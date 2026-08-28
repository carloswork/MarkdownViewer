import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/blocks.dart';
import 'package:markdown_viewer/markdown_theme.dart';
import 'package:markdown_widget/markdown_widget.dart';

/// DF-023: the emoji family is bundled locally and wired in as a *fallback*.
///
/// DF-024: Cascadia Mono is appended to the *proportional* fallback chain,
/// strictly after the emoji family, so the already-bundled symbol repertoire
/// covers arrows and geometric symbols in prose at zero added font bytes.
///
/// These tests prove the wiring — that the emoji family is registered, that it
/// never displaces a primary family, and that it stays strictly ahead of
/// Cascadia Mono in every proportional chain. They do not prove rendering or
/// packaging: rendering is verified in a real release build and packaging by
/// `FontManifest.json`, because `flutter test` runs on the host with a test
/// font and cannot reproduce CanvasKit font resolution.

/// The repo-relative path the code and `pubspec.yaml` both name.
const String kEmojiFontAssetPath = 'fonts/TwemojiMozilla.ttf';

const String kRobotoRegularPath = 'fonts/Roboto-Regular.ttf';
const String kRobotoItalicPath = 'fonts/Roboto-Italic.ttf';
const String kRobotoBoldPath = 'fonts/Roboto-Bold.ttf';
const String kCascadiaMonoPath = 'fonts/CascadiaMono.ttf';

/// DF-024 ordering-risk set: the 19 code points covered by **both**
/// TwemojiMozilla and Cascadia Mono, and by **neither** Roboto face.
///
/// Appending Cascadia Mono to the proportional chain puts these 19 in reach of
/// two fallback families at once. Whichever family comes first supplies the
/// glyph, so the ordering rule - emoji family strictly before the code family
/// - is the only thing keeping them rendering in colour from Twemoji rather
/// than as monochrome symbols from Cascadia Mono. Reordering the chain would
/// silently regress all 19.
///
/// This pins the *list and the ordering rule*. The *rendering* is verified in
/// a real release build; neither check substitutes for the other.
const List<int> kOrderingRiskCodePoints = <int>[
  0x2194, 0x2195, 0x25AA, 0x25AB, 0x25B6, 0x25C0, 0x25FB, 0x25FC, 0x25FD,
  0x25FE, 0x263A, 0x2640, 0x2642, 0x2660, 0x2663, 0x2665, 0x2666, 0x2B1B,
  0x2B1C,
];

MarkdownConfig _configFor(ReaderPalette palette) => buildMarkdownConfig(
  palette: palette,
  wrapCode: true,
  onLinkTap: (_) {},
);

/// Every proportional-text style the plan requires the fallback on, by name.
Map<String, TextStyle> _proportionalStyles(MarkdownConfig config) => {
  'p': config.p.textStyle,
  'h1': config.h1.style,
  'h2': config.h2.style,
  'h3': config.h3.style,
  'h4': config.h4.style,
  'h5': config.h5.style,
  'h6': config.h6.style,
  'a': config.a.style,
  'table.headerStyle': config.table.headerStyle!,
  'table.bodyStyle': config.table.bodyStyle!,
};

/// The two user-authored code styles. The fenced-code `baseStyle` is built
/// inside `CodeBlock.build`, so it is read from a pumped widget below.
Map<String, TextStyle> _inlineCodeStyle(MarkdownConfig config) => {
  'code (inline)': config.code.style,
};

final List<ReaderPalette> _palettes = [ReaderPalette.light, ReaderPalette.dark];

String _paletteName(ReaderPalette p) => p.isDark ? 'dark' : 'light';

/// Reads the fenced-code `baseStyle` by pumping a `CodeBlock` and reading the
/// style off the `Text` that renders the code itself.
Future<TextStyle> _fencedCodeBaseStyle(
  WidgetTester tester,
  ReaderPalette palette,
) async {
  const String code = 'fenced_code_sample';
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(palette),
      home: Scaffold(
        body: CodeBlock(
          code: code,
          // An empty language takes the plain (non-highlighted) path, which
          // renders the code through a single Text carrying baseStyle.
          language: '',
          palette: palette,
          wrap: true,
        ),
      ),
    ),
  );
  return tester.widget<Text>(find.text(code)).style!;
}

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final path in paths) {
    final bytes = File(path).readAsBytesSync();
    loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}

