#!/bin/bash
# Re-sign the staged tree with a Developer ID for distribution.
#
# Usage: scripts/sign.sh "Developer ID Application: ArcBox, Inc. (422ACSY6Y5)"
#
# Every Mach-O gets the hardened runtime and a secure timestamp. The dylibs
# are signed by the same team as the executable, so library validation
# passes without com.apple.security.cs.disable-library-validation. Only the
# executable carries entitlements (entitlements.plist).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${1:?usage: sign.sh SIGNING_IDENTITY}"
STAGE_DIR="${STAGE_DIR:-$ROOT/out/stage}"
BIN="$STAGE_DIR/bin/qemu-system-aarch64"

# Designated identifier; the daemon can pin it together with the team ID.
IDENTIFIER=com.arcboxlabs.qemu.system-aarch64

for lib in "$STAGE_DIR"/lib/*.dylib; do
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$lib"
done
codesign --force --timestamp --options runtime \
  --identifier "$IDENTIFIER" \
  --entitlements "$ROOT/entitlements.plist" \
  --sign "$IDENTITY" "$BIN"

for f in "$STAGE_DIR"/lib/*.dylib "$BIN"; do
  codesign --verify --strict --verbose=2 "$f"
done
codesign -dvv --entitlements - "$BIN" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Timestamp|CodeDirectory)|allow-jit'
