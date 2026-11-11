# Leafspan V1 — Mac App Store / Pro launch contract

Brand migration: update the existing App Store Connect app and IAP display names to Leafspan / Leafspan Pro before submission; retain existing bundle IDs, SKU and StoreKit product identifiers. Current source is version `1.0 (3)` and is **not uploaded**; existing App Store Connect build `2` is from an older source head and is not the release candidate for the new features.

## Decision (2026-11-07)

- macOS first. Defer iOS and iPadOS until Mac demand/revenue has been validated.
- Mac App Store free download plus one non-consumable **Leafspan Pro** purchase.
- Product ID: `com.moretea.pks.notes.pro` / App bundle ID: `com.moretea.pks.notes`.
- Pro target price: CNY 98 (configure in App Store Connect; actual displayed price is `Product.displayPrice`, never hardcode a currency or amount).
- No account login, custom subscription, external payment workflow, proprietary server, or custom sync service.
- User-selected Markdown/PDF files remain the sole document authority. iCloud Drive is optional; no duplication.
- Free access: Markdown editing, file management, PDF reading, local filename and Markdown body search. Advanced mind map/MindNode actions and relationships are Pro.
- Treat the local related-knowledge service as an optional integration, **not a mandatory login/server prerequisite**. Current related-knowledge results need app-store standalone-product acceptance before submission.

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

1. **DONE:** macOS App Store Connect app `6831932674` is registered under its current display name `PKS Notes` with bundle ID `com.moretea.pks.notes`, SKU `pks-notes-mac-2026`, primary locale en-US and first version `1.0`. Its current App Store Connect display name remains `PKS Notes`; change it to `Leafspan` and rename the IAP to `Leafspan Pro` before submission.
2. **DONE:** Paid Apps agreement, banking availability and required tax forms are verified active for the current Apple team.
3. **PARTIAL:** Non-Consumable IAP `6831933705` / `com.moretea.pks.notes.pro` exists with en-US + zh-Hans localization, all 175 current territories plus future territories, and China CNY base price `¥98.00`. A distribution-signed genuine storefront probe now returns the real USA product as Non-Consumable with `displayPrice=$13.99`; reviewer screenshot and genuine Sandbox transaction acceptance remain.
4. **DONE for packaging + Apple validation:** Mac App Distribution + Mac Installer Distribution identities and matching profile `PKS Notes Mac App Store 2026` were verified. The packaging path enforces the App Store category, profile-derived signed application/team identifiers, quarantine removal before signing, and `ITSAppUsesNonExemptEncryption=false`. The current `PKSNotes-macOS.pkg` for `1.0 (2)` at release HEAD `1f07f26` has SHA-256 `49ea25d9a0297e6e88f5265ecbf3fd3d25c6747029e527e299de0009b78c67b5`; local signature/profile/entitlement/quarantine checks pass and Apple `altool --validate-app` reports VERIFY SUCCEEDED. Development-signed App Sandbox acceptance already proved persistent user-selected Documents access. Before review submission, re-run the distribution-build smoke with an iCloud Drive workspace, save/rename/Trash, PDF, MindNode import/export, and related-knowledge-provider-absent behavior.
5. **LOCAL STOREKIT DONE / APPLE SANDBOX PARTIAL:** Swift suite on the updated source is 213 executed, 1 skipped (real iCloud File Provider acceptance), 0 failures and the canonical Xcode-hosted StoreKitTest remains 3/3 PASS (purchase/unlock→refund/revocation, explicit restore, Ask-to-Buy pending→approval). Genuine storefront product discovery and dynamic price are verified; genuine Apple Sandbox purchase/restore/refund/pending acceptance, offline re-open/no duplicate charge and unavailable-storefront behavior remain.
6. **PARTIAL:** public Support and Privacy Policy URLs are verified live on GitHub. Build `2` now carries and App Store Connect reports `usesNonExemptEncryption=false`; its beta state is `READY_FOR_BETA_TESTING` / `READY_FOR_BETA_SUBMISSION`, so the previous export-compliance blocker is resolved. Prepare final Mac screenshots, review contact/copyright, age rating, China mainland availability/filing applicability, and a self-sufficient reviewer onboarding path **without the local related-knowledge provider**.
7. **BUILD UPLOAD DONE / REVIEW NOT SUBMITTED:** build `2` is imported in App Store Connect with `processingState=VALID`, `APP_STORE_ELIGIBLE`, `IS-ON-APP-STORE-CONNECT=true`, and `usesNonExemptEncryption=false` (delivery/build ID `59742372-e452-46e1-a4ed-3703d9a4c96d`). Build `1` is superseded and must not be selected for release. Associate build `2` with macOS `1.0`, then submit the **first non-consumable** with the first Mac app version only after every remaining acceptance gate passes. Do not claim published before App Review approval.

