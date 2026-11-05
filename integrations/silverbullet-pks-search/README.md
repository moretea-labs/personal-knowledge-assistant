# PKS Search for SilverBullet

A small SilverBullet Library that exposes one `PKS: Search` command. It uses the existing PKS API and does not create a second index, database, or note store.

## Requirements

- SilverBullet Server 2.12.1 or newer, using multi-space mode.
- PKS running on the same Mac and listening on `127.0.0.1:3217`.
- The SilverBullet server must have write access to the Space so `net.proxyFetch` is available.

## Install

After this change is merged, run `Library: Install` in SilverBullet and install:

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