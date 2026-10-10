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
base_repo=${base_tag%:latest}

find_image()
{
	images=$("$podman" image list --no-trunc "$@" --format '{{.Id}}') || return
	printf '%s\n' "$images" | sed -n '1p'
}

label()
{
	"$podman" image inspect --format "{{index .Labels \"$2\"}}" "$1"
}

use_project()
{
	if [ "$current" = "$image" ]; then
		echo "devkit: project image is up to date."
	else
		"$podman" image tag "$image" "$project_tag"
		echo "devkit: reused project image for $project_tag."
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

if [ "${#agent_version}" -le 128 ] &&
   printf '%s\n' "$agent_version" | LC_ALL=C grep -Eq '^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$' &&
   [ "$(printf '%s' "$agent_version" | wc -l)" -eq 0 ] &&
   [ "$agent_version" != latest ]; then
	version_tag=$base_repo:$agent_version
else
	version_tag=$base_repo:version-$(printf '%s' "$agent_version" | sha256sum | cut -d ' ' -f 1)
fi

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
	[ "$(find_image --filter "reference=$base_tag")" = "$base" ] ||
		"$podman" image tag "$base" "$base_tag"
	[ "$(find_image --filter "reference=$version_tag")" = "$base" ] ||
		"$podman" image tag "$base" "$version_tag"
	echo "devkit: reused $agent base ($agent_version)."
else
	echo "devkit: building $agent base ($agent_version)."
	pull=missing
	[ -z "$upgrade" ] || pull=always
	"$podman" image build --tag="$base_tag" --tag="$version_tag" \
		--label=local.devkit.image.kind=agent-base \
		--label="local.devkit.base.agent=$agent" \
		--label="local.devkit.base.agent.version=$agent_version" \
		--label="local.devkit.base.hash=$base_hash" \
		--build-arg="DEVKIT_AGENT_VERSION=$agent_version" \
		--layers --pull="$pull" --force-rm --format=docker \
		--file="$build_dir/base"
	base=$(find_image --filter "reference=$version_tag")
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
if [ -n "$image" ]; then
	use_project
else
	echo "devkit: building project image for $project_tag."
	"$podman" image build --tag="$project_tag" \
		--label=local.devkit.image.kind=project \
		--label="local.devkit.agent=$agent" \
		--label="local.devkit.agent.version=$agent_version" \
		--label="local.devkit.hash=$project_hash" \
		--label="local.devkit.base.id=$base" \
		--build-arg="DEVKIT_BASE_IMAGE=$base" \
		"$@" --force-rm --format=docker --file="$build_dir/project"
fi

[ -n "$upgrade" ] && [ -n "$refreshed" ] || exit 0

cleanup_image()
{
	candidate=$1
	[ -n "$candidate" ] || return 0
	kind=$(label "$candidate" local.devkit.image.kind) || return
	case "$kind" in
		project|agent-base) ;;
		*) return 0 ;;
	esac
	tags=$("$podman" image inspect --format '{{range .RepoTags}}{{println .}}{{end}}' "$candidate") || return
	for tag in $tags; do
		# A replaced project must be untagged. Only this agent's old
		# version tags may remain on a replaced base.
		[ "$kind" = agent-base ] || return 0
		case "$tag" in
			"$base_tag"|"$version_tag") return 0 ;;
			"$base_repo":*) ;;
			*) return 0 ;;
		esac
	done
	users=$("$podman" ps --all --filter "ancestor=$candidate" --format '{{.ID}}') || return
	[ -z "$users" ] || return 0
	# Non-forced removal also protects child images, including legacy
	# project images without our base-ID label. Keep cached parents.
	if "$podman" image rm --no-prune "$candidate"; then
		return 0
	else
		status=$?
		[ "$status" -ne 2 ] || return 0
		return "$status"
	fi
}

# Clean the project first so an otherwise-unused old base can be removed.
for candidate in "$current" "$old_base" "$old_version"; do
	[ -n "$candidate" ] || continue
	case " ${cleaned-} " in *" $candidate "*) continue ;; esac
	cleaned="${cleaned-} $candidate"
	if ! cleanup_image "$candidate"; then
		echo "devkit: warning: could not clean replaced image $candidate." >&2
	fi
done
