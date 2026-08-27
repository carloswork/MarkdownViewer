# Markdown Viewer

A calm, lightweight reader for long, structured Markdown documents.

Markdown Viewer is a Flutter web application built for one job: reading a long
technical document comfortably, on a phone or a desktop browser, and picking up
where you left off. It is a reader, not an editor and not a Markdown IDE.

## What it does

- **Open a local Markdown file.** `.md`, `.markdown`, `.mdown`, `.mkd` and
  `.txt` are accepted. The file is read in the browser; it is not uploaded.
- **Paste Markdown text** directly, for content that is not in a file.
- **Table-of-contents navigation.** Headings are extracted into a Contents
  sheet; tapping an entry jumps to that part of the document.
- **Return to your reading position.** The position in the current document is
  stored locally, so *Continue reading* returns you to where you stopped.
- **Appearance controls.** System / light / dark, an adjustable text size, and
  a choice of wrapping or horizontally scrolling long code lines.
- **Syntax-highlighted code blocks** with a copy button. (Copying needs a
  secure context, so it works over HTTPS but not over a plain-HTTP LAN address.)
- **Responsive layout.** Reading width and padding adapt from phone widths up
  to a desktop browser window.

## What it does not do

There is no cloud sync, no account, no collaboration, and no server component.
*Edit local copy* changes only the copy stored in this browser — it never writes
back to the file you opened, and there is no save or export. Native desktop and
mobile apps are not part of this project; it runs in the browser.

## Privacy and local-first behaviour

Markdown files are read locally in the browser. The application does not upload
document content to a server.

Supporting details, all verifiable in the source:

- The document, your reading position and your appearance settings are stored in
  the browser's local storage (IndexedDB, via Hive). If the browser refuses to
  open that store — Private Browsing, for instance — the app runs in memory only
  rather than failing.
- **Remote images referenced by a document are not fetched.** `![](https://…)`
  renders as a placeholder showing the URL; opening it is a deliberate tap.
- Links are handed to the browser to open in a new tab; the app makes no request
  itself. Only `http`, `https` and `mailto` links are accepted.
- Fonts are bundled with the application rather than loaded from a font CDN, so
  a cold load makes no third-party request. That includes emoji: an emoji-capable
  font is bundled and used as a fallback, so emoji in a document render from local
  files instead of being fetched at runtime.
- A Content-Security-Policy backs all of this at the browser level. Release
  builds carry a strict policy limiting `connect-src` to `'self'` and
  page-created `blob:` URLs, which cannot address another origin. See
  [DEPLOY.md](DEPLOY.md).

## Running locally

Requires the Flutter SDK (developed against Flutter 3.44.x stable / Dart 3.12).

```bash
flutter pub get
flutter run -d chrome
```

Tests:

```bash
flutter test
```

## Release build and deployment

Build with the project's script, **not** a bare `flutter build web`:

```powershell
.\tool\build_web.ps1                  # base href defaults to /MarkdownViewer/
.\tool\build_web.ps1 -BaseHref /      # for serving from a domain root
```

A bare `flutter build web` produces a bundle that still carries the looser
development Content-Security-Policy. The script performs the release build,
swaps in the strict release policy and verifies the result, failing the build
rather than emitting a weak bundle.

[DEPLOY.md](DEPLOY.md) covers the two policies and why they differ, the required
build flags, device testing over a local network, and publishing.

## Project maturity

Markdown Viewer is currently a small V1 focused on reading and navigating
Markdown documents. Expect a modest feature set and rough edges rather than a
mature tool.

## Licence

Licensed under the MIT License. See [LICENSE](LICENSE).

Bundled third-party fonts keep their own licences: see
`fonts/Roboto-LICENSE.txt`, `fonts/CascadiaMono-LICENSE.txt` and
`fonts/TwemojiMozilla-LICENSE.txt`.

### Emoji font attribution

The bundled emoji font is **Twemoji Mozilla**, redistributed unmodified.

- Emoji artwork: [Twemoji](https://github.com/jdecked/twemoji), originally created
  by Twitter, licensed under
  [CC-BY 4.0](https://creativecommons.org/licenses/by/4.0/).
- Colour font build: [twemoji-colr](https://github.com/mozilla/twemoji-colr) by the
  Mozilla Foundation, licensed under
  [Apache 2.0](https://www.apache.org/licenses/LICENSE-2.0).
- No changes were made: the font file is redistributed exactly as published.

Roboto and Cascadia Mono remain the primary text and code families; the emoji font
is only ever consulted as a fallback for characters they do not cover.
