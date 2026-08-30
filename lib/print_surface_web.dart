import 'dart:async';
import 'dart:js_interop';

// `web` is intentionally supplied transitively by Flutter. DF-026 C2 is not
// authorized to add a dependency.
// ignore: depend_on_referenced_packages
import 'package:web/web.dart' as web;

import 'print_html.dart';
import 'print_surface_lifecycle.dart';

const _surfaceId = 'df026-print';
const _styleId = 'df026-print-style';
const _statusId = 'df026-print-status';
const _statusStyleId = 'df026-print-status-style';
const _compiledOwner = 'main.dart.js';

Future<int>? _printFontsReady;
final _lifecycle = PrintSurfaceLifecycle();

const _bodyStateAttribute = 'data-df026-print-state';

const _statusCss = r'''
#df026-print-status {
  position: fixed;
  z-index: 2147483647;
  right: 16px;
  bottom: 16px;
  left: 16px;
  box-sizing: border-box;
  max-width: 42rem;
  padding: 12px 14px;
  border: 2px solid #8a6d00;
  border-radius: 8px;
  color: #202124;
  background: #fff8d8;
  box-shadow: 0 3px 12px rgb(0 0 0 / 25%);
  font-size: 14px;
  line-height: 1.4;
  pointer-events: none;
}
#df026-print-status[data-df026-state="error"] {
  border-color: #b3261e;
  background: #fce8e6;
}
#df026-print-status h2 {
  margin: 0 0 4px;
  font-size: 16px;
  line-height: 1.3;
}
#df026-print-status p {
  margin: 0;
}
@media print {
  @page {
    size: A4 portrait;
    margin: 12mm;
  }
  html,
  body {
    position: static !important;
    inset: auto !important;
    width: auto !important;
    height: auto !important;
    min-height: 0 !important;
    overflow: visible !important;
    background: white !important;
    color: black !important;
  }
  body[data-df026-print-state="status"] >
    *:not(#df026-print-status):not(#df026-print) {
    display: none !important;
  }
  #df026-print-status {
    display: block !important;
    position: static !important;
    box-shadow: none !important;
    color: black !important;
    background: white !important;
  }
}
''';

