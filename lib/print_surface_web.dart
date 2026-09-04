import 'dart:async';
import 'dart:js_interop';

// `web` is intentionally supplied transitively by Flutter. DF-026 C2 is not
// authorized to add a dependency.
// ignore: depend_on_referenced_packages
import 'package:web/web.dart' as web;

import 'han_script.dart';
import 'print_fonts.dart';
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


Future<int> _loadPrintFonts(web.Document document) async {
  final fonts = document.fonts;
  // Loads, probes and the expected count all come from the one declared
  // inventory in `print_fonts.dart`. The count is derived rather than written
  // down, so a face cannot be declared and then silently not required
  // (plan.md §6 item 4).
  final loadedFaceSets = await Future.wait(<Future<JSArray<web.FontFace>>>[
    for (final face in kPrintFontFaces)
      fonts.load(face.fontShorthand, face.probe).toDart,
  ]);
  final loadedFaces = loadedFaceSets
      .expand((faces) => faces.toDart)
      .toList(growable: false);
  final checks = <bool>[
    for (final face in kPrintFontFaces)
      fonts.check(face.fontShorthand, face.probe),
  ];
  if (!printFontsAreReady(
    loadedFaceStatuses: <String>[
      for (final face in loadedFaces) face.status,
    ],
    probeResults: checks,
  )) {
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

PrintSurfaceLease mountPrintSurface(
  String markdownSource, {
  required HanScript script,
}) {
  final lease = _lifecycle.beginMount();
  unawaited(_mountPrintSurface(markdownSource, script, lease));
  return lease;
}

void unmountPrintSurface(PrintSurfaceLease lease) {
  if (!_lifecycle.release(lease)) return;
  _removePrintState(web.document);
}

Future<void> _mountPrintSurface(
  String markdownSource,
  HanScript script,
  PrintSurfaceLease lease,
) async {
  final document = web.document;

  _removePrintState(document);
  _showPrintStatus(document, failed: false);
  _installStatusStyle(document);

  // The stacks depend on the resolved script, which the caller passes in. It is
  // deliberately not re-derived here: this code cannot see the document's
  // preference, so re-deriving it would reintroduce exactly the Viewer/print
  // divergence §6 exists to prevent.
  final css = buildPrintCss(script);
  final style = document.getElementById(_styleId);
  if (style == null) {
    final installed = document.createElement('style')
      ..id = _styleId
      ..setAttribute('data-df026-owner', _compiledOwner)
      ..textContent = css;
    document.head!.appendChild(installed);
  } else if (style.textContent != css) {
    // The resolved script changed, so the stacks did. Replacing the sheet's
    // text re-parses its @font-face rules, which discards the CSS-connected
    // FontFace objects the cached load resolved against and re-adds them
    // unloaded - so the cache is dropped with them and the faces are loaded and
    // proven again rather than assumed still ready.
    style.textContent = css;
    _printFontsReady = null;
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
