# Changelog

## v1.2.0 — 2026-09-12

- Added a Settings screen, reached from the main screen, holding the appearance options and the new controls for documents kept in this browser.
- Added a Keep for next time choice. When it is on, the current document and your reading place are stored in this browser so you can continue after reopening. It is off by default, and while it is off a loaded document is kept only for the current visit and is not offered again after you reload or close the page.
- Added Remove saved document, which deletes the stored document and reading place from this browser and reports success only after confirming they are gone. A separate recovery action removes stored reading data that can no longer be read.
- Documents that earlier versions kept in this browser automatically are removed the first time this version starts, because Keep for next time is off by default. A pasted document that existed only in browser storage cannot be recovered afterwards. If the removal cannot be confirmed, the app says so and offers to try again.
- Saving your choice, saving a document and removing stored data are now reported separately, and each is reported only when it actually succeeded. Nothing is described as removed until its removal has been confirmed. Browser storage remains a convenience rather than a backup: you can clear it, and the browser may evict it.

## v1.1.0 — 2026-09-05

- Added bundled local Traditional and Simplified Chinese rendering support with automatic detection and a manual Language override.

## v1.0.6 — 2026-09-03

- Updated the Flutter runtime so unsupported characters no longer trigger an ongoing font-fallback retry loop. Unsupported characters may still appear as missing-glyph boxes.

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
