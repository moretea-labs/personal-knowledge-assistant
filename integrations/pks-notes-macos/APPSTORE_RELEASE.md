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
- Real StoreKit flow acceptance lives in the minimal Xcode macOS app-host under `StoreKitTestHost/`; it compiles the canonical `ProPurchases.swift` and reuses the same fixture, so there is no second entitlement implementation. Run `scripts/test-storekit-host.sh`. For this **local StoreKitTest** path, intentionally keep Xcode's default `Sign to Run Locally` test-host signing: direct acceptance on Xcode 27 verified all three flows (purchase/unlock→refund/revocation, explicit restore, Ask-to-Buy pending→approval). Forcing a personal Apple Development CMS identity changes local StoreKit device-verification behavior and is not equivalent local-test evidence. Real Apple Development/Distribution signing and App Store Sandbox remain separate release gates.

## Mac App Store packaging

Requirements: Apple Developer Account with accepted Paid Apps Agreement, banking/tax setup, macOS App ID and StoreKit non-consumable SKU. Distribution uses **Mac App Distribution** plus **Mac Installer Distribution** identities from the same Apple team, and a matching Mac App Store provisioning profile.

The existing `scripts/install-macos.sh` remains the local developer install path, not the App Store upload path. Shared `Resources/Info.plist` is the bundle metadata authority. `Resources/MacAppStore.entitlements` sets App Sandbox, user-selected read/write, persistent app-scoped bookmarks, and client network access.

To create an actual signed upload package after the account identities are ready, set `PKS_NOTES_APP_SIGN_IDENTITY`, `PKS_NOTES_INSTALLER_SIGN_IDENTITY`, and `PKS_NOTES_PROVISION_PROFILE`, then run `scripts/package-appstore.sh`. The script builds Apple Silicon Release, codesigns the sandboxed app and creates a signed `.pkg` for App Store upload. Do not upload ad-hoc signed `~/Applications` previews.

Submission copy, reviewer notes, privacy declaration intent, IAP metadata, and screenshot planning live in `APPSTORE_METADATA.md`. Keep that file aligned with the shipped build; do not create irreversible App Store Connect records from placeholders.

## App Store Connect release checklist

1. **DONE:** macOS App Store Connect app `6831932674` is registered as `PKS Notes` with bundle ID `com.moretea.pks.notes`, SKU `pks-notes-mac-2026`, primary locale en-US and first version `1.0`.
2. **PENDING VERIFICATION:** enable/accept the Paid Apps agreement and complete tax/banking information.
3. **PARTIAL:** Non-Consumable IAP `6831933705` / `com.moretea.pks.notes.pro` exists with en-US + zh-Hans localization, all 175 current territories plus future territories, and China CNY base price `¥98.00`; reviewer screenshot and genuine Sandbox acceptance remain.
4. **DONE for packaging:** Mac App Distribution + Mac Installer Distribution identities and matching profile `PKS Notes Mac App Store 2026` were verified. `scripts/package-appstore.sh` produced and independently validated `PKSNotes-macOS.pkg` for `1.0 (1)` with SHA-256 `f3b5ad7df4655a302775ebf18890f5ff184f8a21af41ad5c35cbcc5ad9f4aad7`. Development-signed App Sandbox acceptance already proved persistent user-selected Documents access. Before submission, re-run the distribution-build smoke with an iCloud Drive workspace, save/rename/Trash, PDF, MindNode import/export, and PKS-provider-absent behavior.
5. Run `swift test --jobs 4`, Swift Release build, and `scripts/test-storekit-host.sh`; then run App Store Sandbox purchase/restore tests. Verify offline re-open, no duplicate charge, refunds/revocations, pending Ask to Buy and unavailable storefront behavior.
6. Prepare Mac screenshots, localization, privacy policy/support URLs, age rating, encryption/export compliance, China mainland availability and filing applicability; show a self-sufficient reviewer onboarding path **without PKS local provider**.
7. Upload the signed `.pkg` through Transporter or App Store Connect tools; submit the **first non-consumable** with the first Mac app version for review. Do not claim published before App Review approval.

## Known blockers / evidence

- **Resolved 2026-11-07:** Mac App Distribution and Mac Installer Distribution identities plus the matching App Store profile are present and validated. The genuine signed `1.0 (1)` `.pkg` now exists and passes independent app/profile/entitlement/installer-signature validation.
- App Sandbox file-access acceptance is complete at the development-signing layer: an isolated temporary bundle with the production sandbox entitlements created its own macOS container, received a real `NSOpenPanel` grant for a Documents workspace, persisted `PKSNotesWorkspaceBookmark`, created a file before quit, relaunched without showing the picker, automatically restored the workspace, and created a second file after relaunch. All temporary app/workspace/container artifacts were deleted afterward. Final iCloud Drive smoke remains tied to the actual Mac App Store-signed build.
- The sole local PKS Notes preview is now the verified App Store-signed `1.0 (1)` app copied from the packaging output. A separate Xcode-hosted local StoreKitTest app, using Xcode's `Sign to Run Locally` test signing, validates the canonical StoreKit code: **3/3 PASS** for purchase/unlock→refund/revocation, explicit restore, and Ask-to-Buy pending→approval. Local StoreKitTest evidence still does not replace genuine Apple Sandbox acceptance.
- PKS related-knowledge search uses `127.0.0.1:3217` only when the optional local PKS provider is present. If it is absent, the related section clears remote results and shows an explicit unavailable state while Markdown, file access and local backlinks remain usable; no login or custom server is required for the standalone reviewer path.
- App Store Connect now owns the real product configuration: IAP Apple ID `6831933705`, Product ID `com.moretea.pks.notes.pro`, China base price `¥98.00`, all current territories. **Local StoreKit tests are still not a substitute for Apple Sandbox / App Review.**

References:
- https://developer.apple.com/documentation/storekit/transaction/currententitlements
- https://developer.apple.com/documentation/storekit/appstore/sync()
- https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox
- https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution
- https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/
