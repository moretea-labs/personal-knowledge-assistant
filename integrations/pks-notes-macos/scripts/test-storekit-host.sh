#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
: "${PKS_NOTES_DEVELOPMENT_TEAM:?Set the Apple Development team used for local signed StoreKit tests}"

identity="${PKS_NOTES_DEVELOPMENT_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  while IFS= read -r candidate; do
    subject="$(security find-certificate -c "$candidate" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)"
    if [[ "$subject" == *"/OU=$PKS_NOTES_DEVELOPMENT_TEAM/"* ]]; then
      identity="$candidate"
      break
    fi
  done < <(security find-identity -v -p codesigning | sed -n 's/^ *[0-9][0-9]*) [0-9A-F][0-9A-F]* "\(Apple Development:.*\)"$/\1/p')
fi
: "${identity:?No Apple Development identity matches team $PKS_NOTES_DEVELOPMENT_TEAM}"

cd "$root/StoreKitTestHost"
xcodebuild \
  -project PKSNotesStoreKitHost.xcodeproj \
  -scheme PKSNotesStoreKitHost \
  -destination "platform=macOS,arch=arm64" \
  test \
  -only-testing:PKSNotesStoreKitHostTests/ProPurchaseHostTests \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$identity" \
  DEVELOPMENT_TEAM="$PKS_NOTES_DEVELOPMENT_TEAM"
