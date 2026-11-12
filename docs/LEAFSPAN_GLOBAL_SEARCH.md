# Leafspan Global Search (P4h)

## User behavior

Leafspan offers a lightweight, **optional** native global search window in
Settings > Search. Enable the global shortcut and select either Option+Space
or Control+Option+P. Hotkey registration failures are reported; Leafspan does
not steal a shortcut owned by another application. The window is also
available from the Leafspan menu without registering a global shortcut.

Type an application name to launch it. For files, Spotlight supplies the
existing macOS filename/folder index; the existing PKS local search API
supplies document content and relevance when reachable. Search results are
deduplicated by local URL and ordered to prioritize exact/prefix filename
matches over content-only hits. Arrow keys move the selection; Return
opens it; Escape closes the window. Context actions include Finder reveal
and copy path. No new persistent file index is created by the macOS app.

## Source ownership and availability

- Applications: native filesystem catalog of standard app installation
  directories and LaunchServices (read-only, no app index persisted).
- Filenames/folders: system Spotlight metadata (read-only). Its coverage
  depends on the macOS Spotlight index and system privacy settings.
- Document body, chunks, relevance and optional embeddings: **PKS**; the
  current macOS client asks the existing local service on 127.0.0.1:3217.
  If it is offline, applications and Spotlight filenames still work; the
  window indicates that content search is unavailable.
- User files and notes remain their own authority. PKS's SQLite index is
  rebuildable. Remote AI embeddings are optional, not required for search.

## Scope and security

Global search is opt-in. Spotlight does not grant extra filesystem access;
Mac App Store sandbox rules still apply to opening and reading files.
Indexing additional content in PKS requires user-configured sourceRoots
and exclusions. Do not add a separate unrestricted background daemon,
a generic executable plugin framework, or an alternate document writer.

## Known incomplete acceptance

The present implementation is not a complete HapiGo replacement yet:
pinyin/fuzzy filename matching, learned usage ranking, reliable global
shortcut takeover after uninstalling HapiGo, PDF page/Markdown section
navigation from the **global** palette, production-bundled PKS runtime,
and installed-App-Sandbox end-to-end access are not yet verified.
Existing PDF/Markdown in-app navigation remains separate and authoritative.
Do not claim full migration readiness before these checks are completed.
