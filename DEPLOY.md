# Deploying and testing MarkdownViewer

## Two Content-Security-Policies, and why

Debug and release genuinely need different policies, so there is one for each.

`flutter run` compiles with **DDC**, which loads the app as ~750 module scripts and
then starts it with an **inline `<script>`**. Release compiles with **dart2js** to a
single external `main.dart.js` and executes no inline script at all. A
`script-src` strict enough for release therefore blocks the app from ever booting
in development — the page stays blank with:

```
Executing inline script violates the following Content Security Policy
directive 'script-src 'self' 'wasm-unsafe-eval''
```

So:

- **`web/index.html` carries the development policy.** `flutter run -d chrome`
  works out of the box, with no file editing.
- **`tool/build_web.ps1` swaps in the strict release policy** and verifies the
  result before letting the build pass.

The development policy is still restrictive where it costs nothing —
`default-src`, `font-src` and `img-src` are identical to release, so an accidental
third-party font or image fetch is caught while developing. It differs in exactly
two directives:

| Directive | Development adds | Why |
|---|---|---|
| `script-src` | `'unsafe-inline' 'unsafe-eval' blob:` | DDC's module loader and hot restart |
| `connect-src` | `ws://localhost:*`, `ws://127.0.0.1:*` (and http equivalents) | Hot reload / DWDS debug channel |

Neither relaxation permits an off-origin request.

**Both** policies allow `blob:` in `connect-src`. "Load from file" reads the
picked file through `cross_file`, which re-hydrates it from a `blob:` URL the
page created moments earlier. Without it, picking a file fails with:

```
Connecting to 'blob:http://…' violates the following Content Security Policy
directive: "connect-src 'self'". The action has been blocked.
```

A `blob:` URL is same-document and page-created and cannot address another
origin, so this permits no network egress. Do not remove it without re-testing
file loading.

## Development

```bash
flutter run -d chrome
```

Nothing else to do. Hot reload and hot restart work normally.

## Release build

```powershell
.\tool\build_web.ps1                  # base href defaults to /MarkdownViewer/
.\tool\build_web.ps1 -BaseHref /      # for serving from a domain root
```

**Use this script, not a bare `flutter build web`.** A bare build produces a
working bundle that still carries the looser development policy. The script runs:

```
flutter build web --release --no-web-resources-cdn --no-wasm-dry-run --base-href <href>
```

then replaces the block between the `<!-- CSP:BEGIN -->` / `<!-- CSP:END -->`
markers in `build/web/index.html` with the strict policy, and asserts:

- the strict `script-src` is present
- `script-src` contains no `'unsafe-inline'` and no `'unsafe-eval'`
- `connect-src` is `'self'` plus page-created `blob:`, with no localhost and
  no remote `http(s)` / `ws(s)` origins
- `font-src 'self'` survived
- development-only notes were stripped
- the base href was applied
- `.nojekyll` is present

Any failure aborts the build rather than producing a deployable bundle with a
weak policy.

Why those flags matter:

| Flag | Why |
|---|---|
| `--no-web-resources-cdn` | Bundles CanvasKit locally instead of loading it from `www.gstatic.com` at startup. |
| `--base-href /MarkdownViewer/` | GitHub Pages project sites are served from `/<repo>/`. Must start and end with `/`. |
| `--release` | Debug builds are far larger and slower; never validate reading feel on a debug build. |

