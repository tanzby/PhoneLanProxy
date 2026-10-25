#!/bin/sh
# Builds an unsigned Release PhoneLanProxy.ipa for AltStore / SideStore, which
# re-sign it with the user's own Apple Account on install and every refresh.
# Usage: scripts/build_ipa.sh [output-dir [extra xcodebuild settings...]]
#   e.g. scripts/build_ipa.sh build MARKETING_VERSION=1.2   (default output: build/)
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build}"
[ $# -gt 0 ] && shift
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
ARCHIVE="$OUT/PhoneLanProxy.xcarchive"
STAGE="$OUT/ipa-stage"
IPA="$OUT/PhoneLanProxy.ipa"

rm -rf "$ARCHIVE" "$STAGE" "$IPA"

xcodebuild archive \
    -project "$ROOT/PhoneLanProxy.xcodeproj" \
    -scheme PhoneLanProxy \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    "$@"

APP="$ARCHIVE/Products/Applications/PhoneLanProxy.app"
if [ ! -d "$APP/PlugIns/PhoneLanProxyWidgets.appex" ]; then
    echo "error: widget extension missing from $APP" >&2
    exit 1
fi

mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
(cd "$STAGE" && zip -qry "$IPA" Payload)
rm -rf "$STAGE"

echo "$IPA"
