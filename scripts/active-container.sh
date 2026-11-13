#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later

set -eu

podman="$1"
repo="$2"

running=$("$podman" ps --format '{{.Names}}')
matches=
for name in $running; do
	case "$name" in
		"devkit-$repo") shared=true ;;
		*-for-"$repo") shared=false ;;
		*) continue ;;
	esac
	if [ "$shared" = true ]; then
		matches="${matches}${matches:+ }$name"
		continue
	fi
	entrypoint=$("$podman" container inspect --format '{{.Config.Entrypoint}}' "$name")
	case "$entrypoint" in
		'[/.devkit/entry ollama serve]'|'/.devkit/entry ollama serve'|\
		'[/.devkit/entry sashiko]'|'/.devkit/entry sashiko') continue ;;
		*'/.devkit/entry'*) matches="${matches}${matches:+ }$name" ;;
	esac
done
case "$matches" in
	*' '*)
		echo "devkit: multiple containers are running for repo $repo: $matches" >&2
		exit 1
		;;
esac
printf '%s' "$matches"
