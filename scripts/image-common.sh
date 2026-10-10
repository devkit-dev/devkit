# SPDX-License-Identifier: GPL-2.0-or-later

base_repo=${base_tag%:latest}
rollback_tag=$project_tag-rollback
rollback_base_tag=$project_tag-rollback-base

find_image()
{
	images=$("$podman" image list --no-trunc "$@" --format '{{.Id}}') || return
	first=$(printf '%s\n' "$images" | sed -n '1p')
	if [ -n "$first" ]; then
		"$podman" image inspect --format '{{.Id}}' "$first"
	fi
}

label()
{
	"$podman" image inspect --format "{{index .Labels \"$2\"}}" "$1"
}

version_tag_for()
{
	if [ "${#1}" -le 128 ] &&
	   printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$' &&
	   [ "$(printf '%s' "$1" | wc -l)" -eq 0 ] && [ "$1" != latest ]; then
		printf '%s:%s\n' "$base_repo" "$1"
	else
		printf '%s:version-%s\n' "$base_repo" "$(printf '%s' "$1" | sha256sum | cut -d ' ' -f 1)"
	fi
}

# Resolve the project's actual base, rather than the shared latest tag.
validate_project()
{
	[ "$(label "$1" local.devkit.image.kind)" = project ] || return 1
	[ "$(label "$1" local.devkit.agent)" = "$agent" ] || return 1
	validated_version=$(label "$1" local.devkit.agent.version) || return
	case "$validated_version" in ''|'<no value>') return 1 ;; esac
	validated_base=$(label "$1" local.devkit.base.id) || return
	case "$validated_base" in ''|'<no value>') return 1 ;; esac
	validated_base=$("$podman" image inspect --format '{{.Id}}' "$validated_base") || return
	[ "$(label "$validated_base" local.devkit.image.kind)" = agent-base ] || return 1
	[ "$(label "$validated_base" local.devkit.base.agent)" = "$agent" ] || return 1
	[ "$(label "$validated_base" local.devkit.base.agent.version)" = "$validated_version" ]
}

set_tag()
{
	existing=$(find_image --filter "reference=$2") || return
	if [ "$existing" != "$1" ]; then
		"$podman" image tag "$1" "$2"
	fi
}

restore_tag()
{
	if [ -n "$2" ]; then
		set_tag "$2" "$1"
	else
		existing=$(find_image --filter "reference=$1") || return
		if [ -n "$existing" ]; then
			"$podman" image untag "$existing" "$1"
		fi
	fi
}

cleanup_image()
{
	candidate=$1
	[ -n "$candidate" ] || return 0
	kind=$(label "$candidate" local.devkit.image.kind) || return
	case "$kind" in project|agent-base) ;; *) return 0 ;; esac
	tags=$("$podman" image inspect --format '{{range .RepoTags}}{{println .}}{{end}}' "$candidate") || return
	for tag in $tags; do
		# Repository tags, including rollback references, protect images.
		[ "$kind" = agent-base ] || return 0
		case "$tag" in
			"$base_tag"|"${version_tag-}") return 0 ;;
			"$base_repo":*) ;;
			*) return 0 ;;
		esac
	done
	users=$("$podman" ps --all --filter "ancestor=$candidate" --format '{{.ID}}') || return
	[ -z "$users" ] || return 0
	# Child images and containers are protected by non-forced removal.
	if "$podman" image rm --no-prune "$candidate"; then
		return 0
	else
		status=$?
		[ "$status" -ne 2 ] || return 0
		return "$status"
	fi
}

cleanup_images()
{
	cleaned=
	for candidate in "$@"; do
		[ -n "$candidate" ] || continue
		case " $cleaned " in *" $candidate "*) continue ;; esac
		cleaned="$cleaned $candidate"
		if ! cleanup_image "$candidate"; then
			echo "devkit: warning: could not clean image $candidate." >&2
		fi
	done
}
