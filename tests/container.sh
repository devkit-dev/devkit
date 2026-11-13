#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' 0
trap 'exit 1' HUP INT TERM
mkdir -p "$work/mock" "$work/repo"
HOME="$work/home"
mkdir -p "$HOME"
export HOME
git -C "$work/repo" init -q
git -C "$work/repo" config devkit.reponame fixture
git -C "$work/repo" config devkit.agent codex
git -C "$work/repo" config devkit.check-upgrade false

cat > "$work/mock/podman" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$PODMAN_LOG"
case "$1 $2" in
	'ps --format')
		if [ -f "$PREP_MARKER" ] || [ -f "$RACE_MARKER" ]; then
			printf 'devkit-fixture\n'
		else
			printf '%s\n' "$RUNNING_CONTAINERS"
		fi
		;;
	'container inspect')
		if [ "${INSPECT_FAIL-}" = yes ]; then
			echo 'inspect failed' >&2
			exit 125
		fi
		case "$4" in
			*'.Config.Entrypoint'*) printf '%s\n' "$INSPECT_ENTRYPOINT" ;;
			*'.Args'*) printf '%s\n' "$INSPECT_ARGS" ;;
			*) exit 99 ;;
		esac
		;;
	'container exec') exit 0 ;;
	'container run')
		case " $* " in
			*' --name devkit-fixture '*)
				if [ "${RUN_FAIL-}" = yes ]; then
					exit 42
				fi
				if [ "${RACE_MODE-}" = yes ]; then
					: > "$RACE_MARKER"
					exit 125
				fi
				exit 0
				;;
			*) exit 99 ;;
		esac
		;;
	*) echo "unexpected podman call: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$work/mock/podman"
PATH="$work/mock:$PATH"
PODMAN_LOG="$work/podman.log"
RACE_MARKER="$work/race-marker"
PREP_MARKER="$work/prep-marker"
INSPECT_ENTRYPOINT='[/.devkit/entry /usr/local/bin/agent]'
INSPECT_ARGS=/usr/local/bin/agent
export PATH PODMAN_LOG RACE_MARKER PREP_MARKER INSPECT_ENTRYPOINT INSPECT_ARGS

fail()
{
	echo "FAIL: $*" >&2
	cat "$work/output" >&2
	exit 1
}

command_ok()
{
	: > "$PODMAN_LOG"
	"$repo_dir/devkit.sh" --workdir="$work/repo" "$@" > "$work/output" 2>&1 || fail "command failed: $*"
}

command_fails()
{
	: > "$PODMAN_LOG"
	if "$repo_dir/devkit.sh" --workdir="$work/repo" "$@" > "$work/output" 2>&1; then
		fail "command unexpectedly succeeded: $*"
	fi
}

RUNNING_CONTAINERS=aider-for-fixture
export RUNNING_CONTAINERS
command_ok shell
grep -F 'container exec' "$PODMAN_LOG" | grep -F 'aider-for-fixture /bin/bash' >/dev/null || fail 'shell did not join active agent'
command_ok exec true
grep -F 'container exec' "$PODMAN_LOG" | grep -F 'aider-for-fixture true' >/dev/null || fail 'exec did not join active agent'
command_fails run
grep -F 'already has a running container: aider-for-fixture' "$work/output" >/dev/null || fail 'run did not report active agent'

RUNNING_CONTAINERS=devkit-fixture
command_ok shell
grep -F 'container exec' "$PODMAN_LOG" | grep -F 'devkit-fixture /bin/bash' >/dev/null || fail 'shell did not join new container'
command_fails run
grep -F 'already has a running container: devkit-fixture' "$work/output" >/dev/null || fail 'run did not report new container'

INSPECT_FAIL=yes
export INSPECT_FAIL
RUNNING_CONTAINERS=aider-for-fixture
command_fails shell
grep -F 'inspect failed' "$work/output" >/dev/null || fail 'legacy inspect failure was hidden'
unset INSPECT_FAIL

RUNNING_CONTAINERS=$(printf 'aider-for-fixture\ndevkit-fixture')
command_fails shell
grep -F 'multiple containers are running' "$work/output" >/dev/null || fail 'ambiguous containers not reported'

RUNNING_CONTAINERS=codex-for-fixture-ollama
INSPECT_ENTRYPOINT='[/.devkit/entry ollama serve]'
active=$(sh "$repo_dir/scripts/active-container.sh" "$work/mock/podman" fixture-ollama) || fail 'ollama service lookup failed'
if [ -n "$active" ]; then
	fail 'service matched legacy agent'
fi
RUNNING_CONTAINERS=codex-for-fixture-sashiko
INSPECT_ENTRYPOINT='[/.devkit/entry sashiko]'
active=$(sh "$repo_dir/scripts/active-container.sh" "$work/mock/podman" fixture-sashiko) || fail 'sashiko service lookup failed'
if [ -n "$active" ]; then
	fail 'sashiko service matched legacy agent'