`web/flutter_bootstrap.js` additionally pins `canvasKitBaseUrl: "canvaskit/"`, so the
CDN path cannot be taken even if the flag regresses (it has before —
flutter/flutter#148713).

## Testing on an iPhone over the local network

**There are two ways to do this and they are not interchangeable.** Use the right
one for the question you are asking.

| Build | Use it for | Do **not** use it for |
|---|---|---|
| **Debug** (`flutter run`) | Development, hot reload, checking that a change works at all | Performance, memory or stability judgement |
| **Release** (`tool\build_web.ps1`) | Any assessment of speed, memory or stability on a phone | — |

### Why the distinction matters

A debug build is compiled by DDC into ~750 separate module scripts, unminified,
with assertions on and no tree-shaking, plus the injected debug client. Measured
on the same machine, same real-world large document (346 KB, ~5,600 lines,
~1,450 top-level blocks), same iPhone-sized viewport:

| | Release | Debug |
|---|---|---|
| App load transfer | 10.4 MB over 15 responses | **106.4 MB over 784 responses** |
| JS heap, idle at home | 16.3 MB | **205.4 MB** |

That is roughly **12× the JS heap before the user does anything**. A debug build
that struggles on a phone tells you very little about the deployed app.

This is not theoretical: during V1 testing, Safari on an iPhone 13 mini
repeatedly reloaded the app (`A problem repeatedly occurred`) while reading a long
document served from `flutter run`. The same workflow on a **release** build —
scroll the full document, Return to main, Continue reading, Edit local copy —
completed with no reload. The release-build result strongly supports the debug
build being the practical trigger and bounds the problem for V1; it does not by
itself prove that memory consumption was the sole causal mechanism.

**If a reload ever occurs on a *release* build, that is a real defect** — capture
what you were doing and reopen the investigation. See *V1 Refinement
Investigation — Round 2* for the measurements and the remaining hypotheses.

### Debug loop (development)

```bash
flutter run -d web-server --web-hostname 0.0.0.0 --web-port 8080
```

Then open `http://<your-pc-ip>:8080` on the iPhone, on the same Wi-Fi. Allow the
port through Windows Firewall the first time.

IndexedDB works over plain HTTP, so the whole paste → read → leave → resume loop
is testable this way. Only Service Workers require HTTPS, and they affect
caching only.

Note that a plain-HTTP LAN origin is **not a secure context**, so
`navigator.clipboard` does not exist there and the code-block Copy button will
report that it needs an https connection. That is expected on this loop, not a
bug — it works on HTTPS deployments.

### Release loop (performance and stability)

Simplest form — build at the site root and serve `build/web` directly:

```powershell
.\tool\build_web.ps1 -BaseHref /
cd build\web
python -c "from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler; SimpleHTTPRequestHandler.protocol_version='HTTP/1.1'; ThreadingHTTPServer(('0.0.0.0',8080), SimpleHTTPRequestHandler).serve_forever()"
# then open http://<your-pc-ip>:8080 on the iPhone
```

To test the exact artefact that GitHub Pages will serve (base href
`/MarkdownViewer/`), build without `-BaseHref` and serve it under a matching path:

```bash
mkdir -p build/serve && cmd /c mklink /J build\serve\MarkdownViewer build\web
cd build/serve && python -c "
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
SimpleHTTPRequestHandler.protocol_version = 'HTTP/1.1'
ThreadingHTTPServer(('0.0.0.0', 8101), SimpleHTTPRequestHandler).serve_forever()"
# then open http://<your-pc-ip>:8101/MarkdownViewer/
```

Use that threaded, HTTP/1.1 form rather than plain `python -m http.server`. The
default handler is single-threaded and speaks HTTP/1.0 without keep-alive, and
Chrome resets the connection part-way through the 7 MB `canvaskit.wasm`, which
looks like a broken app rather than a broken server.

## Publishing to GitHub Pages

Publication is a release-process step, not a build step: `tool/build_web.ps1`
produces `build/web` locally and needs no remote. The steps below are what
publish that output to GitHub.

1. Create the GitHub repository and add it as a remote.
2. Publish the contents of `build/web` to the root of the orphan `gh-pages`
   branch, so no generated output enters the `master` history.
3. Confirm `.nojekyll` is present at the site root. It is committed in `web/` and
   is copied into `build/web` by the build, so it should be there automatically —
   but check. Without it, Jekyll strips Flutter's `_`-prefixed asset paths and the
   app 404s on assets with no obvious cause.
4. Leave the URL strategy alone. The app uses the default hash strategy because
   GitHub Pages cannot rewrite unknown paths to `index.html`.

### Optional size trim before publishing

`build/web/canvaskit` is ~37 MB on disk, but the browser only downloads
`canvaskit.js` + one `.wasm` (~7 MB uncompressed, ~3 MB over the wire with the
compression GitHub Pages applies). The rest is renderer variants Flutter picks
between at runtime and `.symbols` debug maps that are never fetched.

The `.symbols` files (~3 MB) are safe to delete before publishing:

```bash
rm build/web/canvaskit/*.symbols
```

Do not delete the `.wasm` variants — the runtime picker chooses among them.

## Privacy checks to repeat after any dependency change

1. Grep the build output for third-party hosts:
   ```bash
   grep -ro --binary-files=text -E "https?://[a-zA-Z0-9.-]+" build/web | grep -v localhost | sort -u
   ```
2. Load the app with the browser Network panel open. Every request must target
   the origin serving the app. Confirm the four bundled fonts
   (`Roboto-Regular/Italic/Bold`, `CascadiaMono`) load from `assets/fonts/`.
3. Paste a document containing `![x](https://example.test/a.png)` and confirm a
   placeholder appears and **no** request is made.

The Content-Security-Policy is the backstop: it blocks every off-origin request at
the browser level, so a mistake in application code degrades to a missing glyph
rather than a leak. If the app ever fails to start after a Flutter upgrade, the
CSP is the first thing to check — a new engine requirement (a worker type, a blob
URL, another inline script) shows up as a `[security]` violation in the console.
Remember there are two policies: the development one in `web/index.html` and the
release one in `tool/build_web.ps1`. A Flutter upgrade can break either
independently, so check both.

## After adding or changing a web plugin: clean first

`flutter build web` reuses a cached `web_plugin_registrant.dart`. Adding a plugin
with a web implementation (as `file_selector` has) does **not** always invalidate
that cache, so the build silently ships without the registration and the feature
fails at runtime with:

```
MissingPluginException(No implementation found for method openFile
on channel plugins.flutter.io/file_selector)
```

The app builds, analyses and tests clean — only the browser shows it. After
adding or upgrading any plugin:

```bash
flutter clean && flutter pub get && ./tool/build_web.ps1
```

## Known runtime notes

- `main.dart.js` still contains the string `https://fonts.gstatic.com/s/`. That is
  the engine's Noto fallback downloader, used only for code points no registered
  font covers. Bundling Roboto and Cascadia Mono avoids it for Latin text and
  code; the CSP blocks it outright in every case. Unusual glyphs (some emoji,
  CJK) will render as a missing-glyph box rather than being fetched. This is the
  intended trade.
- Flutter's Wasm/skwasm renderer cannot run on any iOS browser, so iPhone Safari
  uses the CanvasKit JS renderer. Nothing to configure; just don't expect the
  `--wasm` build to help there.
