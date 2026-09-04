/// The print font inventory, the print font stacks, and the stylesheet built
/// from both.
///
/// Pure Dart, with no `dart:js_interop` and no `package:web` import, for the
/// same reason `print_html.dart` is pure: `print_surface_web.dart` sits behind
/// the `dart.library.js_interop` conditional import and cannot be loaded by a
/// VM test, while the properties DF-031 CP-C must assert - the resolved Han
/// order in every print stack, the retained `sans-serif` and `monospace`
/// terminals, and a face count that fails closed - are pure functions of the
/// resolved script and the declared face list. So they live here, where they
/// can be asserted directly, and `print_surface_web.dart` is left as the thin
/// DOM and CSS-injection layer that consumes them (plan.md §6, §12 CP-C).
library;

import 'han_script.dart';

/// One `@font-face` the print stylesheet declares.
///
/// The same record drives three things that previously drifted independently:
/// the `@font-face` rule, the `FontFaceSet.load`/`check` pair that proves the
/// face arrived, and the expected face count. That is why §6 item 4 replaces
/// the `loadedFaces.length != 5` literal with a count derived from this list -
/// it removes the class of defect, not only this instance.
class PrintFontFace {
  const PrintFontFace({
    required this.family,
    required this.assetUrl,
    required this.format,
    required this.weight,
    required this.style,
    required this.probe,
  });

  /// The `font-family` the print stacks name.
  final String family;

  /// The URL Flutter web serves the bundled asset from.
  final String assetUrl;

  /// The CSS `format()` hint. `truetype` for the five DF-026 TTFs; `opentype`
  /// for the two DF-031 faces, which carry CFF outlines (plan.md §6 item 1).
  final String format;

  final int weight;

  /// `normal` or `italic`.
  final String style;

  /// The text `FontFaceSet.load`/`check` is asked for.
  ///
  /// For the two Han faces this is drawn from that pack's **exclusive** set, so
  /// a probe cannot pass against the wrong face (plan.md §6 item 5). The exact
  /// characters are pinned in `test/print_fonts_test.dart`.
  final String probe;

  /// The CSS `font` shorthand that selects exactly this face.
  String get fontShorthand => style == 'normal'
      ? '$weight 10pt "$family"'
      : '$style $weight 10pt "$family"';

  /// This face's `@font-face` rule.
  String get css =>
      '@font-face {\n'
      '  font-family: "$family";\n'
      '  src: url("$assetUrl") format("$format");\n'
      '  font-weight: $weight;\n'
      '  font-style: $style;\n'
      '  font-display: block;\n'
      '}';
}

/// The probe character for each bundled Han pack.
///
/// Each is exclusive to its own pack's repertoire and absent from the other's,
/// which is what lets `FontFaceSet.check` tell the two faces apart. That is
/// asserted against the generated tables in `test/print_fonts_test.dart`.
const Map<HanScript, String> kHanPrintProbes = <HanScript, String>{
  HanScript.hans: '汉', // 汉 - Simplified-exclusive.
  HanScript.hant: '漢', // 漢 - Traditional-exclusive.
};

/// Every face the print stylesheet declares and `_loadPrintFonts` must load.
///
/// The five DF-026 faces are unchanged. The two DF-031 faces are derived from
/// `kHanScriptPacks` rather than restated, so the Viewer and print inventories
/// stay one table rather than two lists that can drift.
final List<PrintFontFace> kPrintFontFaces = List<PrintFontFace>.unmodifiable(
  <PrintFontFace>[
    const PrintFontFace(
      family: 'DF026Roboto',
      assetUrl: '/assets/fonts/Roboto-Regular.ttf',
      format: 'truetype',
      weight: 400,
      style: 'normal',
      probe: 'Regular',
    ),
    const PrintFontFace(
      family: 'DF026Roboto',
      assetUrl: '/assets/fonts/Roboto-Italic.ttf',
      format: 'truetype',
      weight: 400,
      style: 'italic',
      probe: 'Italic',
    ),
    const PrintFontFace(
      family: 'DF026Roboto',
      assetUrl: '/assets/fonts/Roboto-Bold.ttf',
      format: 'truetype',
      weight: 700,
      style: 'normal',
      probe: 'Bold',
    ),
    const PrintFontFace(
      family: 'DF026Mono',
      assetUrl: '/assets/fonts/CascadiaMono.ttf',
      format: 'truetype',
      weight: 400,
      style: 'normal',
      probe: '→',
    ),
    const PrintFontFace(
      family: 'DF026Emoji',
      assetUrl: '/assets/fonts/TwemojiMozilla.ttf',
      format: 'truetype',
      weight: 400,
      style: 'normal',
      probe: '⚠️ ✅ ❌ 🎉 🚀',
    ),
    for (final pack in kHanScriptPacks)
      PrintFontFace(
        family: pack.printFamily,
        assetUrl: '/assets/${pack.asset}',
        format: 'opentype',
        weight: 400,
        style: 'normal',
        probe: kHanPrintProbes[pack.script]!,
      ),
  ],
);