const _printCss = r'''
@font-face {
  font-family: "DF026Roboto";
  src: url("/assets/fonts/Roboto-Regular.ttf") format("truetype");
  font-weight: 400;
  font-style: normal;
  font-display: block;
}
@font-face {
  font-family: "DF026Roboto";
  src: url("/assets/fonts/Roboto-Italic.ttf") format("truetype");
  font-weight: 400;
  font-style: italic;
  font-display: block;
}
@font-face {
  font-family: "DF026Roboto";
  src: url("/assets/fonts/Roboto-Bold.ttf") format("truetype");
  font-weight: 700;
  font-style: normal;
  font-display: block;
}
@font-face {
  font-family: "DF026Mono";
  src: url("/assets/fonts/CascadiaMono.ttf") format("truetype");
  font-weight: 400;
  font-style: normal;
  font-display: block;
}
@font-face {
  font-family: "DF026Emoji";
  src: url("/assets/fonts/TwemojiMozilla.ttf") format("truetype");
  font-weight: 400;
  font-style: normal;
  font-display: block;
}
#df026-print {
  display: none;
}
@media print {
  @page {
    size: A4 portrait;
    margin: 12mm;
  }
  html,
  body {
    position: static !important;
    inset: auto !important;
    width: auto !important;
    height: auto !important;
    min-height: 0 !important;
    overflow: visible !important;
    background: white !important;
    color: black !important;
  }
  body[data-df026-print-state="ready"] >
    *:not(#df026-print):not(#df026-print-status) {
    display: none !important;
  }
  body[data-df026-print-state="ready"] flutter-view {
    display: none !important;
  }
  #df026-print {
    display: block !important;
    position: static !important;
    box-sizing: border-box;
    width: auto !important;
    max-width: none !important;
    overflow: visible !important;
    font: 10pt/1.35 "DF026Roboto", "DF026Emoji", "DF026Mono", sans-serif;
    color: black;
    background: white;
  }
  #df026-print h1 {
    font-size: 18pt;
  }
  #df026-print h2 {
    font-size: 14pt;
    break-after: avoid;
  }
  #df026-print h3 {
    font-size: 11pt;
    break-after: avoid;
  }
  #df026-print p,
  #df026-print ul,
  #df026-print ol,
  #df026-print blockquote,
  #df026-print pre,
  #df026-print table {
    margin: 0 0 7pt;
  }
  #df026-print blockquote {
    margin-left: 12pt;
    padding-left: 8pt;
    border-left: 2pt solid #777;
  }
  #df026-print pre {
    box-sizing: border-box;
    max-width: 100%;
    padding: 5pt;
    overflow: visible;
    background: #f3f3f3;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    word-break: break-word;
    font: 8.6pt/1.25 "DF026Mono", "DF026Emoji", monospace;
  }
  #df026-print code {
    font-family: "DF026Mono", "DF026Emoji", monospace;
  }
  #df026-print table {
    box-sizing: border-box;
    width: 100%;
    max-width: 100%;
    table-layout: fixed;
    border-collapse: collapse;
    font-size: 8.6pt;
  }
  #df026-print th,
  #df026-print td {
    box-sizing: border-box;
    min-width: 0;
    border: 0.5pt solid #777;
    padding: 2pt;
    overflow-wrap: anywhere;
    word-break: break-word;
  }
  #df026-print thead {
    display: table-header-group;
  }
  #df026-print hr {
    border: 0;
    border-top: 0.5pt solid #777;
  }
  #df026-print a {
    color: inherit;
  }
}
''';

Future<int> _loadPrintFonts(web.Document document) async {
  final fonts = document.fonts;
  final loadedFaceSets = await Future.wait(<Future<JSArray<web.FontFace>>>[
    fonts.load('400 10pt "DF026Roboto"', 'Regular').toDart,
    fonts.load('italic 400 10pt "DF026Roboto"', 'Italic').toDart,
    fonts.load('700 10pt "DF026Roboto"', 'Bold').toDart,
    fonts.load('400 10pt "DF026Mono"', '→').toDart,
    fonts.load('400 10pt "DF026Emoji"', '⚠️ ✅ ❌ 🎉 🚀').toDart,
  ]);
  final loadedFaces = loadedFaceSets
      .expand((faces) => faces.toDart)
      .toList(growable: false);
  final checks = <bool>[
    fonts.check('400 10pt "DF026Roboto"', 'Regular'),
    fonts.check('italic 400 10pt "DF026Roboto"', 'Italic'),
    fonts.check('700 10pt "DF026Roboto"', 'Bold'),
    fonts.check('400 10pt "DF026Mono"', '→'),
    fonts.check('400 10pt "DF026Emoji"', '⚠️ ✅ ❌ 🎉 🚀'),
  ];
  if (loadedFaces.length != 5 ||
      loadedFaces.any((face) => face.status != 'loaded') ||
      checks.any((ready) => !ready)) {
    throw StateError('The bundled print font stack did not become ready.');
  }
  await fonts.ready.toDart;
  if (fonts.status != 'loaded') {
    throw StateError(
      'The document font set did not settle after print loading.',
    );
  }
  return loadedFaces.length;
}

PrintSurfaceLease mountPrintSurface(String markdownSource) {
  final lease = _lifecycle.beginMount();
  unawaited(_mountPrintSurface(markdownSource, lease));
  return lease;
}

void unmountPrintSurface(PrintSurfaceLease lease) {
  if (!_lifecycle.release(lease)) return;
  _removePrintState(web.document);
}

