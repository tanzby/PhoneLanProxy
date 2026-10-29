#!/bin/sh
# Builds an unsigned Release PhoneLanProxy.ipa for AltStore / SideStore, which
# re-sign it with the user's own Apple Account on install and every refresh.
# Usage: [OUT=dir] scripts/build_ipa.sh [extra xcodebuild settings...]
#   e.g. scripts/build_ipa.sh MARKETING_VERSION=1.2   (default OUT: build/)
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/build}"
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
    "$@"

APP="$ARCHIVE/Products/Applications/PhoneLanProxy.app"
if [ ! -d "$APP/PlugIns/PhoneLanProxyWidgets.appex" ]; then
    echo "error: widget extension missing from $APP" >&2
    exit 1
fi

# The archive is rebuilt every run, so move the .app instead of copying it.
mkdir -p "$STAGE/Payload"
mv "$APP" "$STAGE/Payload/"
(cd "$STAGE" && zip -qry "$IPA" Payload)
rm -rf "$STAGE"

echo "$IPA"
