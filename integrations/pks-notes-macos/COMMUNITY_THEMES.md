# Leafspan community reading themes

Theme packages are versioned, declarative JSON files with the .leafspan-theme extension. They style the native Markdown preview and editor without changing the Markdown on disk.

## Use a theme

Open Settings > Appearance > Community Themes > Import Theme. Select a local .leafspan-theme file. The imported theme opens in Preview without applying it. Choose Apply Theme to use it, or Close to retain your current theme. You can later Preview, Apply, Export or Remove installed themes from the same settings panel. Choosing any built-in theme or Revert to System Theme restores the original appearance.

## Create a theme

Copy Examples/quiet-study.leafspan-theme and edit its fields. Rename the id to a unique lowercase slug using letters, digits and hyphens (maximum 40 characters), and provide a readable name (maximum 50 characters). Keep formatVersion at 1.

The colors section defines paired light and dark #RRGGBB colors for canvas, ink, codeBackground and link. Maintain legible color contrast in both macOS appearances. Typography uses one of four system font designs (default, serif, rounded, monospaced) and a heading weight (regular, medium, semibold, bold); it also controls font size, heading scales, line/paragraph/heading spacing, reading width, quote inset, code padding/corner and list spacing. Blocks controls quotation bar thickness/opacity/italics and inline/block code scale.

A theme package must be a regular file, at most 64 KB. Bundled fonts, images, CSS, scripts, external paths, remote resources and executable plugins are not supported in format version 1. Unknown top-level keys are rejected. The importer validates identifiers, colors, readable contrast, types and numeric bounds before copying the file into Leafspan's Application Support/Themes directory. A duplicate id must be removed before a new version can be imported.

These themes affect reading presentation only. Note files, links, PDF references and Mind Maps retain their existing canonical formats.
