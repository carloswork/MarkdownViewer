import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/markdown_theme.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/reader_screen.dart';

/// Round 2: the reading column was hard-capped at 720 px on every screen, which
/// wasted most of a desktop window. It now grows with the viewport up to
/// [kMaxProseWidth]. Mobile must be unchanged.
void main() {
  group('readerContentWidth', () {
    test('a phone uses the full width minus padding', () {
      // 390 - 2*20. This is the pre-Round-2 behaviour and must not change.
      expect(readerContentWidth(390), 350);
      expect(readerHorizontalPadding(390), 20);
    });

    test('a small tablet keeps growing', () {
      expect(readerContentWidth(768), 768 - 64);
    });

    test('growth stops at the comfortable maximum', () {
      expect(readerContentWidth(1280), kMaxProseWidth);
      expect(readerContentWidth(1920), kMaxProseWidth);
      expect(readerContentWidth(3440), kMaxProseWidth);
    });

    test('content is centred once it is capped', () {
      const viewport = 1920.0;
      final padding = readerHorizontalPadding(viewport);
      expect(viewport - 2 * padding, closeTo(kMaxProseWidth, 0.01));
    });

    test('width increases monotonically with the viewport', () {
      var previous = 0.0;
      for (final width in [
        320.0,
        390.0,
        600.0,
        768.0,
        1024.0,
        1280.0,
        1920.0,
      ]) {
        final content = readerContentWidth(width);
        expect(content, greaterThanOrEqualTo(previous));
        previous = content;
      }
    });

    test(
      'is substantially wider than the old fixed 720 on a desktop window',
      () {
        expect(readerContentWidth(1920), greaterThan(720));
      },
    );

    test('never exceeds the viewport', () {
      for (final width in [200.0, 390.0, 800.0, 1920.0]) {
        expect(readerContentWidth(width), lessThanOrEqualTo(width));
      }
    });
  });

  group('reader screen layout', () {
    Future<void> pumpAt(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(
            document: MarkdownDocument.fromSource(
              '# Heading\n\nA paragraph of body text used to measure the column.',
            ),
            settings: const Settings(),
            onSettingsChanged: (_) {},
            onEdit: () {},
            onLoadFile: () {},
            onReturnHome: () {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('phone viewport renders without overflow', (tester) async {
      await pumpAt(tester, const Size(390, 844));
      expect(tester.takeException(), isNull);
    });

    testWidgets('wide desktop viewport renders without overflow', (
      tester,
    ) async {
      await pumpAt(tester, const Size(2560, 1440));
      expect(tester.takeException(), isNull);
    });
  });
}
