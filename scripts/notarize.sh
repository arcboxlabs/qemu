#!/bin/bash
# Notarize the signed, staged tree.
#
# Usage: scripts/notarize.sh [KEYCHAIN_PROFILE]   (default: arcbox-notarize)
#
# The profile is created with `xcrun notarytool store-credentials`, the same
# way arcbox-desktop's release workflow does. Notarization covers the Mach-O
# files by their code-directory hashes, so the tarball packed from the same
# tree afterwards is covered too. Bare Mach-O files cannot be stapled;
# Gatekeeper looks the ticket up online when it assesses them.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${1:-arcbox-notarize}"
STAGE_DIR="${STAGE_DIR:-$ROOT/out/stage}"
OUT_DIR="${OUT_DIR:-$ROOT/out}"

ZIP="$OUT_DIR/notarize.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$STAGE_DIR" "$ZIP"

# A rejected submission can exit non-zero; read the result either way so the
# log below explains the rejection.
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" \
  --wait --timeout 1h --output-format json >"$OUT_DIR/notarize-result.json" || true
cat "$OUT_DIR/notarize-result.json"
field() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$OUT_DIR/notarize-result.json" "$1"; }
ID="$(field id)"
STATUS="$(field status)"

xcrun notarytool log "$ID" --keychain-profile "$PROFILE" "$OUT_DIR/notarize-log.json"
cat "$OUT_DIR/notarize-log.json"
rm -f "$ZIP"

if [ "$STATUS" != "Accepted" ]; then
  echo "error: notarization $ID finished with status $STATUS" >&2
  exit 1
fi
echo "Notarization $ID accepted"