void main() {
  // ---------------------------------------------------------------------------
  // 1. Fallback registered, primaries preserved.
  // ---------------------------------------------------------------------------
  group('emoji fallback is registered and primaries are preserved', () {
    for (final palette in _palettes) {
      final name = _paletteName(palette);

      test('$name: ThemeData keeps Roboto primary and adds the emoji fallback', () {
        final theme = buildAppTheme(palette);
        final body = theme.textTheme.bodyMedium!;

        expect(body.fontFamily, kBodyFont);
        expect(body.fontFamilyFallback, contains(kEmojiFont));
        expect(body.fontFamilyFallback, contains(kCodeFont));
        expect(
          body.fontFamilyFallback!.indexOf(kEmojiFont),
          lessThan(body.fontFamilyFallback!.indexOf(kCodeFont)),
          reason: 'the emoji family must stay strictly ahead of the code family',
        );
      });

      test('$name: proportional Markdown styles keep Roboto and add the fallback', () {
        final styles = _proportionalStyles(_configFor(palette));

        expect(styles, isNotEmpty);
        styles.forEach((label, style) {
          // Either Roboto explicitly, or inherited from ThemeData - never the
          // emoji family.
          expect(
            style.fontFamily,
            anyOf(isNull, equals(kBodyFont)),
            reason: '$label must not carry a non-Roboto primary family',
          );
          expect(
            style.fontFamilyFallback,
            contains(kEmojiFont),
            reason: '$label must list the emoji family as a fallback',
          );
        });
      });

      test('$name: the emoji family is never a primary family', () {
        final theme = buildAppTheme(palette);
        final config = _configFor(palette);

        final primaries = <String?>[
          theme.textTheme.bodyMedium?.fontFamily,
          theme.textTheme.titleLarge?.fontFamily,
          ..._proportionalStyles(config).values.map((s) => s.fontFamily),
          ..._inlineCodeStyle(config).values.map((s) => s.fontFamily),
        ];

        for (final primary in primaries) {
          expect(primary, isNot(kEmojiFont));
        }
      });

      testWidgets('$name: fenced-code baseStyle never uses the emoji family as primary', (
        tester,
      ) async {
        final style = await _fencedCodeBaseStyle(tester, palette);
        expect(style.fontFamily, isNot(kEmojiFont));
      });
    }
  });

  // ---------------------------------------------------------------------------
  // 2. Code text keeps Cascadia Mono primary.
  // ---------------------------------------------------------------------------
  group('user-authored code keeps Cascadia Mono primary', () {
    for (final palette in _palettes) {
      final name = _paletteName(palette);

      test('$name: inline code keeps Cascadia Mono and adds the fallback', () {
        final style = _configFor(palette).code.style;

        expect(style.fontFamily, kCodeFont);
        expect(style.fontFamilyFallback, contains(kEmojiFont));
        expect(style.fontFamilyFallback!.last, kEmojiFont);
      });

      testWidgets('$name: fenced code keeps Cascadia Mono and adds the fallback', (
        tester,
      ) async {
        final style = await _fencedCodeBaseStyle(tester, palette);

        expect(style.fontFamily, kCodeFont);
        expect(style.fontFamilyFallback, contains(kEmojiFont));
        expect(style.fontFamilyFallback!.last, kEmojiFont);
      });
    }
  });

  // ---------------------------------------------------------------------------
  // 3. Ordering (C4).
  //
  //    DF-024 makes "the emoji family is last" deliberately untrue for
  //    *proportional* chains, where Cascadia Mono now follows it. The tail
  //    assertion is therefore replaced - not dropped - by a strictly stronger
  //    invariant: both families present, exactly once each, emoji strictly
  //    first. Code chains are asserted separately and still end with the emoji
  //    family, because kCodeFontFallback is unchanged.
  // ---------------------------------------------------------------------------
  group('fallback ordering', () {
    void expectProportionalOrdering(String label, List<String>? list) {
      expect(list, isNotNull, reason: '$label has no fallback list');
      expect(
        list!.where((f) => f == kEmojiFont).length,
        1,
        reason: '$label must list the emoji family exactly once',
      );
      expect(
        list.where((f) => f == kCodeFont).length,
        1,
        reason: '$label must list the code family exactly once',
      );
      expect(
        list.indexOf(kEmojiFont),
        lessThan(list.indexOf(kCodeFont)),
        reason:
            '$label must keep the emoji family strictly ahead of the code '
            'family, or the ordering-risk code points regress to monochrome',
      );
    }

    test('the proportional fallback constant puts the emoji family first', () {
      expectProportionalOrdering('kBodyFontFallback', kBodyFontFallback);
    });

    test('the code fallback constant is unchanged and still ends with the emoji family', () {
      expect(
        kCodeFontFallback,
        <String>[kEmojiFont],
        reason:
            'kCodeFontFallback is deliberately untouched: Cascadia Mono is '
            'already the primary family in every code style',
      );
      expect(kCodeFontFallback.last, kEmojiFont);
      expect(kCodeFontFallback.where((f) => f == kEmojiFont).length, 1);
    });

    for (final palette in _palettes) {
      final name = _paletteName(palette);

      test('$name: every proportional fallback list keeps the emoji family first', () {
        final theme = buildAppTheme(palette);
        final config = _configFor(palette);

        final lists = <String, List<String>?>{
          'theme.bodyMedium': theme.textTheme.bodyMedium?.fontFamilyFallback,
          ..._proportionalStyles(config).map(
            (label, style) => MapEntry(label, style.fontFamilyFallback),
          ),
        };

        expect(lists.length, greaterThan(1));
        lists.forEach(expectProportionalOrdering);
      });

      testWidgets('$name: both code fallback lists still end with the emoji family', (
        tester,
      ) async {
        final config = _configFor(palette);

        final lists = <String, List<String>?>{
          ..._inlineCodeStyle(config).map(
            (label, style) => MapEntry(label, style.fontFamilyFallback),
          ),
          'code (fenced)': (await _fencedCodeBaseStyle(tester, palette))
              .fontFamilyFallback,
        };

        lists.forEach((label, list) {
          expect(list, isNotNull, reason: '$label has no fallback list');
          expect(
            list,
            kCodeFontFallback,
            reason: '$label must use the unchanged code fallback chain',
          );
          expect(
            list!.last,
            kEmojiFont,
            reason: '$label must end with the emoji family',
          );
          expect(
            list.where((f) => f == kEmojiFont).length,
            1,
            reason: '$label must list the emoji family exactly once',
          );
        });
      });
    }
  });

  // ---------------------------------------------------------------------------
  // 3b. Primacy (C3). Neither fallback family may become a primary family where
  //     it would displace the intended one.
  // ---------------------------------------------------------------------------
  group('primary families are preserved', () {
    for (final palette in _palettes) {
      final name = _paletteName(palette);

      testWidgets('$name: fallback families never take over a primary slot', (
        tester,
      ) async {
        final theme = buildAppTheme(palette);
        final config = _configFor(palette);

        final proportionalPrimaries = <String, String?>{
          'theme.bodyMedium': theme.textTheme.bodyMedium?.fontFamily,
          'theme.titleLarge': theme.textTheme.titleLarge?.fontFamily,
          ..._proportionalStyles(
            config,
          ).map((label, style) => MapEntry(label, style.fontFamily)),
        };

        proportionalPrimaries.forEach((label, primary) {
          expect(
            primary,
            isNot(kEmojiFont),
            reason: '$label must never make the emoji family primary',
          );
          expect(
            primary,
            isNot(kCodeFont),
            reason:
                '$label is proportional prose: the code family is a fallback '
                'there, never a primary family',
          );
          expect(
            primary,
            anyOf(isNull, equals(kBodyFont)),
            reason: '$label must keep Roboto primary, explicitly or inherited',
          );
        });

        final codePrimaries = <String, String?>{
          ..._inlineCodeStyle(
            config,
          ).map((label, style) => MapEntry(label, style.fontFamily)),
          'code (fenced)': (await _fencedCodeBaseStyle(tester, palette))
              .fontFamily,
        };

        codePrimaries.forEach((label, primary) {
          expect(
            primary,
            kCodeFont,
            reason: '$label must keep Cascadia Mono primary',
          );
        });
      });
    }
  });

  // ---------------------------------------------------------------------------
  // 3c. Ordering-risk data lock. Pins the 19 code points and the rule that
  //     protects them. See kOrderingRiskCodePoints for why they matter.
  // ---------------------------------------------------------------------------
  group('ordering-risk data lock', () {
    test('the 19 ordering-risk code points are pinned exactly', () {
      expect(
        kOrderingRiskCodePoints.length,
        19,
        reason: 'the ordering-risk set is exhaustive by construction',
      );
      expect(
        kOrderingRiskCodePoints.toSet().length,
        kOrderingRiskCodePoints.length,
        reason: 'the set must contain no duplicates',
      );
      // A second, textual representation of the same data, so that editing any
      // single code point fails this test rather than passing silently.
      expect(
        kOrderingRiskCodePoints
            .map((c) => c.toRadixString(16).toUpperCase().padLeft(4, '0'))
            .join(' '),
        '2194 2195 25AA 25AB 25B6 25C0 25FB 25FC 25FD 25FE 263A 2640 2642 '
        '2660 2663 2665 2666 2B1B 2B1C',
      );
    });

    test('the rule that protects the ordering-risk set holds', () {
      // These 19 are reachable from two fallback families at once. The first
      // family in the chain wins, so this ordering is what keeps them coming
      // from Twemoji rather than from Cascadia Mono.
      expect(kBodyFontFallback, contains(kEmojiFont));
      expect(kBodyFontFallback, contains(kCodeFont));
      expect(
        kBodyFontFallback.indexOf(kEmojiFont),
        lessThan(kBodyFontFallback.indexOf(kCodeFont)),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 4. The font file exists at the exact registered path.
  // ---------------------------------------------------------------------------
  group('bundled font asset', () {
    test('the emoji font exists at the exact registered repo-relative path', () {
      // Deliberately a direct file check, not a pubspec.yaml parse: Source
      // declares no direct `yaml` dependency, and the build already validates
      // the manifest authoritatively.
      expect(
        File(kEmojiFontAssetPath).existsSync(),
        isTrue,
        reason: '$kEmojiFontAssetPath must exist and match the pubspec entry',
      );
    });

    test('the existing bundled fonts are still present', () {
      for (final path in [
        kRobotoRegularPath,
        kRobotoItalicPath,
        kRobotoBoldPath,
        kCascadiaMonoPath,
      ]) {
        expect(File(path).existsSync(), isTrue, reason: '$path must still exist');
      }
    });

    test('no new font binary is introduced', () {
      // DF-024 is a zero-added-font-bytes change: it reuses a font that is
      // already bundled rather than acquiring one. The test suite is one of the
      // places that guardrail is enforced, so no new font path is added above
      // and none may appear on disk.
      const declaredFontAssets = <String>[
        kRobotoRegularPath,
        kRobotoItalicPath,
        kRobotoBoldPath,
        kCascadiaMonoPath,
        kEmojiFontAssetPath,
      ];
      expect(declaredFontAssets.toSet().length, 5);

      final onDisk = Directory('fonts')
          .listSync()
          .whereType<File>()
          .map((entry) => entry.uri.pathSegments.last)
          .where((name) => name.toLowerCase().endsWith('.ttf'))
          .map((name) => 'fonts/$name')
          .toSet();

      expect(
        onDisk,
        declaredFontAssets.toSet(),
        reason:
            'fonts/ must hold exactly the font binaries already bundled at the '
            'baseline - DF-024 adds, removes, subsets and regenerates nothing',
      );
    });

    test('the emoji licence/notice file is bundled alongside the font', () {
      expect(
        File('fonts/TwemojiMozilla-LICENSE.txt').existsSync(),
        isTrue,
        reason: 'the bundled font must ship its licence and attribution notice',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 5. Vertical-metrics diagnostic (plan section 3.4.1).
  //
  //    This asserts the *instrument precondition* (the line-count guard) and
  //    reports the measured deltas. Per the Cycle 3 owner decision the deltas
  //    are diagnostic evidence: a non-zero value is NOT a failure and must not
  //    be asserted against any numeric tolerance.
  // ---------------------------------------------------------------------------
  group('vertical-metrics diagnostic', () {
    const String kMetricsControl = 'Check Cross Warning Rocket Celebration';
    const String kMetricsMixed =
        'Check ✅ Cross ❌ Warning ⚠️ Rocket 🚀 Celebration 🎉';

    test('line-count guard holds; per-line metric deltas are recorded', () async {
      await _loadFont(kBodyFont, [
        kRobotoRegularPath,
        kRobotoItalicPath,
        kRobotoBoldPath,
      ]);
      await _loadFont(kCodeFont, [kCascadiaMonoPath]);
      await _loadFont(kEmojiFont, [kEmojiFontAssetPath]);

      // Each production style is paired with the fallback list the app actually
      // applies to it: proportional styles get kBodyFontFallback, code styles
      // get kCodeFontFallback.
      const styles = <(String, TextStyle, List<String>)>[
        (
          'S1 body',
          TextStyle(
            fontFamily: kBodyFont,
            fontSize: kBodyFontSize,
            height: kBodyLineHeight,
          ),
          kBodyFontFallback,
        ),
        (
          'S2 h2',
          TextStyle(
            fontFamily: kBodyFont,
            fontSize: 23,
            height: 1.3,
            fontWeight: FontWeight.w700,
          ),
          kBodyFontFallback,
        ),
        (
          'S3 inline code',
          TextStyle(fontFamily: kCodeFont, fontSize: kBodyFontSize - 2),
          kCodeFontFallback,
        ),
        (
          'S4 fenced code',
          TextStyle(
            fontFamily: kCodeFont,
            fontSize: kBodyFontSize - 3,
            height: 1.45,
          ),
          kCodeFontFallback,
        ),
      ];

      const strings = <String, String>{
        'kMetricsControl': kMetricsControl,
        'kMetricsMixed': kMetricsMixed,
      };
      const scales = <double>[1.0, 1.60];

      ui.LineMetrics measure(String text, TextStyle style, double scale) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.linear(scale),
        );
        // Unconstrained width, so wrapping cannot affect the measurement.
        painter.layout(maxWidth: double.infinity);
        final lines = painter.computeLineMetrics();
        // The instrument precondition. A failure here means P2 did not hold and
        // the comparison is void - this is the one real assertion in this test.
        expect(
          lines.length,
          1,
          reason: 'line-count guard failed for "$text" - measurement is void',
        );
        return lines.first;
      }

      final report = StringBuffer()
        ..writeln('DF-023 vertical-metrics diagnostic (deltas are evidence, not a gate)')
        ..writeln(
          '${'style'.padRight(16)}${'string'.padRight(17)}${'scale'.padRight(7)}'
          '${'dAscent'.padLeft(11)}${'dDescent'.padLeft(11)}'
          '${'dHeight'.padLeft(10)}${'dBaseline'.padLeft(11)}',
        );

      var comparisons = 0;
      for (final (styleName, style, fallback) in styles) {
        for (final entry in strings.entries) {
          for (final scale in scales) {
            final text = entry.value;
            // Baseline: the current path, with no emoji family available.
            final baseline = measure(text, style, scale);
            // Candidate: the same style with the shipped fallback appended.
            final candidate = measure(
              text,
              style.copyWith(fontFamilyFallback: fallback),
              scale,
            );
            comparisons++;
            report.writeln(
              '${styleName.padRight(16)}${entry.key.padRight(17)}'
              '${scale.toString().padRight(7)}'
              '${(candidate.ascent - baseline.ascent).toStringAsFixed(4).padLeft(11)}'
              '${(candidate.descent - baseline.descent).toStringAsFixed(4).padLeft(11)}'
              '${(candidate.height - baseline.height).toStringAsFixed(4).padLeft(10)}'
              '${(candidate.baseline - baseline.baseline).toStringAsFixed(4).padLeft(11)}',
            );
          }
        }
      }

      expect(comparisons, 16, reason: 'all 16 comparisons must be measured');
      // Recorded, never asserted against a threshold.
      // ignore: avoid_print
      print(report.toString());
    });
  });
}
