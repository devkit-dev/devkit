#!/bin/sh -eu
set -eu

src=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/mock" "$tmp/repo"
git -C "$tmp/repo" init -q
git -C "$tmp/repo" config devkit.check-upgrade false
git -C "$tmp/repo" config --add devkit.run-arg "--security-opt='unmask=/proc/*'"
git -C "$tmp/repo" config --add devkit.run-arg "--annotation='note=hello world'"

cat >"$tmp/mock/podman" <<'EOF'
#!/bin/sh -eu
case "$1 $2" in
  'ps --format') exit 0 ;;
  'container run') shift 2; printf '<%s>\n' "$@" >"$PODMAN_LOG" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tmp/mock/podman"
cat >"$tmp/mock.mk" <<'EOF'
_create-image-none:
	@:
EOF

PATH="$tmp/mock:$PATH" PODMAN_LOG="$tmp/args" MAKEFILES="$tmp/mock.mk" \
  make -s -C "$tmp/repo" -f "$src/devkit.mk" \
  run VENDOR=none "ARGS='hello world'" >/dev/null
cat >"$tmp/expected" <<'EOF'
<--log-driver=none>
<--security-opt=unmask=/proc/*>
<--annotation=note=hello world>
<-->
<localhost/devkit/repo:dummy>
<hello world>
EOF
sed -n '/^<--log-driver=none>$/,$p' "$tmp/args" | diff -u "$tmp/expected" -

git -C "$tmp/repo" config --unset-all devkit.run-arg
PATH="$tmp/mock:$PATH" PODMAN_LOG="$tmp/args" MAKEFILES="$tmp/mock.mk" \
  make -s -C "$tmp/repo" -f "$src/devkit.mk" \
  run VENDOR=none >/dev/null
cat >"$tmp/expected" <<'EOF'
<--log-driver=none>
<-->
<localhost/devkit/repo:dummy>
EOF
sed -n '/^<--log-driver=none>$/,$p' "$tmp/args" | diff -u "$tmp/expected" -
