#!/bin/bash
# Package the staged tree and the corresponding sources.
#
# Usage: scripts/package.sh VERSION
#
# Writes to $OUT_DIR (default out/):
#   qemu-darwin-arm64-vVERSION.tar.gz (+ .sha256)          the package
#   qemu-darwin-arm64-vVERSION-sources.tar (+ .sha256)     GPL/LGPL sources

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../versions.env
source "$ROOT/versions.env"

VERSION="${1:?usage: package.sh VERSION}"
VERSION="${VERSION#v}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
STAGE_DIR="${STAGE_DIR:-$ROOT/out/stage}"
OUT_DIR="${OUT_DIR:-$ROOT/out}"
NAME="qemu-darwin-arm64-v$VERSION"

[ -x "$STAGE_DIR/bin/qemu-system-aarch64" ] || { echo "error: run scripts/build.sh first" >&2; exit 1; }
grep -q "\"version\": \"$VERSION\"" "$STAGE_DIR/BUILD-INFO.json" ||
  echo "warning: BUILD-INFO.json does not record version $VERSION (set VERSION when running build.sh)" >&2

# Flat layout, no top-level directory: the daemon extracts into its own
# versioned directory. No AppleDouble files or extended attributes.
TAR_FLAGS=(--no-xattrs --no-mac-metadata --no-acls --uid 0 --gid 0 --uname root --gname wheel)
(cd "$STAGE_DIR" && COPYFILE_DISABLE=1 tar "${TAR_FLAGS[@]}" -czf "$OUT_DIR/$NAME.tar.gz" bin lib licenses BUILD-INFO.json)

# Corresponding source: the upstream tarballs, the meson wraps glib pulled in,
# QEMU's dtc subproject (fetched by git at configure time), and this repo.
SRC_STAGE="$BUILD_DIR/sources/$NAME-sources"
rm -rf "$BUILD_DIR/sources"
mkdir -p "$SRC_STAGE/glib-subprojects"
cp "$BUILD_DIR/dl/qemu-$QEMU_VERSION.tar.xz" "$BUILD_DIR/dl/glib-$GLIB_VERSION.tar.xz" "$SRC_STAGE/"
cp "$BUILD_DIR/src/glib-$GLIB_VERSION"/subprojects/packagecache/* "$SRC_STAGE/glib-subprojects/"
tar -C "$BUILD_DIR/src/qemu-$QEMU_VERSION/subprojects" --exclude .git -czf "$SRC_STAGE/qemu-subproject-dtc.tar.gz" dtc
if git -C "$ROOT" rev-parse HEAD >/dev/null 2>&1; then
  git -C "$ROOT" archive --format=tar.gz --prefix=arcbox-qemu/ -o "$SRC_STAGE/arcbox-qemu-build.tar.gz" HEAD
else
  tar -C "$ROOT" --exclude ./build --exclude ./out -czf "$SRC_STAGE/arcbox-qemu-build.tar.gz" .
fi
(cd "$BUILD_DIR/sources" && COPYFILE_DISABLE=1 tar "${TAR_FLAGS[@]}" -cf "$OUT_DIR/$NAME-sources.tar" "$NAME-sources")

cd "$OUT_DIR"
for f in "$NAME.tar.gz" "$NAME-sources.tar"; do
  shasum -a 256 "$f" >"$f.sha256"
done
ls -l "$NAME"*
cat "$NAME.tar.gz.sha256"