Future<void> _mountPrintSurface(
  String markdownSource,
  PrintSurfaceLease lease,
) async {
  final document = web.document;

  _removePrintState(document);
  _showPrintStatus(document, failed: false);
  _installStatusStyle(document);

  var style = document.getElementById(_styleId);
  if (style == null) {
    style = document.createElement('style')
      ..id = _styleId
      ..setAttribute('data-df026-owner', _compiledOwner)
      ..textContent = _printCss;
    document.head!.appendChild(style);
  }

  // `display:none` defers CSS font discovery until printing. Start every
  // bundled print face from product code at mount time and expose the printable
  // DOM only after those promises resolve. A caller can therefore print the
  // instant #df026-print exists without racing an asynchronous beforeprint
  // callback or falling away from the reader's bundled fallback chain.
  final fontsReady = _printFontsReady ??= _loadPrintFonts(document);
  late final int loadedFaceCount;
  try {
    loadedFaceCount = await fontsReady;
  } on Object {
    if (!_lifecycle.isCurrent(lease)) return;
    // A rejected CSS FontFace remains failed even if the asset later becomes
    // available. Drop both the cached Future and the stylesheet that owns
    // those faces so a later reader mount can construct and load fresh faces.
    if (identical(_printFontsReady, fontsReady)) {
      _printFontsReady = null;
    }
    document.getElementById(_styleId)?.remove();
    document.getElementById(_surfaceId)?.remove();
    _showPrintStatus(document, failed: true);
    return;
  }

  if (!_lifecycle.isCurrent(lease)) return;

  document.getElementById(_surfaceId)?.remove();
  final surface = document.createElement('main')
    ..id = _surfaceId
    ..setAttribute('aria-label', 'Printable document')
    ..setAttribute('data-df026-owner', _compiledOwner)
    ..setAttribute('data-df026-fonts', 'loaded')
    ..setAttribute('data-df026-font-count', '$loadedFaceCount')
    ..setAttribute('data-df026-font-set-status', document.fonts.status)
    ..innerHTML = buildPrintHtml(markdownSource).toJS;
  document.body!.appendChild(surface);
  document.body!.setAttribute(_bodyStateAttribute, 'ready');
  document.getElementById(_statusId)?.remove();
  document.getElementById(_statusStyleId)?.remove();
}

void _removePrintState(web.Document document) {
  document.getElementById(_surfaceId)?.remove();
  document.getElementById(_statusId)?.remove();
  document.getElementById(_statusStyleId)?.remove();
  document.body?.removeAttribute(_bodyStateAttribute);
}

void _installStatusStyle(web.Document document) {
  if (document.getElementById(_statusStyleId) != null) return;
  final style = document.createElement('style')
    ..id = _statusStyleId
    ..setAttribute('data-df026-owner', _compiledOwner)
    ..textContent = _statusCss;
  document.head!.appendChild(style);
}

void _showPrintStatus(web.Document document, {required bool failed}) {
  final status =
      document.getElementById(_statusId) ?? document.createElement('section');
  status
    ..id = _statusId
    ..setAttribute('data-df026-owner', _compiledOwner)
    ..setAttribute('data-df026-state', failed ? 'error' : 'pending')
    ..setAttribute('role', failed ? 'alert' : 'status')
    ..setAttribute('aria-live', failed ? 'assertive' : 'polite')
    ..setAttribute('aria-atomic', 'true')
    ..textContent = '';

  final heading = document.createElement('h2')
    ..textContent = failed
        ? 'Printing is not ready'
        : 'Preparing this document for printing';
  final detail = document.createElement('p')
    ..textContent = failed
        ? 'A bundled print font could not be loaded. The document is still '
              'available; reload the page, then try printing again.'
        : 'Bundled print fonts are still loading. Wait for this message to '
              'disappear, then print again.';
  status
    ..appendChild(heading)
    ..appendChild(detail);

  if (status.parentNode == null) {
    document.body!.appendChild(status);
  }
  document.body!.setAttribute(_bodyStateAttribute, 'status');
}