fi
RUNNING_CONTAINERS=codex-for-fixture-ollama
INSPECT_ENTRYPOINT='[/.devkit/entry /usr/local/bin/agent]'
[ "$(sh "$repo_dir/scripts/active-container.sh" "$work/mock/podman" fixture-ollama)" = codex-for-fixture-ollama ] || fail 'genuine legacy agent was missed'

RUNNING_CONTAINERS=retired-for-fixture
command_ok shell
grep -F 'retired-for-fixture /bin/bash' "$PODMAN_LOG" >/dev/null || fail 'removed agent was missed'
command_fails run
grep -F 'already has a running container: retired-for-fixture' "$work/output" >/dev/null || fail 'removed agent did not block run'

RUNNING_CONTAINERS=codex-for-fixture
INSPECT_ENTRYPOINT='[/.devkit/entry]'
for INSPECT_ARGS in ollama sashiko; do
	command_ok shell
	grep -F 'codex-for-fixture /bin/bash' "$PODMAN_LOG" >/dev/null || fail "legacy exec $INSPECT_ARGS container was missed"
	command_fails run
	grep -F 'already has a running container: codex-for-fixture' "$work/output" >/dev/null || fail "legacy exec $INSPECT_ARGS did not block run"
done

INSPECT_FAIL=yes
export INSPECT_FAIL
command_fails run
grep -F 'inspect failed' "$work/output" >/dev/null || fail 'inspect failure was hidden'
unset INSPECT_FAIL

RUNNING_CONTAINERS=$(printf 'retired-for-fixture\naider-for-fixture')
INSPECT_ENTRYPOINT='[/.devkit/entry /usr/local/bin/agent]'
command_fails shell
grep -F 'multiple containers are running' "$work/output" >/dev/null || fail 'multiple legacy agents not reported'

cat > "$work/mock.mk" <<'EOF'
_create-image-none:
	@if [ "$${PREP_MODE-}" = yes ]; then : > "$$PREP_MARKER"; fi
EOF
RUNNING_CONTAINERS=
: > "$PODMAN_LOG"
make -s -C "$work/repo" -f "$repo_dir/devkit.mk" -f "$work/mock.mk" _start-shell VENDOR=none > "$work/output" 2>&1 || fail 'new shell failed'
grep -F -- '--entrypoint=["/.devkit/entry","/bin/bash"]' "$PODMAN_LOG" >/dev/null || fail 'new shell lost its entrypoint'
: > "$PODMAN_LOG"
make -s -C "$work/repo" -f "$repo_dir/devkit.mk" -f "$work/mock.mk" _start-exec VENDOR=none > "$work/output" 2>&1 || fail 'new exec failed'
grep -F -- '--entrypoint=["/.devkit/entry"]' "$PODMAN_LOG" >/dev/null || fail 'new exec lost its entrypoint'
: > "$PODMAN_LOG"
make -s -C "$work/repo" -f "$repo_dir/devkit.mk" -f "$work/mock.mk" _start-run VENDOR=none > "$work/output" 2>&1 || fail 'start failed'
grep -F 'container run' "$PODMAN_LOG" | grep -F -- '--name devkit-fixture' >/dev/null || fail 'start did not reserve repo name'

PREP_MODE=yes
export PREP_MODE
: > "$PODMAN_LOG"
make -s -C "$work/repo" -f "$repo_dir/devkit.mk" -f "$work/mock.mk" _start-shell VENDOR=none > "$work/output" 2>&1 || fail 'prepared shell did not join active container'
grep -F 'container exec' "$PODMAN_LOG" | grep -F 'devkit-fixture /bin/bash' >/dev/null || fail 'prepared shell did not attach'
if grep -F 'container run' "$PODMAN_LOG" >/dev/null; then
	fail 'prepared shell tried to start another container'
fi
unset PREP_MODE
rm -f -- "$PREP_MARKER"

RACE_MODE=yes
export RACE_MODE
RUNNING_CONTAINERS=
: > "$PODMAN_LOG"
if make -s -C "$work/repo" -f "$repo_dir/devkit.mk" -f "$work/mock.mk" _start-shell VENDOR=none > "$work/output" 2>&1; then
	fail 'racing shell unexpectedly succeeded'
fi
if [ "$(grep -c '^ps --format' "$PODMAN_LOG")" != 1 ]; then
	fail 'racing shell repeated the active-container lookup'
fi
if grep -F 'container exec' "$PODMAN_LOG" >/dev/null; then
	fail 'racing shell attached after run failed'
fi
unset RACE_MODE
rm -f -- "$RACE_MARKER"

RUN_FAIL=yes
export RUN_FAIL
: > "$PODMAN_LOG"
if make -s -C "$work/repo" -f "$repo_dir/devkit.mk" -f "$work/mock.mk" _start-run VENDOR=none > "$work/output" 2>&1; then
	fail 'failed run unexpectedly succeeded'
else
	status=$?
fi
[ "$status" -eq 2 ] || fail "make returned $status instead of 2"
grep -F 'Error 42' "$work/output" >/dev/null || fail 'podman failure status was lost'
unset RUN_FAIL

echo 'Container dispatch tests passed.'
