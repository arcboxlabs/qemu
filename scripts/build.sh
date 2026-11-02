#!/bin/bash
# Build a relocatable qemu-system-aarch64 for Apple Silicon macOS.
#
# Produces $STAGE_DIR (default out/stage): the package tree described in
# README.md, ad-hoc signed without the hardened runtime so it runs as is.
# scripts/sign.sh re-signs it with a Developer ID for release.
#
# Environment:
#   VERSION     package version recorded in BUILD-INFO.json (default 0.0.0-dev)
#   BUILD_DIR   scratch directory (default build/)
#   STAGE_DIR   output tree (default out/stage/)
#   JOBS        parallel jobs (default: all CPUs)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../versions.env
source "$ROOT/versions.env"
export MACOSX_DEPLOYMENT_TARGET

VERSION="${VERSION:-0.0.0-dev}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
STAGE_DIR="${STAGE_DIR:-$ROOT/out/stage}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

DL="$BUILD_DIR/dl"
SRC="$BUILD_DIR/src"
DEPS="$BUILD_DIR/deps"
QEMU_SRC="$SRC/qemu-$QEMU_VERSION"
GLIB_SRC="$SRC/glib-$GLIB_VERSION"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

[ "$(uname -s)/$(uname -m)" = "Darwin/arm64" ] || die "must run on Apple Silicon macOS"
command -v pkg-config >/dev/null || die "pkg-config not found (brew install pkgconf)"

# Every configure option below is load-bearing; README.md explains each one.
QEMU_CONFIGURE_ARGS=(
  --prefix=/opt/arcbox-qemu
  --target-list=aarch64-softmmu
  # Start from nothing, so whatever Homebrew has installed on the build host
  # cannot leak in as an optional dependency.
  --without-default-features
  --enable-tcg
  --enable-vhost-user
  # vhost-net only builds on Linux (hw/net/vhost_net.c needs
  # linux/vhost_types.h), and --enable-vhost-user would otherwise pull it in.
  --disable-vhost-net
  --enable-fdt=internal
  --disable-docs
  --disable-install-blobs
)

fetch() { # url sha256 file
  local url="$1" sha="$2" out="$DL/$3"
  mkdir -p "$DL"
  if [ ! -f "$out" ] || ! echo "$sha  $out" | shasum -a 256 -c --status; then
    log "Downloading $url"
    curl -fL --retry 3 -o "$out.part" "$url"
    mv "$out.part" "$out"
  fi
  echo "$sha  $out" | shasum -a 256 -c --quiet || die "checksum mismatch for $out"
}

unpack() { # tarball dir
  if [ ! -d "$2" ]; then
    mkdir -p "$SRC"
    tar -xf "$1" -C "$SRC"
  fi
}

# --- Build tools ------------------------------------------------------------
if [ ! -x "$BUILD_DIR/venv/bin/meson" ]; then
  log "Installing meson $MESON_VERSION and ninja $NINJA_VERSION"
  python3 -m venv "$BUILD_DIR/venv"
  "$BUILD_DIR/venv/bin/pip" install --quiet --disable-pip-version-check \
    "meson==$MESON_VERSION" "ninja==$NINJA_VERSION"
fi
export PATH="$BUILD_DIR/venv/bin:$PATH"

fetch "https://download.qemu.org/qemu-$QEMU_VERSION.tar.xz" "$QEMU_SHA256" "qemu-$QEMU_VERSION.tar.xz"
fetch "https://download.gnome.org/sources/glib/${GLIB_VERSION%.*}/glib-$GLIB_VERSION.tar.xz" "$GLIB_SHA256" "glib-$GLIB_VERSION.tar.xz"
unpack "$DL/qemu-$QEMU_VERSION.tar.xz" "$QEMU_SRC"
unpack "$DL/glib-$GLIB_VERSION.tar.xz" "$GLIB_SRC"

# Only our own prefix is visible to pkg-config.
unset PKG_CONFIG_PATH
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"

# --- glib (LGPL-2.1, shipped as a dylib) -----------------------------------
# pcre2, proxy-libintl and libffi come from glib's own pinned meson wraps and
# are linked statically, so libglib depends on nothing outside macOS.
if [ ! -f "$DEPS/lib/pkgconfig/glib-2.0.pc" ]; then
  log "Building glib $GLIB_VERSION"
  rm -rf "$BUILD_DIR/glib-build"
  meson setup "$BUILD_DIR/glib-build" "$GLIB_SRC" \
    --prefix="$DEPS" --libdir=lib --buildtype=release \
    -Ddefault_library=shared \
    --force-fallback-for=libpcre2-8,libffi,intl \
    -Dpcre2:default_library=static \
    -Dlibffi:default_library=static \
    -Dproxy-libintl:default_library=static \
    -Dtests=false -Dintrospection=disabled -Dnls=disabled \
    -Ddocumentation=false -Dman-pages=disabled -Dlibelf=disabled \
    -Dsysprof=disabled -Ddtrace=disabled -Dglib_debug=disabled
  meson compile -C "$BUILD_DIR/glib-build" -j "$JOBS"
  meson install -C "$BUILD_DIR/glib-build" --quiet
fi