/// How many faces must load before the print surface may be exposed.
///
/// Derived, never a literal: adding a face to [kPrintFontFaces] raises the bar
/// automatically, and a declared face that fails to appear cannot lower it
/// (plan.md §6 item 4).
int get kPrintFontFaceCount => kPrintFontFaces.length;

/// Both Han print families, the resolved lead first.
///
/// The print-side mirror of `hanFamiliesFor`. Both are always present, so which
/// one leads changes regional form and never coverage.
List<String> printHanFamiliesFor(HanScript lead) => <String>[
  hanScriptPackFor(lead).printFamily,
  for (final pack in kHanScriptPacks)
    if (pack.script != lead) pack.printFamily,
];

String _stack(List<String> families, String terminal) =>
    '${families.map((family) => '"$family"').join(', ')}, $terminal';

/// The proportional print stack for [lead].
///
/// `sans-serif` is retained deliberately. It is the DF-026 design choice, and
/// it remains the safety net for everything still unsupported - Hangul, Arabic,
/// Indic, Thai, and Han outside the shipped repertoires. Removing it would
/// *remove* machine-dependent coverage (plan.md §6).
String printProportionalStack(HanScript lead) => _stack(<String>[
  'DF026Roboto',
  'DF026Emoji',
  'DF026Mono',
  ...printHanFamiliesFor(lead),
], 'sans-serif');

/// The monospace print stack for [lead], used by **both** monospace
/// declarations - `#df026-print pre` and `#df026-print code` (plan.md §7.2).
///
/// `monospace` is retained for the same reason `sans-serif` is.
String printMonospaceStack(HanScript lead) => _stack(<String>[
  'DF026Mono',
  'DF026Emoji',
  ...printHanFamiliesFor(lead),
], 'monospace');

/// Whether every declared face loaded and answered its probe.
///
/// Fails closed: a short list - a declared face that never produced a
/// `FontFace` - is a failure rather than a pass, because the expected length is
/// [kPrintFontFaceCount] rather than whatever happened to arrive.
bool printFontsAreReady({
  required List<String> loadedFaceStatuses,
  required List<bool> probeResults,
}) {
  if (loadedFaceStatuses.length != kPrintFontFaceCount) return false;
  if (probeResults.length != kPrintFontFaceCount) return false;
  return loadedFaceStatuses.every((status) => status == 'loaded') &&
      probeResults.every((ready) => ready);
}

/// The whole print stylesheet, with [lead] deciding the Han order in all three
/// stacks.
///
/// [lead] is the **resolved** script the Viewer used, passed in by the caller.
/// It is deliberately never re-derived here: the print surface cannot see the
/// document's preference, so re-deriving it would reintroduce exactly the
/// Viewer/print divergence §6 exists to prevent.
String buildPrintCss(HanScript lead) {
  final faces = kPrintFontFaces.map((face) => face.css).join('\n');
  final proportional = printProportionalStack(lead);
  final monospace = printMonospaceStack(lead);
  return '''
$faces
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
    font: 10pt/1.35 $proportional;
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
    font: 8.6pt/1.25 $monospace;
  }
  #df026-print code {
    font-family: $monospace;
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
}
