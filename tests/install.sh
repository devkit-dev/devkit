#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' 0
trap 'exit 1' HUP INT TERM
mkdir -p "$work/mock" "$work/fixture/devkit/agents" "$work/fixture/devkit/subcmds"
cp "$repo_dir/devkit.sh" "$work/fixture/devkit/devkit.sh"
sed 's/^VERSION = .*/VERSION = 6/' "$repo_dir/devkit.mk" > "$work/fixture/devkit/devkit.mk"
printf '# fixture agent\n' > "$work/fixture/devkit/agents/dummy.mk"
printf '# fixture subcommand\n' > "$work/fixture/devkit/subcmds/ollama.mk"
tar -czf "$work/missing-installer.tar.gz" -C "$work/fixture" devkit
cp "$repo_dir/install.sh" "$work/fixture/devkit/install.sh"
tar -czf "$work/release.tar.gz" -C "$work/fixture" devkit
sed 's/^VERSION = .*/VERSION = 7/' "$repo_dir/devkit.mk" > "$work/fixture/devkit/devkit.mk"
tar -czf "$work/release-v7.tar.gz" -C "$work/fixture" devkit
mkdir "$work/incomplete"
tar -czf "$work/incomplete.tar.gz" -C "$work" incomplete

cat > "$work/mock/curl" <<'EOF'
#!/bin/sh
set -eu
repo=${EXPECTED_REPO:-https://github.com/devkit-dev/devkit}
tag=${LATEST_TAG:-v6}
printf '%s\n' "$*" >> "$FIXTURE_DIR/curl.log"
if [ "$*" = "-fsSL -o /dev/null -w %{url_effective} $repo/releases/latest" ]; then
	case "${DOWNLOAD_MODE-}" in
		unavailable) exit 22 ;;
		no-release) printf '%s/releases/latest' "$repo" ;;
		*) printf '%s/releases/tag/%s' "$repo" "$tag" ;;
	esac
else
	[ "$#" = 4 ] && [ "$1" = -fsSL ] && [ "$2" = -o ] &&
		[ "$4" = "$repo/archive/refs/tags/$tag.tar.gz" ] || exit 99
	case "${DOWNLOAD_MODE-}" in
		failed) printf 'partial download' > "$3"; exit 22 ;;
		invalid) printf 'invalid archive' > "$3" ;;
		incomplete) cp "$FIXTURE_DIR/incomplete.tar.gz" "$3" ;;
		missing-installer) cp "$FIXTURE_DIR/missing-installer.tar.gz" "$3" ;;
		*)
			if [ "$tag" = v7 ]; then
				cp "$FIXTURE_DIR/release-v7.tar.gz" "$3"
			else
				cp "$FIXTURE_DIR/release.tar.gz" "$3"
			fi
			;;
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
if [ "${USE_REAL_MAKE-}" = true ]; then exec "$REAL_MAKE" "$@"; fi
[ "$1" = -f ] && [ "$2" = "$HOME/.local/share/devkit/devkit.mk" ]
[ -f "$2" ]
[ "$3" = -- ] && [ "$4" = version ]
echo 'installed launcher works'
EOF
cat > "$work/mock/git" <<'EOF'
#!/bin/sh
# Report that the newer config subcommands are unavailable.
exit 1
EOF
cat > "$work/mock/podman" <<'EOF'
#!/bin/sh
echo 'unexpected podman invocation' >&2
exit 99
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
	unset DOWNLOAD_MODE FAIL_LINK FAIL_REPLACE DEVKIT_REPO EXPECTED_REPO LATEST_TAG USE_REAL_MAKE
	: > "$work/curl.log"
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
REAL_MAKE=$(command -v make)
export FIXTURE_DIR REAL_MAKE