# --- QEMU -------------------------------------------------------------------
# Reconfigure from scratch whenever the arguments change.
STAMP="$BUILD_DIR/qemu-build/arcbox-configure-args"
if [ "$(cat "$STAMP" 2>/dev/null)" != "${QEMU_CONFIGURE_ARGS[*]}" ]; then
  log "Configuring QEMU $QEMU_VERSION"
  rm -rf "$BUILD_DIR/qemu-build"
  mkdir -p "$BUILD_DIR/qemu-build"
  (cd "$BUILD_DIR/qemu-build" && "$QEMU_SRC/configure" "${QEMU_CONFIGURE_ARGS[@]}")
  echo "${QEMU_CONFIGURE_ARGS[*]}" >"$STAMP"
fi
log "Building QEMU $QEMU_VERSION"
ninja -C "$BUILD_DIR/qemu-build" -j "$JOBS" qemu-system-aarch64-unsigned

# --- Stage ------------------------------------------------------------------
log "Staging $STAGE_DIR"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/bin" "$STAGE_DIR/lib"
BIN="$STAGE_DIR/bin/qemu-system-aarch64"
cp "$BUILD_DIR/qemu-build/qemu-system-aarch64-unsigned" "$BIN"
# Drop the debug map (paths to build-tree .o files); keep function symbols
# so crash reports still symbolicate.
strip -S "$BIN" 2>/dev/null

is_system() { case "$1" in /usr/lib/* | /System/*) return 0 ;; *) return 1 ;; esac; }

# Drop build-tree rpaths; the only search path is ../lib next to the binary.
delete_rpaths() {
  otool -l "$1" | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }' |
    while read -r rp; do install_name_tool -delete_rpath "$rp" "$1" 2>/dev/null; done
}

# Copy every non-system dylib $1 links against into lib/ and point $1 at
# @rpath/<name>. Anything not built into $DEPS (e.g. a Homebrew path) fails.
bundle_deps() {
  local file="$1" self dep path name
  self="$(otool -D "$file" | tail -n +2)"
  otool -L "$file" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    [ "$dep" = "$self" ] && continue
    is_system "$dep" && continue
    case "$dep" in
      @rpath/*) path="$DEPS/lib/${dep#@rpath/}" ;;
      "$DEPS"/*) path="$dep" ;;
      *) die "$file links $dep, which is neither a system library nor built here" ;;
    esac
    name="$(basename "$path")"
    if [ ! -f "$STAGE_DIR/lib/$name" ]; then
      cp -L "$path" "$STAGE_DIR/lib/$name"
      chmod 644 "$STAGE_DIR/lib/$name"
      install_name_tool -id "@rpath/$name" "$STAGE_DIR/lib/$name" 2>/dev/null
      delete_rpaths "$STAGE_DIR/lib/$name"
      bundle_deps "$STAGE_DIR/lib/$name"
    fi
    install_name_tool -change "$dep" "@rpath/$name" "$file" 2>/dev/null
  done
}

delete_rpaths "$BIN"
install_name_tool -add_rpath "@executable_path/../lib" "$BIN" 2>/dev/null
bundle_deps "$BIN"

# install_name_tool invalidated the linker signatures; ad-hoc sign so the
# development build runs as is. No hardened runtime here: library validation
# would reject ad-hoc dylibs.
codesign --force --sign - "$STAGE_DIR"/lib/*.dylib
codesign --force --sign - --identifier com.arcboxlabs.qemu.system-aarch64 "$BIN"

# --- Licenses ---------------------------------------------------------------
L="$STAGE_DIR/licenses"
mkdir -p "$L/qemu" "$L/glib" "$L/pcre2" "$L/proxy-libintl" "$L/dtc" "$L/berkeley-softfloat-3"
cp "$QEMU_SRC/COPYING" "$QEMU_SRC/COPYING.LIB" "$QEMU_SRC/LICENSE" "$L/qemu/"
cp "$GLIB_SRC/COPYING" "$L/glib/"
cp "$GLIB_SRC"/subprojects/pcre2-*/LICENCE* "$L/pcre2/"
cp "$GLIB_SRC"/subprojects/proxy-libintl-*/COPYING* "$L/proxy-libintl/" 2>/dev/null ||
  cp "$GLIB_SRC"/subprojects/proxy-libintl-*/LICENSE* "$L/proxy-libintl/"
cp "$QEMU_SRC"/subprojects/dtc/BSD-2-Clause "$QEMU_SRC"/subprojects/dtc/GPL "$QEMU_SRC"/subprojects/dtc/README.license "$L/dtc/"
cp "$QEMU_SRC"/subprojects/berkeley-softfloat-3/COPYING.txt "$L/berkeley-softfloat-3/"

# --- Build info -------------------------------------------------------------
COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
python3 - "$STAGE_DIR/BUILD-INFO.json" "$VERSION" "$COMMIT" "${QEMU_CONFIGURE_ARGS[@]}" <<PY
import json, sys
out, version, commit, *args = sys.argv[1:]
json.dump({
    "version": version,
    "commit": commit,
    "qemu_version": "$QEMU_VERSION",
    "glib_version": "$GLIB_VERSION",
    "macos_minimum": "$MACOSX_DEPLOYMENT_TARGET",
    "arch": "arm64",
    "executable": "bin/qemu-system-aarch64",
    "configure_args": args,
}, open(out, "w"), indent=2)
open(out, "a").write("\n")
PY

log "Done: $STAGE_DIR"
du -sh "$STAGE_DIR"/bin/* "$STAGE_DIR"/lib/*
