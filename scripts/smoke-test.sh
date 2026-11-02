#!/bin/bash
# Check a packaged QEMU tarball the way the ArcBox daemon will use it.
#
# Usage: scripts/smoke-test.sh PACKAGE.tar.gz [KERNEL]
#
# Extracts the package into a fresh directory whose path contains a space,
# then checks that:
#   - every Mach-O links only macOS system libraries or @rpath/ dylibs that
#     are in the package, and searches only @executable_path/@loader_path;
#   - every Mach-O targets MACOSX_DEPLOYMENT_TARGET and has a valid signature
#     (with EXPECT_TEAM_ID set: that team and the hardened runtime);
#   - the devices, backends and accelerator ArcBox needs are compiled in;
#   - with KERNEL given, scripts/boot-test.py boots it with -kernel.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../versions.env
source "$ROOT/versions.env"

PACKAGE="${1:?usage: smoke-test.sh PACKAGE.tar.gz [KERNEL]}"
KERNEL="${2:-}"

FAILED=0
fail() { echo "FAIL $*"; FAILED=1; }
ok() { echo "ok   $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
DIR="$WORK/relocated qemu"
mkdir -p "$DIR"
tar -xzf "$PACKAGE" -C "$DIR"
QEMU="$DIR/bin/qemu-system-aarch64"
echo "Extracted to $DIR"
(cd "$DIR" && find . -type f | sort)

MACHOS=()
while IFS= read -r f; do
  file -b "$f" | grep -q '^Mach-O' && MACHOS+=("$f")
done < <(find "$DIR" -type f)
[ "${#MACHOS[@]}" -gt 0 ] || fail "no Mach-O files in package"

for f in "${MACHOS[@]}"; do
  rel="${f#"$DIR"/}"
  self="$(otool -D "$f" | tail -n +2)"
  while read -r dep; do
    [ "$dep" = "$self" ] && continue
    case "$dep" in
      /usr/lib/* | /System/Library/*) ;;
      @rpath/*) [ -f "$DIR/lib/${dep#@rpath/}" ] || fail "$rel: $dep is not in lib/" ;;
      *) fail "$rel links $dep" ;;
    esac
  done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')

  while read -r rp; do
    case "$rp" in
      @executable_path/* | @loader_path/*) ;;
      *) fail "$rel has LC_RPATH $rp" ;;
    esac
  done < <(otool -l "$f" | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }')

  minos="$(otool -l "$f" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; exit }')"
  [ "$minos" = "$MACOSX_DEPLOYMENT_TARGET" ] || fail "$rel: minos $minos, expected $MACOSX_DEPLOYMENT_TARGET"

  codesign --verify --strict "$f" 2>/dev/null || fail "$rel: invalid code signature"
  if [ -n "${EXPECT_TEAM_ID:-}" ]; then
    info="$(codesign -dv "$f" 2>&1)"
    grep -q "^TeamIdentifier=$EXPECT_TEAM_ID\$" <<<"$info" || fail "$rel: not signed by team $EXPECT_TEAM_ID"
    grep -q 'flags=.*runtime' <<<"$info" || fail "$rel: hardened runtime not enabled"
  fi
done
ok "${#MACHOS[@]} Mach-O files: system or bundled dylibs only, minos $MACOSX_DEPLOYMENT_TARGET, signatures valid"
otool -L "$QEMU"

"$QEMU" --version | head -1
grep -q "version $QEMU_VERSION" <("$QEMU" --version) || fail "qemu --version is not $QEMU_VERSION"

check_listed() { # what option names...
  local what="$1" option="$2" out name
  shift 2
  out="$("$QEMU" -M none "$option" help 2>&1)"
  for name in "$@"; do
    if grep -qE "(^|[ \"])$name([\", ]|\$)" <<<"$out"; then ok "$what $name"; else fail "$what $name missing"; fi
  done
}
check_listed device -device vhost-user-fs-pci vhost-user-vsock-pci virtio-blk-pci \
  virtio-net-pci virtio-serial-pci virtconsole virtio-rng-pci
check_listed object -object memory-backend-shm
check_listed netdev -netdev dgram vhost-user
check_listed accelerator -accel tcg
if "$QEMU" -machine help | grep -q '^virt '; then ok "machine virt"; else fail "machine virt missing"; fi

if [ -n "$KERNEL" ]; then
  python3 "$ROOT/scripts/boot-test.py" "$QEMU" "$KERNEL" || FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
  echo "smoke test FAILED"
  exit 1
fi
echo "smoke test passed"
