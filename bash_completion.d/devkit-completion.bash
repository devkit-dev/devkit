# bash completion for devkit
# source this file or install into /etc/bash_completion.d/

_devkit()
{
	local cur prev words cword
	_init_completion -n : || return

	local commands="clean clean-all list help version init check upgrade rollback shell run exec"
	local opts="--root --agent= --agent --workdir= --workdir -h --help -V --version"

	commands+=" sashiko sashiko-daemon sashiko-kill sashiko-logs"
	commands+=" ollama ollama-daemon ollama-kill ollama-logs"

	cur="${COMP_WORDS[COMP_CWORD]}"
	prev="${COMP_WORDS[COMP_CWORD-1]}"

	# Complete argument for --workdir (supports --workdir DIR)
	if [[ "$prev" == "--workdir" ]]; then
		_filedir -d
		return
	fi

	# Complete argument for --workdir=DIR
	if [[ "$cur" == --workdir=* ]]; then
		local val="${cur#--workdir=}"
		# Ask bash-completion to complete directories for the value part
		local IFS=$'\n'
		local matches
		matches=$(compgen -d -- "$val")
		if [[ -n "$matches" ]]; then
			COMPREPLY=()
			while IFS= read -r m; do
				COMPREPLY+=("--workdir=$m")
			done <<< "$matches"
		fi
		return
	fi

	# If current token is an option, complete options
	if [[ "$cur" == -* ]]; then
		COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
		return
	fi

	# Determine whether a command is already present
	local i cmd_seen=""
	for ((i=1; i<COMP_CWORD; i++)); do
		case "${COMP_WORDS[i]}" in
			clean|clean-all|list|help|version|init|check|upgrade|rollback|shell|run)
				cmd_seen="${COMP_WORDS[i]}"
				break
				;;
		esac
	done

	# Before command: offer commands + options (so can use devkit --root run)
	if [[ -z "$cmd_seen" ]]; then
		COMPREPLY=( $(compgen -W "$commands $opts" -- "$cur") )
		return
	fi

	# After command: by default nothing more (no positional args in usage)
	COMPREPLY=()
}

# Register completion for devkit (and optionally devkit)
complete -F _devkit devkit