reset_home
install_ok
[ "$(readlink "$HOME/.local/bin/devkit")" = "$dest/devkit.sh" ] || fail 'wrong launcher'
[ -f "$dest/agents/dummy.mk" ] && [ -f "$dest/subcmds/ollama.mk" ] || fail 'support files missing'
[ "$(cat "$dest/.devkit-repo")" = https://github.com/devkit-dev/devkit ] || fail 'default repository not saved'
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

for mode in unavailable no-release failed invalid incomplete missing-installer; do
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

reset_home
DEVKIT_REPO=
export DEVKIT_REPO
install_ok
[ "$(cat "$dest/.devkit-repo")" = https://github.com/devkit-dev/devkit ] || fail 'empty override did not default to upstream'

reset_home
EXPECTED_REPO=https://github.com/example/devkit
DEVKIT_REPO="$EXPECTED_REPO///"
export EXPECTED_REPO DEVKIT_REPO
install_ok
[ "$(cat "$dest/.devkit-repo")" = "$EXPECTED_REPO" ] || fail 'fork repository not normalized and saved'
unset DEVKIT_REPO
install_ok
DEVKIT_REPO=
export DEVKIT_REPO
install_ok
[ "$(cat "$dest/.devkit-repo")" = "$EXPECTED_REPO" ] || fail 'saved repository not reused'

reset_runtime()
{
	reset_home
	# The Makefile's existing path handling requires a home without spaces.
	HOME="$work/runtime-$case_number"
	export HOME
	mkdir -p "$HOME"
	dest="$HOME/.local/share/devkit"
	USE_REAL_MAKE=true
	export USE_REAL_MAKE
}

upgrade_ok()
{
	"$HOME/.local/bin/devkit" self-upgrade > "$work/output" 2>&1 || fail 'self-upgrade failed'
}

upgrade_fails()
{
	if "$HOME/.local/bin/devkit" self-upgrade > "$work/output" 2>&1; then
		fail 'self-upgrade unexpectedly succeeded'
	fi
}

check_release()
{
	# Including version avoids unrelated project initialization.
	make -f "$dest/devkit.mk" version _check-devkit-version > "$work/output" 2>&1 || fail 'release check failed'
	grep -F "release home page: $EXPECTED_REPO/releases/latest" "$work/output" >/dev/null || fail 'release check used wrong repository'
	grep -F "available version: ${LATEST_TAG#v}" "$work/output" >/dev/null || fail 'release check did not resolve version'
}

reset_runtime
EXPECTED_REPO=https://github.com/example/devkit
DEVKIT_REPO=$EXPECTED_REPO
export EXPECTED_REPO DEVKIT_REPO
install_ok
unset DEVKIT_REPO
LATEST_TAG=v6
export LATEST_TAG
check_release
printf 'keep me\n' > "$dest/marker"
for tag in v6 6; do
	LATEST_TAG=$tag
	: > "$work/curl.log"
	upgrade_ok
	grep -F 'devkit is up to date (6).' "$work/output" >/dev/null || fail 'missing up-to-date message'
	[ "$(cat "$dest/marker")" = 'keep me' ] || fail 'no-op replaced installation'
	[ "$(cat "$dest/.devkit-repo")" = "$EXPECTED_REPO" ] || fail 'no-op changed repository'
	[ "$(wc -l < "$work/curl.log")" -eq 1 ] || fail 'no-op did more than release lookup'
	assert_clean
done

LATEST_TAG=v7
make -f "$dest/devkit.mk" version _check-self-upgrade CHECK_UPGRADE=true > "$work/output" 2>&1 || fail 'upgrade notification failed'
grep -F 'new version 7 is available' "$work/output" >/dev/null || fail 'missing fork upgrade notification'
: > "$work/curl.log"
upgrade_ok
[ ! -e "$dest/marker" ] || fail 'upgrade retained previous tree'
[ "$(cat "$dest/.devkit-repo")" = "$EXPECTED_REPO" ] || fail 'upgrade lost fork repository'
grep -Fx 'VERSION = 7' "$dest/devkit.mk" >/dev/null || fail 'upgrade did not install new release'
[ "$(wc -l < "$work/curl.log")" -eq 2 ] || fail 'upgrade repeated release lookup'
assert_clean

# An explicit source switch must install even when versions are equal.
EXPECTED_REPO=https://github.com/devkit-dev/devkit
DEVKIT_REPO="$EXPECTED_REPO///"
export DEVKIT_REPO
check_release
printf 'replace me\n' > "$dest/marker"
upgrade_ok
[ ! -e "$dest/marker" ] || fail 'same-version repository switch was skipped'
[ "$(cat "$dest/.devkit-repo")" = "$EXPECTED_REPO" ] || fail 'repository switch not saved'
assert_clean

# Failed source switches must preserve both the installed tree and source.
for fault in unavailable no-release failed invalid incomplete missing-installer replacement; do
	reset_runtime
	install_ok
	printf 'keep me\n' > "$dest/marker"
	EXPECTED_REPO=https://github.com/example/devkit
	DEVKIT_REPO=$EXPECTED_REPO
	LATEST_TAG=v7
	export EXPECTED_REPO DEVKIT_REPO LATEST_TAG
	if [ "$fault" = replacement ]; then
		FAIL_REPLACE=true
		export FAIL_REPLACE
	else
		DOWNLOAD_MODE=$fault
		export DOWNLOAD_MODE
	fi
	upgrade_fails
	[ "$(cat "$dest/marker")" = 'keep me' ] || fail "$fault lost previous installation"
	[ "$(cat "$dest/.devkit-repo")" = https://github.com/devkit-dev/devkit ] || fail "$fault changed saved repository"
	[ "$(readlink "$HOME/.local/bin/devkit")" = "$dest/devkit.sh" ] || fail "$fault changed launcher"
	assert_clean
done

reset_runtime
install_ok
rm "$dest/.devkit-repo"
EXPECTED_REPO=https://github.com/devkit-dev/devkit
LATEST_TAG=v6
export EXPECTED_REPO LATEST_TAG
check_release
upgrade_ok
[ ! -e "$dest/.devkit-repo" ] || fail 'legacy no-op changed metadata'
LATEST_TAG=v7
upgrade_ok
[ "$(cat "$dest/.devkit-repo")" = "$EXPECTED_REPO" ] || fail 'legacy upgrade did not save repository'
assert_clean

echo 'Installer tests passed.'
