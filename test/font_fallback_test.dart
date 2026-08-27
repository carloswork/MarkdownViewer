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
/// These tests prove the wiring — that the emoji family is registered, that it
/// never displaces a primary family, and that it is always last. They do not
/// prove rendering or packaging: rendering is verified in a real release build
/// and packaging by `FontManifest.json`, because `flutter test` runs on the host
/// with a test font and cannot reproduce CanvasKit font resolution.

/// The repo-relative path the code and `pubspec.yaml` both name.
const String kEmojiFontAssetPath = 'fonts/TwemojiMozilla.ttf';

const String kRobotoRegularPath = 'fonts/Roboto-Regular.ttf';
const String kRobotoItalicPath = 'fonts/Roboto-Italic.ttf';
const String kRobotoBoldPath = 'fonts/Roboto-Bold.ttf';
const String kCascadiaMonoPath = 'fonts/CascadiaMono.ttf';

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
        expect(body.fontFamilyFallback!.last, kEmojiFont);
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
  // 3. Ordering: the emoji family is always last, and appears once.
  // ---------------------------------------------------------------------------
  group('emoji family is last in every fallback list', () {
    test('the declared fallback constants end with the emoji family', () {
      expect(kBodyFontFallback.last, kEmojiFont);
      expect(kCodeFontFallback.last, kEmojiFont);
      expect(kBodyFontFallback.where((f) => f == kEmojiFont).length, 1);
      expect(kCodeFontFallback.where((f) => f == kEmojiFont).length, 1);
    });

    for (final palette in _palettes) {
      final name = _paletteName(palette);

      testWidgets('$name: every applicable fallback list ends with the emoji family', (
        tester,
      ) async {
        final theme = buildAppTheme(palette);
        final config = _configFor(palette);

        final lists = <String, List<String>?>{
          'theme.bodyMedium': theme.textTheme.bodyMedium?.fontFamilyFallback,
          ..._proportionalStyles(config).map(
            (label, style) => MapEntry(label, style.fontFamilyFallback),
          ),
          ..._inlineCodeStyle(config).map(
            (label, style) => MapEntry(label, style.fontFamilyFallback),
          ),
          'code (fenced)': (await _fencedCodeBaseStyle(tester, palette))
              .fontFamilyFallback,
        };

        lists.forEach((label, list) {
          expect(list, isNotNull, reason: '$label has no fallback list');
          expect(
            list!.last,
            kEmojiFont,
            reason: '$label must end with the emoji family so it cannot pre-empt a primary',
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