## Known blockers / evidence

- **Resolved 2026-11-08:** Mac App Distribution and Mac Installer Distribution identities plus the matching App Store profile are present and validated. The current signed `1.0 (2)` `.pkg` at release HEAD `1f07f26` includes `origin/main@e2f2a18`, the silent automatic-restore fix, bounded stale Quick Open refresh, App Store category, profile-derived application/team entitlements, quarantine stripping, and the canonical non-exempt-encryption declaration; it passes independent app/profile/entitlement/installer-signature validation and has SHA-256 `49ea25d9a0297e6e88f5265ecbf3fd3d25c6747029e527e299de0009b78c67b5`.
- Apple Content Delivery evidence: an initial upload was rejected during import with 91109 because the downloaded provisioning profile carried `com.apple.quarantine`; that delivery never entered App Store Connect. Build `1` then imported successfully after quarantine normalization but lacked an export-compliance declaration. The canonical Info.plist now sets `ITSAppUsesNonExemptEncryption=false`; delivery `59742372-e452-46e1-a4ed-3703d9a4c96d` imported successfully as build `2` with `BUILD-STATUS=VALID`, `IMPORT-STATUS=VALID`, `APP_STORE_ELIGIBLE`, and `usesNonExemptEncryption=false`.
- App Sandbox file-access acceptance is complete at the development-signing layer: an isolated temporary bundle with the production sandbox entitlements created its own macOS container, received a real `NSOpenPanel` grant for a Documents workspace, persisted `PKSNotesWorkspaceBookmark`, created a file before quit, relaunched without showing the picker, automatically restored the workspace, and created a second file after relaunch. All temporary app/workspace/container artifacts were deleted afterward. Final iCloud Drive smoke remains tied to the actual Mac App Store-signed build.
- The Xcode-hosted local StoreKitTest app, using Xcode's `Sign to Run Locally` test signing, validates the canonical StoreKit code: **3/3 PASS** for purchase/unlock→refund/revocation, explicit restore, and Ask-to-Buy pending→approval. Final distribution-signed UI smoke remains open because multiple same-bundle development copies can coexist and the current Computer provider binds only by bundle ID, not PID; ambiguous bindings are not accepted as release evidence. Local StoreKitTest evidence still does not replace genuine Apple Sandbox acceptance.
- Local Search now reuses the Quick Open workspace projection for filename and bounded Markdown-body queries, independently of the optional knowledge provider. The optional provider at `127.0.0.1:3217` adds cross-source results; when unavailable, workspace results remain functional and the related section shows an explicit unavailable state. No login or custom server is required for the standalone reviewer path. Static/Swift acceptance is not a substitute for GUI release smoke.
- App Store Connect owns the real product configuration: IAP Apple ID `6831933705`, Product ID `com.moretea.pks.notes.pro`, China base price `¥98.00`, all current territories. A Mac App Distribution-signed probe using bundle ID `com.moretea.pks.notes` now resolves the genuine USA storefront product as Non-Consumable and returns `displayPrice=$13.99`. This proves product propagation/dynamic pricing only; **it does not substitute for Apple Sandbox transaction acceptance or App Review.**
- Public release URLs are live: Support `https://github.com/moretea-labs/personal-knowledge-assistant/blob/main/SUPPORT.md`; Privacy `https://github.com/moretea-labs/personal-knowledge-assistant/blob/main/PRIVACY.md` (both HTTP 200 verified 2026-11-08).

References:
- https://developer.apple.com/documentation/storekit/transaction/currententitlements
- https://developer.apple.com/documentation/storekit/appstore/sync()
- https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox
- https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution
- https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/
