# Changelog

## v1.0.5 — 2026-09-01

- Release builds now keep generated `index.html` bytes consistent whether the build script is checked out with LF or CRLF line endings.

## v1.0.4 — 2026-09-01

- Release builds now write `index.html` as BOM-less UTF-8 consistently across supported PowerShell versions.

## v1.0.3 — 2026-08-31

- Printing from the browser now produces the whole document across as many pages as it needs, instead of only the part that was visible on screen. Printed pages use a light, paper-oriented layout without the application's toolbars.
- Printed output is real text rather than a picture of the screen, so it can be selected and copied from a saved PDF. Long code lines wrap instead of being cut off, and wide tables keep every column.
- If a font needed for printing cannot be loaded, the Viewer now says so instead of printing a blank page. Reload the page and try again.
- Characters outside the bundled fonts, including CJK text and emoji newer than the bundled emoji font, still show a missing-glyph box on screen. In printed output they may appear if your computer already has a font for them, so printed results for those characters vary from one computer to another.

## v1.0.2 — 2026-08-28

- Common typographic symbols such as arrows and check marks now render in body text instead of showing missing-glyph boxes.
- Characters outside the bundled fonts, including CJK text and emoji newer than the bundled emoji font, still show a missing-glyph box.

## v1.0.1 — 2026-08-27

- Emoji and common symbols in Markdown now render in colour using a bundled local fallback font.
- Some unsupported characters may still show missing glyphs, including CJK text and emoji newer than the bundled font.

## v1.0.0 — 2026-08-24

- Initial public release of Markdown Viewer.
