# PKS Search for SilverBullet

A small SilverBullet Library that exposes one `PKS: Search` command. It uses the existing PKS API and does not create a second index, database, or note store.

## Requirements

- SilverBullet Server 2.12.1 or newer, using multi-space mode.
- PKS running on the same Mac and listening on `127.0.0.1:3217`.
- The SilverBullet server must have write access to the Space so `net.proxyFetch` is available.

## Install

In SilverBullet, run `Library: Install` and install:

`https://github.com/moretea-labs/personal-knowledge-assistant/blob/main/integrations/silverbullet-pks-search/Library/greyson/PKS%20Search.md`

The library installs as `Library/greyson/PKS Search` and adds `PKS: Search` to the command palette.

## Behavior

- Search calls `GET /api/search` through SilverBullet's authenticated server proxy.
- The library calls the current Space's `/.ping` endpoint through the same proxy and reads its `x-space-path` header.
- A local result is opened only when its absolute PKS URI is proven to be under that exact Space root. The `.md` suffix is removed for SilverBullet page navigation.
- Other results use `GET /api/read/:documentId?maxChars=8000` and display a read-only preview. The PKS endpoint caps returned characters but currently reads the source before slicing.
- Search previews are not written into the Space.

## Security and ownership

- The browser never connects directly to PKS; `net.proxyFetch` performs the request from the SilverBullet server.
- Keep PKS bound to loopback. Do not expose port 3217 publicly.
- The library only performs GET requests. It does not modify PKS or note files.
- iCloud Markdown files remain canonical. MindNode, XMind, OPML, iThoughts and draw.io files are not converted. Notion page clippings are outside this library's scope.

## Mac local deployment and verification

SilverBullet Server is separate from the Forge Runtime and PKS. The macOS arm64 `2.12.1` server release is `silverbullet-server-darwin-aarch64.zip` (SHA-256 `cd83db88e1759e929eadd5f78130a41f0d4c8ed150a3fa79c914fb8985721c37`). Do not substitute the `sb-darwin-aarch64.zip` CLI.

Local installation layout used for initial verification:

- Executable: `~/.local/opt/silverbullet/2.12.1/silverbullet`
- Server data/config: `~/.local/share/silverbullet/server`
- Disposable test Space: `~/.local/share/silverbullet/test-space`
- Loopback server: `http://127.0.0.1:3218/`
- macOS login agent: `~/Library/LaunchAgents/com.greyson.silverbullet.plist` (`RunAtLoad` and `KeepAlive`); it invokes the server with `-L 127.0.0.1 -p 3218`
- Optional local application launcher: `~/Applications/SilverBullet Notes.app` (opens the browser URL)

An empty server data folder redirects to `/.setup/`. In the first-run wizard create a private admin account and bind the **test** Space folder, keeping anonymous access `none`. Do not store credentials in Git or expose the setup wizard on the LAN. After first-run setup, verify `GET /.dashboard/api/profile` works with login and the unauthenticated `GET /.fs/index.md` is denied. The `PKS Search.md` Library in the disposable Space can then be tested through the command palette.

To inspect the local service:

```sh
launchctl print "gui/$(id -u)/com.greyson.silverbullet"
curl -I http://127.0.0.1:3218/
lsof -nP -iTCP:3218 -sTCP:LISTEN
```

To stop/restart **only SilverBullet** (never Forge or PKS):

```sh
launchctl bootout "gui/$(id -u)/com.greyson.silverbullet"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.greyson.silverbullet.plist"
```

The real iCloud vault must not be bound during initial installation. Before enabling it, take a source-file baseline/backup, verify exact-folder editing and attachment semantics, restrict sensitive directories through separate Spaces and access roles (not just `sync.ignore`), and test Mac/iPhone PWA offline synchronization and conflict handling. iPhone access requires a trusted private-network TLS endpoint; the Mac-only `127.0.0.1` service is not accessible from the phone. Keep PKS port `3217` on loopback. Uninstalling the server must not delete the canonical iCloud notes.

For non-ASCII queries, URL-encode **each UTF-8 byte** once. Lua patterns iterate by byte; do not re-encode bytes as Unicode code points (which breaks Chinese searches).
