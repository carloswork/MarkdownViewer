import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/han_script.dart';
import 'package:markdown_viewer/han_script_tables.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/print_fonts.dart';

/// DF-031 CP-C — print parity for the resolved document script.
///
/// `investigation.md` §I established that the Viewer and print already diverge
/// for CJK, and that a Viewer-only change would **invert** rather than resolve
/// that asymmetry. The plan's answer (§6) is one shared coverage rule across
/// both surfaces, with the `sans-serif` terminal kept as a deliberately
/// recorded exception. These are the properties that make that real.
///
/// They live against `lib/print_fonts.dart` rather than
/// `lib/print_surface_web.dart` because the surface sits behind the
/// `dart.library.js_interop` conditional import and cannot be loaded by a VM
/// test. The stacks, the face inventory, the derived count and the readiness
/// rule are pure functions of the resolved script and the declared faces, so
/// they are asserted here directly instead of being matched as source text.
void main() {
  // Proved Traditional and Simplified respectively by han_script_test.dart.
  const traditionalSample = '# 報告\n\n說編輯設與錯誤處請閱讀單';
  const simplifiedSample = '# 报告\n\n说编辑设与错误处请阅读单';

  /// The body of the CSS declaration block introduced by [selector].
  String block(String css, String selector, {int from = 0}) {
    final start = css.indexOf('$selector {', from);
    expect(
      start,
      greaterThan(-1),
      reason: '$selector must exist in the print stylesheet',
    );
    return css.substring(start, css.indexOf('}', start));
  }

  /// The `@media print` copy of a selector, not the `display: none` one.
  String printedBlock(String css, String selector) =>
      block(css, selector, from: css.indexOf('@media print'));

  // ---------------------------------------------------------------------------
  // §12 CP-C item 1 — the stack order comes from the resolved script.
  // ---------------------------------------------------------------------------
  group('the print stacks follow the resolved script', () {
    test('the proportional stack is the DF-026 prefix, the resolved Han '
        'order, then sans-serif', () {
      expect(
        printProportionalStack(HanScript.hans),
        '"DF026Roboto", "DF026Emoji", "DF026Mono", "DF031Hans", '
        '"DF031Hant", sans-serif',
      );
      expect(
        printProportionalStack(HanScript.hant),
        '"DF026Roboto", "DF026Emoji", "DF026Mono", "DF031Hant", '
        '"DF031Hans", sans-serif',
      );
    });

    test('the monospace stack is Cascadia, emoji, the resolved Han order, '
        'then monospace', () {
      expect(
        printMonospaceStack(HanScript.hans),
        '"DF026Mono", "DF026Emoji", "DF031Hans", "DF031Hant", monospace',
      );
      expect(
        printMonospaceStack(HanScript.hant),
        '"DF026Mono", "DF026Emoji", "DF031Hant", "DF031Hans", monospace',
      );
    });

    test('both Han families are in every stack, whichever one leads', () {
      // What makes the §5.4.3 default bounded: which pack leads changes
      // regional form, never coverage.
      for (final lead in HanScript.values) {
        expect(printHanFamiliesFor(lead), hasLength(2));
        expect(
          printHanFamiliesFor(lead).first,
          hanScriptPackFor(lead).printFamily,
        );
        expect(
          printHanFamiliesFor(lead).toSet(),
          kHanScriptPacks.map((pack) => pack.printFamily).toSet(),
        );
      }
    });

    test('the stylesheet applies the resolved order in all three stacks', () {
      for (final lead in HanScript.values) {
        final css = buildPrintCss(lead);
        expect(
          printedBlock(css, '#df026-print'),
          contains('font: 10pt/1.35 ${printProportionalStack(lead)};'),
        );
        expect(
          printedBlock(css, '#df026-print pre'),
          contains('font: 8.6pt/1.25 ${printMonospaceStack(lead)};'),
        );
        expect(
          printedBlock(css, '#df026-print code'),
          contains('font-family: ${printMonospaceStack(lead)};'),
        );
      }
    });

    test('the print stack takes the same resolveHanScript result the Viewer '
        'takes, under every preference', () {
      // The central CP-C property. Both surfaces consume one resolution rather
      // than each computing its own - which is the single mechanism that makes
      // print follow an explicit preference (plan.md §6).
      for (final source in <String>[traditionalSample, simplifiedSample]) {
        for (final preference in DocumentScriptPreference.values) {
          final document = MarkdownDocument.fromSource(
            source,
          ).copyWith(scriptPreference: preference);
          final resolved = resolveHanScriptForDocument(document);

          // The Viewer's chain and the print chain lead with the same pack.
          expect(
            printHanFamiliesFor(resolved).first,
            hanScriptPackFor(resolved).printFamily,
          );
          expect(
            hanFamiliesFor(resolved).first,
            hanScriptPackFor(resolved).family,
          );
          expect(
            buildPrintCss(resolved),
            contains(printProportionalStack(resolved)),
          );
        }
      }
    });

    test('an explicit preference overrides detection on the print side too', () {
      // Not only under `auto`: this is the case where a print surface that
      // re-derived the script from the source alone would silently disagree
      // with the Viewer, because it cannot see the preference.
      final document = MarkdownDocument.fromSource(
        traditionalSample,
      ).copyWith(scriptPreference: DocumentScriptPreference.simplifiedChinese);

      // Detection, ignoring the preference, says Traditional.
      expect(resolveHanScript(traditionalSample), HanScript.hant);
      // The resolved script - what both surfaces use - says Simplified.
      final resolved = resolveHanScriptForDocument(document);
      expect(resolved, HanScript.hans);

      expect(printProportionalStack(resolved), contains('"DF031Hans", "DF031Hant"'));
      expect(
        printProportionalStack(resolved),
        isNot(contains('"DF031Hant", "DF031Hans"')),
      );
      expect(
        printProportionalStack(resolved),
        isNot(printProportionalStack(resolveHanScript(traditionalSample))),
        reason:
            'if these matched, the print side would be following detection '
            'rather than the resolved script, and the override would be '
            'invisible in print',
      );

      // And the same for the reverse override.
      final reverse = MarkdownDocument.fromSource(
        simplifiedSample,
      ).copyWith(scriptPreference: DocumentScriptPreference.traditionalChinese);
      expect(resolveHanScript(simplifiedSample), HanScript.hans);
      expect(resolveHanScriptForDocument(reverse), HanScript.hant);
      expect(
        printMonospaceStack(resolveHanScriptForDocument(reverse)),
        contains('"DF031Hant", "DF031Hans"'),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // §12 CP-C item 4 — the terminals are retained.
  // ---------------------------------------------------------------------------
  group('the DF-026 terminals are retained', () {
    test('every stack still ends in its generic terminal', () {
      for (final lead in HanScript.values) {
        expect(printProportionalStack(lead), endsWith(', sans-serif'));
        expect(printMonospaceStack(lead), endsWith(', monospace'));
      }
    });

    test('the stylesheet keeps sans-serif and BOTH monospace terminals', () {
      // Both monospace declarations, not one: `#df026-print pre` and
      // `#df026-print code` (plan.md §7.2). Counting the occurrences is what
      // makes "both" assertable rather than assumed.
      for (final lead in HanScript.values) {
        final css = buildPrintCss(lead);
        expect(printedBlock(css, '#df026-print'), contains('sans-serif;'));
        expect(printedBlock(css, '#df026-print pre'), contains('monospace;'));
        expect(printedBlock(css, '#df026-print code'), contains('monospace;'));
        expect(
          'monospace;'.allMatches(css).length,
          2,
          reason:
              'exactly the two monospace declarations must carry the terminal',
        );
        expect('sans-serif;'.allMatches(css).length, 1);
      }
    });

    test('the terminals sit last, after the Han families', () {
      // A terminal kept but moved ahead of the bundled faces would silently
      // undo the change while still passing a "contains" check.
      for (final lead in HanScript.values) {
        for (final stack in <String>[
          printProportionalStack(lead),
          printMonospaceStack(lead),
        ]) {
          for (final pack in kHanScriptPacks) {
            expect(stack.indexOf(pack.printFamily), greaterThan(-1));
            expect(
              stack.indexOf(pack.printFamily),
              lessThan(stack.indexOf(RegExp('sans-serif|monospace'))),
            );
          }
        }
      }
    });
  });

  // ---------------------------------------------------------------------------
  // §12 CP-C item 2 — the derived face count, and failing closed.
  // ---------------------------------------------------------------------------
  group('the print face inventory', () {
    test('declares the five DF-026 faces unchanged plus the two Han faces', () {
      expect(kPrintFontFaceCount, kPrintFontFaces.length);
      expect(
        kPrintFontFaceCount,
        7,
        reason:
            'five DF-026 faces plus one face per Han pack - the count the '
            'former `!= 5` literal has to become',
      );
      expect(
        kPrintFontFaces.take(5).map((face) => face.fontShorthand).toList(),
        <String>[
          '400 10pt "DF026Roboto"',
          'italic 400 10pt "DF026Roboto"',
          '700 10pt "DF026Roboto"',
          '400 10pt "DF026Mono"',
          '400 10pt "DF026Emoji"',
        ],
        reason: 'the DF-026 load descriptors must be byte-identical',
      );
      expect(
        kPrintFontFaces.take(5).map((face) => face.probe).toList(),
        <String>['Regular', 'Italic', 'Bold', '→', '⚠️ ✅ ❌ 🎉 🚀'],
        reason: 'the DF-026 probes must be unchanged',
      );
      for (final face in kPrintFontFaces.take(5)) {
        expect(face.format, 'truetype');
      }
    });

    test('the Han faces are derived from kHanScriptPacks, not restated', () {
      final han = kPrintFontFaces.skip(5).toList();
      expect(han, hasLength(kHanScriptPacks.length));
      for (var i = 0; i < kHanScriptPacks.length; i++) {
        final pack = kHanScriptPacks[i];
        expect(han[i].family, pack.printFamily);
        expect(han[i].assetUrl, '/assets/${pack.asset}');
        expect(
          han[i].format,
          'opentype',
          reason: 'the two derivatives carry CFF outlines',
        );
        expect(han[i].weight, 400);
        expect(han[i].style, 'normal');
      }
    });

    test('every declared face has an @font-face rule, and there are no '
        'others', () {
      final css = buildPrintCss(kDefaultHanScript);
      expect('@font-face'.allMatches(css).length, kPrintFontFaceCount);
      for (final face in kPrintFontFaces) {
        expect(css, contains(face.css));
        expect(
          face.css,
          contains('font-display: block'),
          reason: 'the two new rules match the five existing ones',
        );
      }
      // The two new rules, spelled out once so a silent change to the shared
      // template is visible in the diff.
      expect(
        css,
        contains(
          '@font-face {\n'
          '  font-family: "DF031Hans";\n'
          '  src: url("/assets/fonts/SaudoHans-Regular.otf") '
          'format("opentype");\n'
          '  font-weight: 400;\n'
          '  font-style: normal;\n'
          '  font-display: block;\n'
          '}',
        ),
      );
      expect(
        css,
        contains(
          '@font-face {\n'
          '  font-family: "DF031Hant";\n'
          '  src: url("/assets/fonts/SaudoHant-Regular.otf") '
          'format("opentype");\n'
          '  font-weight: 400;\n'
          '  font-style: normal;\n'
          '  font-display: block;\n'
          '}',
        ),
      );
    });

    test('readiness fails closed when a declared face is missing', () {
      List<String> statuses(int n) => List<String>.filled(n, 'loaded');
      List<bool> probes(int n) => List<bool>.filled(n, true);

      // The happy path, at the derived count.
      expect(
        printFontsAreReady(
          loadedFaceStatuses: statuses(kPrintFontFaceCount),
          probeResults: probes(kPrintFontFaceCount),
        ),
        isTrue,
      );

      // One declared face never produced a FontFace. This is the case the
      // `!= 5` literal would have waved through the moment a sixth face was
      // declared - the fail-closed hazard the Investigation named.
      expect(
        printFontsAreReady(
          loadedFaceStatuses: statuses(kPrintFontFaceCount - 1),
          probeResults: probes(kPrintFontFaceCount - 1),
        ),
        isFalse,
      );
      // Specifically: the count the old literal used is now a failure.
      expect(
        printFontsAreReady(
          loadedFaceStatuses: statuses(5),
          probeResults: probes(5),
        ),
        isFalse,
        reason:
            'five loaded faces was the whole inventory before DF-031 and is '
            'an incomplete one after it',
      );

      // A face that arrived but did not load.
      final unloaded = statuses(kPrintFontFaceCount)..[kPrintFontFaceCount - 1] =
          'unloaded';
      expect(
        printFontsAreReady(
          loadedFaceStatuses: unloaded,
          probeResults: probes(kPrintFontFaceCount),
        ),
        isFalse,
      );

      // A probe that came back false.
      final failedProbe = probes(kPrintFontFaceCount)
        ..[kPrintFontFaceCount - 1] = false;
      expect(
        printFontsAreReady(
          loadedFaceStatuses: statuses(kPrintFontFaceCount),
          probeResults: failedProbe,
        ),
        isFalse,
      );

      // Fewer probes than declared faces - a load/check pair that was added on
      // one side only.
      expect(
        printFontsAreReady(
          loadedFaceStatuses: statuses(kPrintFontFaceCount),
          probeResults: probes(kPrintFontFaceCount - 1),
        ),
        isFalse,
      );

      // Nothing at all is not "nothing failed".
      expect(
        printFontsAreReady(
          loadedFaceStatuses: const <String>[],
          probeResults: const <bool>[],
        ),
        isFalse,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // §12 CP-C item 3 — the probes are pinned to the right exclusive set.
  // ---------------------------------------------------------------------------
  group('the Han probe characters', () {
    test('are pinned', () {
      // Pinned literally, so changing one is a visible decision rather than a
      // detail. Both are the character 'Han' itself in each convention.
      expect(kHanPrintProbes[HanScript.hans], '汉'); // U+6C49
      expect(kHanPrintProbes[HanScript.hant], '漢'); // U+6F22
      expect(kHanPrintProbes[HanScript.hans]!.runes.first, 0x6C49);
      expect(kHanPrintProbes[HanScript.hant]!.runes.first, 0x6F22);
      expect(kHanPrintProbes, hasLength(kHanScriptPacks.length));
    });

    test('are drawn from their own pack\'s exclusive set and absent from the '
        'other\'s', () {
      // This is what stops a probe passing against the wrong face: a character
      // both faces carry would report "ready" for a face that never arrived.
      const exclusive = <HanScript, List<int>>{
        HanScript.hans: kHansExclusiveRanges,
        HanScript.hant: kHantExclusiveRanges,
      };

      for (final pack in kHanScriptPacks) {
        final probe = kHanPrintProbes[pack.script]!;
        expect(
          probe.runes,
          hasLength(1),
          reason: 'a single code point keeps the check unambiguous',
        );
        final codePoint = probe.runes.first;
        final other = HanScript.values.firstWhere((s) => s != pack.script);

        expect(
          hanScriptTableContains(exclusive[pack.script]!, codePoint),
          isTrue,
          reason: '$probe must be exclusive to ${pack.printFamily}',
        );
        expect(
          hanScriptTableContains(exclusive[other]!, codePoint),
          isFalse,
          reason: '$probe must not be in the ${other.name} exclusive set',
        );
        expect(
          hanScriptTableContains(kHanUnionRanges, codePoint),
          isTrue,
          reason: '$probe must be inside the shipped union',
        );
      }
    });

    test('each probe is the face the loader asks for', () {
      // The probe travels with its face, so a reordered inventory cannot pair
      // a Simplified probe with the Traditional family.
      for (final face in kPrintFontFaces) {
        final pack = kHanScriptPacks
            .where((pack) => pack.printFamily == face.family)
            .toList();
        if (pack.isEmpty) continue;
        expect(face.probe, kHanPrintProbes[pack.single.script]);
        expect(face.fontShorthand, '400 10pt "${face.family}"');
      }
    });

    test('a probe resolves the document it is drawn from to its own pack', () {
      // A round trip through the detector: each probe character on its own is
      // decisive evidence for exactly the pack whose face it proves.
      for (final pack in kHanScriptPacks) {
        expect(
          resolveHanScript(kHanPrintProbes[pack.script]!),
          pack.script,
        );
      }
    });
  });
}
