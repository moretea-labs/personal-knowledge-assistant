#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/StoreKitTestHost"
xcodebuild \
  -project PKSNotesStoreKitHost.xcodeproj \
  -scheme PKSNotesStoreKitHost \
  -destination "platform=macOS,arch=arm64" \
  test \
  -only-testing:PKSNotesStoreKitHostTests/ProPurchaseHostTests
