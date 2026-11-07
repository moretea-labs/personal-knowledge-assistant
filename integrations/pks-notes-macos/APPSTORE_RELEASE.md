# PKS Notes V1 — Mac App Store / Pro launch contract

## Decision (2026-11-07)

- macOS first. Defer iOS and iPadOS until Mac demand/revenue has been validated.
- Mac App Store free download plus one non-consumable **PKS Notes Pro** purchase.
- Product ID: `com.moretea.pks.notes.pro` / App bundle ID: `com.moretea.pks.notes`.
- Pro target price: CNY 98 (configure in App Store Connect; actual displayed price is `Product.displayPrice`, never hardcode a currency or amount).
- No PKS login, custom subscription, external payment workflow, proprietary server, or PKS-hosted sync.
- User-selected Markdown/PDF files remain the sole document authority. iCloud Drive is optional; no duplication.
- Free access: Markdown editing, file management, PDF reading, basic local file/filename navigation. Advanced mind map/MindNode actions and relationships are Pro.
- Treat PKS local HTTP knowledge service as optional integration, **not a mandatory login/server prerequisite**. Current PKS-related results need app-store standalone-product acceptance before submission.

## Runtime / StoreKit 2

`Sources/PKSNotes/ProPurchases.swift` is the single in-app purchase entitlement authority:
- `Product.products(for:)` resolves real storefront pricing and product type.
- `Transaction.currentEntitlements` unlocks only **verified**, non-revoked transactions matching the non-consumable product ID.
- `Transaction.updates` refreshes status including external refunds; finish verified transactions.
- User-visible pending, cancellation, error and restored-state handling.
- `AppStore.sync()` only behind a user-selected **Restore Purchases** action.
- No writable UserDefaults Boolean, plain-text license files, or server verification. Previously owned files remain editable if Pro expires/refunds.
- Test configuration: `Tests/PKSNotesTests/Resources/PKSNotes.storekit` (local fixture; never uploads to App Store).
- Real StoreKit flow acceptance lives in the minimal Xcode macOS app-host under `StoreKitTestHost/`; it compiles the canonical `ProPurchases.swift` and reuses the same fixture, so there is no second entitlement implementation. Run `scripts/test-storekit-host.sh`. The local hosted suite covers purchase/unlock, refund/revocation, explicit restore, and Ask-to-Buy pending→approval. This is deterministic local StoreKitTest evidence; Apple signing and App Store Sandbox remain separate release gates.

## Mac App Store packaging

Requirements: Apple Developer Account with accepted Paid Apps Agreement, banking/tax setup, macOS App ID and StoreKit non-consumable SKU. Distribution uses **Mac App Distribution** plus **Mac Installer Distribution** identities from the same Apple team, and a matching Mac App Store provisioning profile.

The existing `scripts/install-macos.sh` remains the local developer install path, not the App Store upload path. Shared `Resources/Info.plist` is the bundle metadata authority. `Resources/MacAppStore.entitlements` sets App Sandbox, user-selected read/write, persistent app-scoped bookmarks, and client network access.

To create an actual signed upload package after the account identities are ready, set `PKS_NOTES_APP_SIGN_IDENTITY`, `PKS_NOTES_INSTALLER_SIGN_IDENTITY`, and `PKS_NOTES_PROVISION_PROFILE`, then run `scripts/package-appstore.sh`. The script builds Apple Silicon Release, codesigns the sandboxed app and creates a signed `.pkg` for App Store upload. Do not upload ad-hoc signed `~/Applications` previews.

## App Store Connect release checklist

1. Register the **macOS** app with bundle ID `com.moretea.pks.notes`, make the app **Free**. Verify exact team and product ID before creating irreversible records.
2. Enable/accept paid-apps contracts and complete tax/banking information.
3. Under In-App Purchases create **Non-Consumable** `com.moretea.pks.notes.pro`; set reference name, simplified Chinese + English localization, pricing per territory (initial China target ¥98), availability, review screenshot.
4. Confirm Mac App Distribution and Installer identities + appropriate profile and run an actual signed sandbox build. Preserve user-selected folder bookmark across relaunch, including iCloud Drive. Verify save, rename, move to Trash, PDF, MindNode import/export, and PKS integration failure behavior.
5. Run `swift test --jobs 4`, Swift Release build, and `scripts/test-storekit-host.sh`; then run App Store Sandbox purchase/restore tests. Verify offline re-open, no duplicate charge, refunds/revocations, pending Ask to Buy and unavailable storefront behavior.
6. Prepare Mac screenshots, localization, privacy policy/support URLs, age rating, encryption/export compliance, China mainland availability and filing applicability; show a self-sufficient reviewer onboarding path **without PKS local provider**.
7. Upload the signed `.pkg` through Transporter or App Store Connect tools; submit the **first non-consumable** with the first Mac app version for review. Do not claim published before App Review approval.

## Known blockers / evidence

- Existing local machine certificates were checked on 2026-11-07: Apple Development and Developer ID Application identities exist, but **Mac App Distribution / Mac Installer Distribution** identities were not detected in the checked keychain outputs. This blocks creating a genuine App Store submission package.
- The normal local preview remains a Swift Package executable installed using an ad-hoc signature. A separate Xcode-hosted local test app validates the canonical StoreKit code with StoreKitTest: purchase/unlock, refund/revocation, explicit restore, and Ask-to-Buy pending→approval all pass. This local test host is not an App Store distribution artifact; Apple Development/App Store Sandbox verification remains required separately.
- PKS related-knowledge search uses `127.0.0.1:3217` only when the optional local PKS provider is present. If it is absent, the related section clears remote results and shows an explicit unavailable state while Markdown, file access and local backlinks remain usable; no login or custom server is required for the standalone reviewer path.
- Product configuration exists only as an Xcode StoreKit testing fixture until App Store Connect is updated. **Local StoreKit tests are not a substitute for Apple sandbox / App Review.**

References:
- https://developer.apple.com/documentation/storekit/transaction/currententitlements
- https://developer.apple.com/documentation/storekit/appstore/sync()
- https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox
- https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution
- https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/
