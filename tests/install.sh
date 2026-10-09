#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' 0
trap 'exit 1' HUP INT TERM
mkdir -p "$work/mock" "$work/fixture/devkit/agents" "$work/fixture/devkit/subcmds"
cp "$repo_dir/devkit.sh" "$work/fixture/devkit/devkit.sh"
printf 'fixture makefile\n' > "$work/fixture/devkit/devkit.mk"
printf 'fixture agent\n' > "$work/fixture/devkit/agents/dummy.mk"
printf 'fixture subcommand\n' > "$work/fixture/devkit/subcmds/ollama.mk"
tar -czf "$work/release.tar.gz" -C "$work/fixture" devkit
mkdir "$work/incomplete"
tar -czf "$work/incomplete.tar.gz" -C "$work" incomplete

cat > "$work/mock/curl" <<'EOF'
#!/bin/sh
set -eu
if [ "$*" = "-fsSL -o /dev/null -w %{url_effective} https://github.com/devkit-dev/devkit/releases/latest" ]; then
	case "${DOWNLOAD_MODE-}" in
		unavailable) exit 22 ;;
		no-release) printf 'https://github.com/devkit-dev/devkit/releases/latest' ;;
		*) printf 'https://github.com/devkit-dev/devkit/releases/tag/v6' ;;
	esac
else
	[ "$#" = 4 ] && [ "$1" = -fsSL ] && [ "$2" = -o ] &&
		[ "$4" = https://github.com/devkit-dev/devkit/archive/refs/tags/v6.tar.gz ] || exit 99
	case "${DOWNLOAD_MODE-}" in
		failed) printf 'partial download' > "$3"; exit 22 ;;
		invalid) printf 'invalid archive' > "$3" ;;
		incomplete) cp "$FIXTURE_DIR/incomplete.tar.gz" "$3" ;;
		*) cp "$FIXTURE_DIR/release.tar.gz" "$3" ;;
	esac
fi
EOF
cat > "$work/mock/ln" <<'EOF'
#!/bin/sh
[ "${FAIL_LINK-}" != true ] || exit 1
exec /bin/ln "$@"
EOF
cat > "$work/mock/mv" <<'EOF'
#!/bin/sh
if [ "${FAIL_REPLACE-}" = true ]; then
	case "$2" in */new) exit 1 ;; esac
fi
exec /bin/mv "$@"
EOF
cat > "$work/mock/make" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = -f ] && [ "$2" = "$HOME/.local/share/devkit/devkit.mk" ]
[ -f "$2" ]
[ "$3" = -- ] && [ "$4" = version ]
echo 'installed launcher works'
EOF
chmod +x "$work/mock/"*

fail()
{
	echo "FAIL: $*" >&2
	cat "$work/output" >&2
	exit 1
}

reset_home()
{
	case_number=$((case_number + 1))
	HOME="$work/home $case_number"
	export HOME
	mkdir -p "$HOME"
	PATH="$work/mock:/usr/bin:/bin"
	export PATH
	unset DOWNLOAD_MODE FAIL_LINK FAIL_REPLACE
	dest="$HOME/.local/share/devkit"
}

install_ok()
{
	# Feed the script through stdin, like the documented curl pipeline.
	/bin/sh < "$repo_dir/install.sh" > "$work/output" 2>&1 || fail 'installation failed'
}

install_fails()
{
	if /bin/sh < "$repo_dir/install.sh" > "$work/output" 2>&1; then
		fail 'installation unexpectedly succeeded'
	fi
}

assert_clean()
{
	for entry in "$HOME/.local/share/".devkit-install.*; do
		[ ! -e "$entry" ] || fail 'staging directory left behind'
	done
}

case_number=0
FIXTURE_DIR=$work
export FIXTURE_DIR

