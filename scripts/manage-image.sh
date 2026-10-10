#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later

set -eu

action=$1
podman=$2
agent=$3
base_tag=$4
project_tag=$5
container=$6
. "${0%/*}/image-common.sh"

current=$(find_image --filter "reference=$project_tag")
saved=$(find_image --filter "reference=$rollback_tag")
saved_base=$(find_image --filter "reference=$rollback_base_tag")

case "$action" in
rollback)
	if [ -z "$saved" ] || [ -z "$saved_base" ]; then
		echo "devkit: no rollback image is available for $project_tag." >&2
		exit 1
	fi
	if ! validate_project "$saved" || [ "$validated_base" != "$saved_base" ]; then
		echo "devkit: saved rollback image or base is invalid for $project_tag." >&2
		exit 1
	fi
	running=$("$podman" ps --filter "name=$container" --format '{{.Names}}')
	if [ "$current" = "$saved" ]; then
		echo "devkit: already using the rollback image ($validated_version)."
	else
		set_tag "$saved" "$project_tag"
		echo "devkit: restored $project_tag to $agent $validated_version."
	fi
	for name in $running; do
		if [ "$name" = "$container" ]; then
			echo "devkit: restart $container to use the restored image." >&2
		fi
	done
	;;
clean)
	for tag in "$project_tag" "$rollback_tag" "$rollback_base_tag"; do
		restore_tag "$tag" ''
	done
	cleanup_images "$current" "$saved" "$saved_base"
	;;
*)
	echo "devkit: unknown image operation: $action" >&2
	exit 1
	;;
esac
