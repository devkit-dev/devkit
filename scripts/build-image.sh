#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later

set -eu

podman=$1
agent=$2
base_tag=$3
project_tag=$4
project_hash=$5
devkit_version=$6
vendor=$7
upgrade=$8
build_dir=$9
shift 9
. "${0%/*}/image-common.sh"

use_project()
{
	if [ "$current" = "$image" ]; then
		echo "devkit: project image is up to date."
	else
		"$podman" image tag "$image" "$project_tag"
		echo "devkit: using project image for $project_tag."
	fi
}

current=$(find_image --filter "reference=$project_tag")
if [ -z "$upgrade" ]; then
	if [ -n "$current" ] &&
	   [ "$(label "$current" local.devkit.hash)" = "$project_hash" ]; then
		exit 0
	fi
	image=$(find_image --filter "label=local.devkit.hash=$project_hash")
	if [ -n "$image" ]; then
		use_project
		exit 0
	fi
fi

base_hash=$({
	printf '%s\n' "$agent" "$devkit_version" "$vendor"
	cat "$build_dir/base"
} | sha256sum | cut -d ' ' -f 1)
old_base=$(find_image --filter "reference=$base_tag")
old_version=
refreshed=
base=

if [ -z "$upgrade" ] && [ -n "$old_base" ] &&
   [ "$(label "$old_base" local.devkit.base.hash)" = "$base_hash" ]; then
	base=$old_base
	agent_version=$(label "$base" local.devkit.base.agent.version)
else
	if ! agent_version=$(sh "$build_dir/release") ||
	   [ -z "$agent_version" ]; then
		echo "devkit: unable to determine the latest $agent version." >&2
		exit 1
	fi
fi

version_tag=$(version_tag_for "$agent_version")
outgoing_version=
outgoing_base=
history_changed=
previous_project=
previous_base=
if [ -n "$upgrade" ] && [ -n "$current" ]; then
	if ! validate_project "$current"; then
		echo "devkit: cannot retain rollback: current image has unresolved version/base metadata." >&2
		exit 1
	fi
	outgoing_version=$validated_version
	outgoing_base=$validated_base
	if [ "$outgoing_version" != "$agent_version" ]; then
		history_changed=yes
		previous_project=$(find_image --filter "reference=$rollback_tag")
		previous_base=$(find_image --filter "reference=$rollback_base_tag")
	fi
fi

base_build_tag=$base_repo:build-${build_dir##*/}-$$
project_build_tag=${project_tag%:*}:build-${build_dir##*/}-$$
transaction=
committed=
finish()
{
	result=$?
	trap - EXIT
	if [ -n "$transaction" ] && [ -z "$committed" ]; then
		while read -r tag original; do
			if ! restore_tag "$tag" "$original"; then
				echo "devkit: warning: could not restore tag $tag." >&2
			fi
		done <"$build_dir/tags"
	fi
	for tag in "$project_build_tag" "$base_build_tag"; do
		if ! restore_tag "$tag" ''; then
			echo "devkit: warning: could not remove temporary tag $tag." >&2
		fi
	done
	exit "$result"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM

if [ -z "$base" ]; then
	old_version=$(find_image --filter "reference=$version_tag")
	if [ -n "$old_version" ] &&
	   [ "$(label "$old_version" local.devkit.base.hash)" = "$base_hash" ] &&
	   [ "$(label "$old_version" local.devkit.base.agent.version)" = "$agent_version" ]; then
		base=$old_version
	else
		base=$(find_image \
			--filter 'label=local.devkit.image.kind=agent-base' \
			--filter "label=local.devkit.base.hash=$base_hash" \
			--filter "label=local.devkit.base.agent.version=$agent_version")
	fi
fi

if [ -n "$base" ]; then
	echo "devkit: reused $agent base ($agent_version)."
else
	echo "devkit: building $agent base ($agent_version)."
	pull=missing
	[ -z "$upgrade" ] || pull=always
	"$podman" image build --tag="$base_build_tag" \
		--label=local.devkit.image.kind=agent-base \
		--label="local.devkit.base.agent=$agent" \
		--label="local.devkit.base.agent.version=$agent_version" \
		--label="local.devkit.base.hash=$base_hash" \
		--build-arg="DEVKIT_AGENT_VERSION=$agent_version" \
		--layers --pull="$pull" --force-rm --format=docker \
		--file="$build_dir/base"
	base=$(find_image --filter "reference=$base_build_tag")
	[ -n "$base" ] || { echo 'devkit: built base image not found.' >&2; exit 1; }
	refreshed=yes
fi

# Use a full immutable ID both in FROM and in project-image metadata.
base=$("$podman" image inspect --format '{{.Id}}' "$base")
image=
if [ -n "$current" ] &&
   [ "$(label "$current" local.devkit.hash)" = "$project_hash" ] &&
   [ "$(label "$current" local.devkit.base.id)" = "$base" ]; then
	image=$current
else
	image=$(find_image --filter "label=local.devkit.hash=$project_hash" \
		--filter "label=local.devkit.base.id=$base")
fi
if [ -z "$image" ]; then
	echo "devkit: building project image for $project_tag."
	"$podman" image build --tag="$project_build_tag" \
		--label=local.devkit.image.kind=project \
		--label="local.devkit.agent=$agent" \
		--label="local.devkit.agent.version=$agent_version" \
		--label="local.devkit.hash=$project_hash" \
		--label="local.devkit.base.id=$base" \
		--build-arg="DEVKIT_BASE_IMAGE=$base" \
		"$@" --force-rm --format=docker --file="$build_dir/project"
	image=$(find_image --filter "reference=$project_build_tag")
	[ -n "$image" ] || { echo 'devkit: built project image not found.' >&2; exit 1; }
fi

# Record original tag targets before publishing any prepared images.
: >"$build_dir/tags"
remember_tag()
{
	original=$(find_image --filter "reference=$1") || return
	printf '%s %s\n' "$1" "$original" >>"$build_dir/tags"
}
remember_tag "$project_tag"
remember_tag "$base_tag"
remember_tag "$version_tag"
if [ -n "$history_changed" ]; then
	outgoing_tag=$(version_tag_for "$outgoing_version")
	remember_tag "$rollback_tag"
	remember_tag "$rollback_base_tag"
	remember_tag "$outgoing_tag"
fi
transaction=yes
if [ -n "$history_changed" ]; then
	set_tag "$current" "$rollback_tag"
	set_tag "$outgoing_base" "$rollback_base_tag"
	set_tag "$outgoing_base" "$outgoing_tag"
fi
set_tag "$base" "$version_tag"
set_tag "$base" "$base_tag"
use_project
committed=yes

if [ -n "$upgrade" ] && { [ -n "$refreshed" ] || [ -n "$history_changed" ]; }; then
	# Repository rollback tags protect retained projects and their bases.
	cleanup_images "$current" "$previous_project" "$old_base" "$old_version" "$previous_base"
fi
