#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later

set -eu

fail()
{
	echo "devkit: $*" >&2
	exit 1
}

cleanup()
{
	status=$?
	trap - 0 HUP INT TERM
	if [ "$committed" = false ]; then
		if [ "$new_launcher" = true ] && [ -L "$launcher" ] &&
			[ "$(readlink "$launcher")" = "$dest_dir/devkit.sh" ]; then
			rm -- "$launcher"
		fi
		if [ "$installed" = true ]; then
			rm -rf -- "$dest_dir"
		fi
		if [ -d "$stage/previous" ]; then
			if ! mv -- "$stage/previous" "$dest_dir"; then
				echo "devkit: restore failed; previous installation: $stage/previous" >&2
				exit 1
			fi
		fi
	fi
	rm -rf -- "$stage"
	exit "$status"
}

main()
{
	case "${HOME-}" in
		/*) ;;
		*) fail 'HOME must be an absolute path.' ;;
	esac
	for utility in curl tar mkdir mktemp mv rm ln readlink; do
		command -v "$utility" >/dev/null 2>&1 ||
			fail "required utility '$utility' not found."
	done

	dest_dir="$HOME/.local/share/devkit"
	bin_dir=
	for dir in "$HOME/bin" "$HOME/.local/bin"; do
		case ":${PATH-}:" in
			*:"$dir":*) bin_dir=$dir; break ;;
		esac
	done
	needs_path=false
	if [ -z "$bin_dir" ]; then
		bin_dir="$HOME/.local/bin"
		needs_path=true
	fi
	launcher="$bin_dir/devkit"
	if [ -e "$launcher" ] || [ -L "$launcher" ]; then
		[ -L "$launcher" ] &&
			[ "$(readlink "$launcher")" = "$dest_dir/devkit.sh" ] ||
			fail "refusing to replace unrelated launcher: $launcher"
	fi
	if [ -e "$dest_dir" ] || [ -L "$dest_dir" ]; then
		[ ! -L "$dest_dir" ] && [ -d "$dest_dir" ] &&
			[ -f "$dest_dir/devkit.sh" ] &&
			[ -f "$dest_dir/devkit.mk" ] &&
			[ -d "$dest_dir/agents" ] &&
			[ -d "$dest_dir/subcmds" ] ||
			fail "refusing to replace unrelated installation directory: $dest_dir"
	fi

	repo=https://github.com/devkit-dev/devkit
	release_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$repo/releases/latest") ||
		fail 'unable to determine the latest release.'
	case "$release_url" in
		"$repo/releases/tag/"*) tag=${release_url##*/} ;;
		*) fail 'unable to determine the latest release.' ;;
	esac
	case "$tag" in
		''|.|..|*[!a-zA-Z0-9._-]*) fail 'invalid release tag.' ;;
	esac

	mkdir -p -- "$HOME/.local/share" "$bin_dir"
	stage=$(mktemp -d "$HOME/.local/share/.devkit-install.XXXXXXXX")
	committed=false
	installed=false
	new_launcher=false
	trap cleanup 0
	trap 'exit 1' HUP INT TERM
	curl -fsSL -o "$stage/release.tar.gz" "$repo/archive/refs/tags/$tag.tar.gz" ||
		fail 'release download failed.'
	mkdir -- "$stage/new"
	tar -xzf "$stage/release.tar.gz" -C "$stage/new" --strip-components=1 ||
		fail 'release extraction failed.'
	[ -x "$stage/new/devkit.sh" ] && [ -f "$stage/new/devkit.mk" ] &&
		[ -d "$stage/new/agents" ] && [ -d "$stage/new/subcmds" ] ||
		fail 'release archive is missing required files.'

	if [ -d "$dest_dir" ]; then
		mv -- "$dest_dir" "$stage/previous"
	fi
	installed=true
	mv -- "$stage/new" "$dest_dir"
	if [ ! -L "$launcher" ]; then
		new_launcher=true
		ln -s -- "$dest_dir/devkit.sh" "$launcher" ||
			fail "unable to create launcher: $launcher"
	fi
	committed=true
	echo "devkit $tag installed in $dest_dir"
	if [ "$needs_path" = true ]; then
		echo 'Add ~/.local/bin to PATH before running devkit:'
		# shellcheck disable=SC2016
		echo '  export PATH="$HOME/.local/bin:$PATH"'
	fi
}

main "$@"