reset_home
install_ok
[ "$(readlink "$HOME/.local/bin/devkit")" = "$dest/devkit.sh" ] || fail 'wrong launcher'
[ -f "$dest/agents/dummy.mk" ] && [ -f "$dest/subcmds/ollama.mk" ] || fail 'support files missing'
grep -F 'export PATH="$HOME/.local/bin:$PATH"' "$work/output" >/dev/null || fail 'missing PATH instructions'
"$HOME/.local/bin/devkit" version > "$work/output" 2>&1 || fail 'launcher cannot locate makefile'
printf 'old installation\n' > "$dest/old-marker"
install_ok
[ ! -e "$dest/old-marker" ] || fail 'repeat installation retained old tree'
assert_clean

for selected in bin .local/bin; do
	reset_home
	PATH="$PATH:$HOME/$selected"
	# Prefer ~/bin even when ~/.local/bin occurs earlier in PATH.
	if [ "$selected" = bin ]; then PATH="$HOME/.local/bin:$PATH"; fi
	install_ok
	[ -L "$HOME/$selected/devkit" ] || fail 'wrong PATH directory selected'
	if grep -F 'export PATH=' "$work/output" >/dev/null; then fail 'unnecessary PATH instructions'; fi
	assert_clean
done

for conflict in file directory symlink; do
	reset_home
	mkdir -p "$HOME/.local/bin"
	case "$conflict" in
		file) printf 'keep me\n' > "$HOME/.local/bin/devkit" ;;
		directory) mkdir "$HOME/.local/bin/devkit" ;;
		symlink) /bin/ln -s "$HOME/unrelated" "$HOME/.local/bin/devkit" ;;
	esac
	install_fails
	grep -F 'unrelated launcher' "$work/output" >/dev/null || fail 'conflict not diagnosed'
	[ ! -e "$dest" ] || fail 'installation created despite conflict'
	case "$conflict" in
		file) [ "$(cat "$HOME/.local/bin/devkit")" = 'keep me' ] || fail 'launcher file changed' ;;
		directory) [ -d "$HOME/.local/bin/devkit" ] || fail 'launcher directory changed' ;;
		symlink) [ "$(readlink "$HOME/.local/bin/devkit")" = "$HOME/unrelated" ] || fail 'launcher symlink changed' ;;
	esac
done

reset_home
mkdir -p "$dest"
printf 'keep me\n' > "$dest/marker"
install_fails
[ "$(cat "$dest/marker")" = 'keep me' ] || fail 'unrelated directory changed'

reset_home
mkdir -p "$HOME/.local/share" "$HOME/unrelated"
printf 'keep me\n' > "$HOME/unrelated/marker"
/bin/ln -s "$HOME/unrelated" "$dest"
install_fails
[ -L "$dest" ] && [ "$(cat "$HOME/unrelated/marker")" = 'keep me' ] || fail 'destination symlink changed'

for mode in unavailable no-release failed invalid incomplete; do
	reset_home
	install_ok
	printf 'keep me\n' > "$dest/marker"
	DOWNLOAD_MODE=$mode
	export DOWNLOAD_MODE
	install_fails
	[ "$(cat "$dest/marker")" = 'keep me' ] || fail "$mode lost previous installation"
	[ -L "$HOME/.local/bin/devkit" ] || fail "$mode lost launcher"
	assert_clean
done

for fault in FAIL_LINK FAIL_REPLACE; do
	reset_home
	install_ok
	printf 'keep me\n' > "$dest/marker"
	# Exercise launcher creation while replacing an existing installation.
	rm "$HOME/.local/bin/devkit"
	export "$fault=true"
	install_fails
	[ "$(cat "$dest/marker")" = 'keep me' ] || fail "$fault rollback lost previous installation"
	[ ! -e "$HOME/.local/bin/devkit" ] || fail "$fault left a launcher"
	assert_clean
done

reset_home
FAIL_LINK=true
export FAIL_LINK
install_fails
[ ! -e "$dest" ] || fail 'failed fresh install left destination'
assert_clean

reset_home
mkdir "$work/missing-tools"
PATH="$work/missing-tools"
install_fails
PATH=/usr/bin:/bin
grep -F "required utility 'curl' not found" "$work/output" >/dev/null || fail 'missing utility not diagnosed'
[ ! -e "$dest" ] || fail 'missing utility changed destination'

echo 'Installer tests passed.'
