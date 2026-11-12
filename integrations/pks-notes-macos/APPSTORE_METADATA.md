# Leafspan — App Store Connect Metadata Draft

This file is the submission-copy authority for the first macOS App Store release. Keep it synchronized with the shipped feature set. Do not put a fixed Pro price in metadata; StoreKit/App Store Connect owns storefront pricing.

## App identity

- Bundle ID: `com.moretea.pks.notes`
- App name (en-US / zh-Hans): `Leafspan` (target; App Store Connect rename pending)
- Primary category draft: Productivity
- App price: Free
- Pro model: one Non-Consumable In-App Purchase
- Pro Product ID: `com.moretea.pks.notes.pro`
- App Store Connect App ID: `6831932674`
- App Store Connect IAP Apple ID: `6831933705`
- App Store Connect SKU: `pks-notes-mac-2026`
- First macOS version: `1.0 (1)`
- Sign-in required: No

## Required external values before submission

These values must be real, public, and verified before creating the final submission:

- Support URL: `https://github.com/moretea-labs/personal-knowledge-assistant/blob/main/SUPPORT.md` — **VERIFIED public (HTTP 200, 2026-11-08)**
- Privacy Policy URL: `https://github.com/moretea-labs/personal-knowledge-assistant/blob/main/PRIVACY.md` — **VERIFIED public (HTTP 200, 2026-11-08)**
- App Review contact name: **REQUIRED**
- App Review contact email: **REQUIRED**
- App Review contact phone in international format: **REQUIRED**
- Copyright owner/year: **REQUIRED**
- Final App Store Connect SKU: `pks-notes-mac-2026` — **VERIFIED**

Do not invent placeholders in App Store Connect.

## en-US

### Subtitle

Local Markdown & Mind Maps

### Description

Leafspan is a native macOS workspace for people who keep their knowledge in plain Markdown files.

Your notes stay in the folder you choose. There is no account, custom sync service, subscription, or proprietary document format.

Free features:
- Open and manage an existing Markdown folder.
- Create, edit, rename, move, search, and preview Markdown notes.
- Preview PDFs alongside your notes.
- Use Quick Open, Recent, Favorites, document outline, wiki links, and basic local search/navigation.
- Keep working even when the optional local related-knowledge service is unavailable.

Leafspan Pro is a one-time in-app purchase that unlocks advanced knowledge tools:
- Editable mind maps backed by the same Markdown file.
- MindNode interoperability and portable outline exchange.
- Backlinks, related-knowledge, and relationship views.

Your existing Markdown and PDF files remain accessible and editable even if a Pro entitlement is unavailable or later revoked.

### Keywords

markdown,notes,knowledge,mind map,outline,pdf,wiki,backlinks,local files

### Promotional text draft

Own your notes as plain Markdown. Edit locally, visualize outlines as mind maps, and unlock advanced knowledge tools with a one-time Pro purchase.

## zh-Hans

### Subtitle

本地 Markdown 与思维导图

### Description

Leafspan 是一款原生 macOS 知识笔记工具，面向希望把资料长期保存在普通 Markdown 文件中的用户。

你的笔记始终保存在自己选择的文件夹中。Leafspan 不要求注册账号，不依赖自建同步服务器，不采用订阅制，也不会把文档锁进专有格式。

免费功能：
- 打开并管理已有 Markdown 文件夹。
- 新建、编辑、重命名、移动、搜索和预览 Markdown 笔记。
- 在笔记工作区中预览 PDF。
- 使用快速打开、最近使用、收藏、文档大纲、Wiki 链接和基础本地搜索/导航。
- 即使可选的本地相关知识服务不可用，也可以继续正常管理和编辑文件。

Leafspan Pro 为一次性 App 内购买，解锁高级知识功能：
- 基于同一 Markdown 文件的可编辑思维导图。
- MindNode 互通与可移植的大纲交换。
- 反向链接、相关知识与关系视图。

即使 Pro 权益暂时不可用或之后被撤销，你已有的 Markdown 与 PDF 文件仍可继续访问和编辑。

### Keywords

Markdown,笔记,知识库,思维导图,大纲,PDF,双链,反向链接,本地文件

### Promotional text draft

笔记始终是你自己的 Markdown 文件。原生本地编辑、思维导图，以及一次性买断解锁的高级知识能力。

## App Privacy declaration draft

Current implementation intent:

- Select **No, we do not collect data from this app** only after confirming the release build contains no analytics, ads, telemetry, developer-operated account service, or third-party SDK that collects user data.
- User documents remain in the local/iCloud folder selected by the user.
- StoreKit purchase processing is handled by Apple; Leafspan does not run a custom payment or entitlement server.
- The optional related-knowledge service runs locally; its absence must not block Markdown/file workflows.
- Markdown can contain user-provided external links or images; those destinations are selected by the user's content, not a Leafspan data-collection service.

