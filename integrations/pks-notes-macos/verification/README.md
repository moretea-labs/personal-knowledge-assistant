# Leafspan verification records

## Selected icon authority and replacement protection

The user requested that the current ivory/apricot note icon be committed and remain discoverable so later work cannot accidentally restore an older design. `Resources/LeafspanIcon-master.png` is the sole artwork source; `Resources/AppIcon-1024.png` and `Resources/AppIcon.icns` are derived exports. `Resources/AppIcon.sha256` pins all three.

- The Swift exporter refuses to write outputs if the master differs from the pinned artwork.
- `python3 scripts/verify-app-icon.py` checks the three hashes and `CFBundleIconFile=AppIcon`. The installer, App Store packager and CI invoke it.
- Failed checks require inspection/restoration from Git, not silently regenerating the manifest. An explicit user-requested redesign may update the master, exports, manifest and this record together.
- Isolated positive/negative guard checks are recorded in [`icon-lock-2026-11-12.json`](icon-lock-2026-11-12.json). Their scope excludes real installation and unrelated feature acceptance.

Record each completed check with its exact scope and artifact identity. Reuse a passed check when its inputs and relevant environment are unchanged; rerun only affected checks after a change. Asset checks do not certify application functionality or release readiness.

## 2026-11-12 — light note with muted apricot border (current)

- User requested a combination of image two and three: paler orange border, retaining the rest of the third image’s light effect.
- Built-in Imagegen edit: use the neutral light icon as the base and the orange note as the cover-placement reference; recolor only the folded notebook border to low-saturation apricot (main-face target approximately `#E8B18C`), keeping the ivory outer tile, white page, graphite strokes, geometry and soft shadows.
- Updated the canonical master, 1024 PNG and ICNS. Ten sizes, RGBA alpha and ICNS extraction passed; fingerprints are in [`icon-apricot-2026-11-12.json`](icon-apricot-2026-11-12.json).
- Prior variant records retain their original hashes and are historical evidence. No unrelated feature acceptance was repeated; installed-app/Dock review remains separate.

## 2026-11-12 — user-selected neutral light note icon (prior colorway)

The user explicitly chose this version: “那就用这个”.

- Design: ivory tile, pale stone folded cover, white note page and three graphite writing strokes. The recognizable note silhouette replaces the empty abstract aperture. No botanical motif or vivid orange/red.
- Master: `Resources/LeafspanIcon-master.png`. Outputs: `Resources/AppIcon-1024.png`, `Resources/AppIcon.icns`; ten native iconset entries spanning 16–1024 pixels.
- Generation command: `swift scripts/generate-app-icon.swift` from the app package directory. Every output derives from the same selected master.
- Completed checks and asset SHA-256 fingerprints: [`icon-light-2026-11-12.json`](icon-light-2026-11-12.json). Ten sizes, RGBA alpha and ICNS extraction passed. Master was visually inspected; user selection is recorded separately from technical validation.
- Tool: built-in Imagegen edit. Final prompt: “Preserve the folded notebook silhouette, inner note page and three writing strokes. Change the charcoal tile to warm ivory; replace vivid orange/red with pale stone gray, white paper and medium graphite strokes, with very subtle muted blue-gray in the inner fold. Restrained matte paper depth and clean transparency; no bright accents, leaves, letters or extra objects.”
- Installed-app/Dock review was not performed by these asset checks. No alternate application was created, and no running bundle was overwritten.
- Existing unrelated dirty functionality changes were preserved. Do not repeat Swift/StoreKit/iCloud acceptance for this artwork-only revision.

## Superseded directions

- Botanical and P-shaped directions: superseded by the user's request to avoid inferring a leaf from the name.
- Empty abstract folded-span direction: user requested a more recognizable relationship to notes. Historical checks in [`icon-2026-11-12.json`](icon-2026-11-12.json) refer to that old artwork and must not be reused for the current master.
- Orange-red note variant: user requested a lighter, quieter palette; it was a design iteration, not the selected final icon.
