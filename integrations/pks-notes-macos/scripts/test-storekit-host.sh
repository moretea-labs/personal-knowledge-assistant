#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
derived="${PKS_NOTES_STOREKIT_DERIVED_DATA:-/tmp/PKSNotesStoreKitHost-${UID}}"

cd "$root/StoreKitTestHost"
rm -rf "$derived"

# Keep Xcode's default "Sign to Run Locally" test-host signing here.
# It is the canonical local StoreKitTest environment and verifies all three
# StoreKit flows. Apple Development / Distribution signing belongs to the
# separate App Store Sandbox and release gates.
xcodebuild \
  -project PKSNotesStoreKitHost.xcodeproj \
  -scheme PKSNotesStoreKitHost \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$derived" \
  test \
  -only-testing:PKSNotesStoreKitHostTests/ProPurchaseHostTests