The public privacy policy must accurately describe the final release behavior.

### Current source/dependency audit (2026-11-07)

- Direct package graph: MarkdownUI → NetworkImage and swift-cmark only.
- Source scan finds no analytics, advertising, telemetry, crash-reporting or tracking SDK integration. The only fixed application network endpoint is the optional local related-knowledge service at `127.0.0.1:3217`; user-authored Markdown may also reference external images/links selected by the user's own content.
- No `PrivacyInfo.xcprivacy` is added solely for Required Reason APIs in this macOS-only V1: Apple's current Required Reason API platform list does not include macOS. Re-check Apple submission requirements and the final dependency graph immediately before upload.
- App Store Connect App Privacy answers are still mandatory. Select “No, we do not collect data from this app” only if the final release audit remains consistent with the implementation above.

## Non-Consumable IAP

- Type: Non-Consumable
- Reference Name: `Leafspan Pro`
- Product ID: `com.moretea.pks.notes.pro`
- Initial China pricing intent: target approximately CNY ¥98 in App Store Connect. Never hardcode this price in the app or metadata; the app displays `Product.displayPrice`.

### en-US

- Display Name: `Leafspan Pro`
- Description: `Mind maps, MindNode and knowledge links`

### zh-Hans

- Display Name: `Leafspan Pro`
- Description: `思维导图、MindNode 与知识关联`

### IAP review notes draft

Leafspan Pro is a one-time non-consumable purchase. It unlocks editable mind maps, MindNode interoperability, and related-knowledge views. Core Markdown/PDF/file management remains free.

To review:
1. Open any Markdown note.
2. Choose the Mind Map control, or open Settings → Pro.
3. Complete the purchase with the App Store Sandbox account.
4. Verify the Pro feature becomes available.
5. Use Restore Purchases in Settings → Pro to verify restore behavior.

No account or demo login is required.

## App Review notes draft

Leafspan does not require an account or sign-in.

The app works with a folder chosen by the reviewer. Choose any writable folder containing Markdown files, or choose an empty writable folder and create notes in the app. File access uses the macOS user-selected-folder sandbox entitlement and persistent security-scoped bookmarks.

Core Markdown, PDF, file management, Quick Open, basic search/navigation, and wiki-link workflows are free. Backlinks and related-knowledge relationship views are part of Pro.

Leafspan Pro is one non-consumable in-app purchase. Pro unlocks editable mind maps, MindNode interoperability, and related-knowledge views. Use the App Store Sandbox account supplied by Apple for purchase testing. Restore Purchases is available in Settings → Pro.

The optional local related-knowledge service is not required for review. If it is unavailable, the Pro relationship view shows an unavailable related-knowledge state while normal local Markdown/file workflows continue; local backlinks remain available inside that Pro relationship view.

No custom server, custom payment system, subscription, or user account is used.

## Screenshot plan

Use real app UI with synthetic/non-personal demo notes only. Do not expose the developer's personal workspace.

Mac screenshots:
- Exact size: 1440 × 900 px, 16:10, PNG without alpha.
- Prepare both en-US and zh-Hans sets if the UI text differs materially.

Recommended set:
1. Local Markdown workspace — editor/preview with sidebar and a synthetic note.
2. Search and knowledge navigation — Quick Open/search/wiki/backlink workflow.
3. Pro mind map — clearly identify in surrounding metadata that Mind Map is a Pro feature requiring the one-time IAP.
4. Settings → Pro — use as the IAP App Review screenshot and show the actual StoreKit purchase/restore UI.

Before capture:
- switch to a dedicated synthetic demo workspace;
- hide personal filenames/content;
- use the actual shipping build and current UI;
- restore the developer's original workspace/preferences after capture.

## Submission gates

Do not submit until all are true:

- Mac App Distribution + Mac Installer Distribution identities exist in the correct team.
- Matching macOS App Store provisioning profile exists for `com.moretea.pks.notes`.
- `scripts/package-appstore.sh` succeeds and validates profile/team/entitlements/pkg signature.
- App Store Connect app + non-consumable IAP exist and agreements/tax/banking are ready.
- Apple Sandbox purchase, restore, refund/revocation, Ask-to-Buy approval, dynamic price, and unavailable-storefront paths pass.
- Security-scoped folder bookmark survives relaunch with a sandboxed signed build, including iCloud Drive.
- Support URL, Privacy Policy URL, Review contact, copyright, and final screenshots are supplied.
- Standalone reviewer flow works with the optional local related-knowledge provider absent.
