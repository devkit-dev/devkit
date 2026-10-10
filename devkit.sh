#!/bin/sh -efu
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026  Alexey Gladkov <gladkov.alexey@gmail.com>

scr="$(realpath "$0")"
cwd="${scr%/*}"

PROG="${scr##*/}"
workdir=
agent=

is_command()
{
	case "$1" in
		clean|clean-all|list|help|version|init|check|upgrade|rollback|exec|shell|run)
			;;
		sashiko|sashiko-daemon|sashiko-kill|sashiko-logs)
			;;
		ollama|ollama-daemon|ollama-kill|ollama-logs)
			;;
		*)
			return 1
			;;
	esac
}

set_option()
{
	local _name _value
	prev_i="$i"

	_name="$1"; shift

	if [ -n "${1##*=*}" ]; then
		i=$(( $i - 1 ))
		shift
		_value="$1"
	else
		_value="${1#*=}"
	fi
	eval "$_name=\"\$_value\""
}

a=
i="$#"
while [ "$i" -gt 0 ] && ! is_command "$a"; do
	a="$1"
	case "$1" in
		--root)
			export ROOT=1
			;;
		--agent|--agent=*)
			set_option agent "$@"
			[ "$prev_i" = "$i" ] || shift
			;;
		--workdir|--workdir=*)
			set_option workdir "$@"
			[ "$prev_i" = "$i" ] || shift
			;;
		-v|--verbose)
			export VERBOSE=1
			;;
		-h|--help)
			i=1; set -- - help
			;;
		-V|--version)
			i=1; set -- - version
			;;
		*)
			set -- "$@" "$1"
			;;
	esac
	shift
	i=$(( $i - 1 ))
done

NARGS=0
while [ "$i" -gt 0 ]; do
	eval "ARG${NARGS}=\"\$1\""
	eval "export ARG${NARGS}"
	NARGS=$(( $NARGS + 1 ))
	shift
	i=$(( $i - 1 ))
done
export PROG NARGS

[ -z "$agent" ] ||
	set -- "$@" "AGENT=$agent"

export MAKEFLAGS="--no-print-directory --no-builtin-rules"

exec make -f "$cwd/devkit.mk" ${workdir:+--directory="$workdir"} -- "$@"
