import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/markdown_theme.dart';
import 'package:markdown_viewer/reader_text_unit.dart';
import 'package:markdown_widget/markdown_widget.dart';

const _fixture = '''
Inline `status_😀_OK C:/repo/file.md 063b17d9` end.

Adjacent **strong** *emphasis* [link](https://example.test/path).

| Header | Code |
| --- | --- |
| Cell | `status_OK` |
''';

String _text(RenderParagraph p) =>
    p.text.toPlainText(includeSemanticsLabels: false);

List<Object> _truth(WidgetTester tester) => tester.allRenderObjects
    .whereType<RenderParagraph>()
    .toSet()
    .map(
      (p) => <Object>[
        _text(p),
        p
            .getBoxesForSelection(
              TextSelection(baseOffset: 0, extentOffset: _text(p).length),
            )
            .map((b) => [b.left, b.top, b.right, b.bottom, b.direction])
            .toList(),
        p.text
            .getSemanticsInformation()
            .map(
              (s) => [
                s.text,
                s.semanticsLabel,
                s.isPlaceholder,
                s.recognizer?.runtimeType.toString(),
              ],
            )
            .toList(),
      ],
    )
    .toList();

Future<Uint8List> _raster(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return Uint8List.fromList(data!.buffer.asUint8List());
  });
  return bytes!;
}

int _changed(Uint8List a, Uint8List b, Rect box, int width) {
  var changed = 0;
  for (var y = box.top.ceil(); y < box.bottom.floor(); y++) {
    for (var x = box.left.ceil(); x < box.right.floor(); x++) {
      final i = (y * width + x) * 4;
      if (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2]) {
        changed++;
      }
    }
  }
  return changed;
}

void main() {
  for (final palette in [ReaderPalette.light, ReaderPalette.dark]) {
    testWidgets('inline selection paints through tint and preserves render truth '
        '${palette.isDark ? 'dark' : 'light'}', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? copied;
      String? selected;
      final links = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String?;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      Future<Map<String, Object>> exercise(bool opaque) async {
        // Dispose prior active SelectionArea before mounting its comparator.
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        copied = null;
        selected = null;
        links.clear();
        final key = GlobalKey();
        final capture = ReaderTextUnitCapture();
        var config = buildMarkdownConfig(
          palette: palette,
          wrapCode: false,
          onLinkTap: links.add,
        );
        // Only the inline background differs in the opaque comparator.
        if (opaque) {
          config = config.copy(
            configs: [
              CodeConfig(
                style: config.code.style.copyWith(
                  backgroundColor: palette.codeBackground,
                ),
              ),
            ],
          );
        }
        final blocks = MarkdownGenerator(
          linesMargin: const EdgeInsets.symmetric(vertical: 5),
          generators: capture.generators,
          onNodeAccepted: capture.onNodeAccepted,
        ).buildWidgets(_fixture, config: config);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: palette.isDark ? Brightness.dark : Brightness.light,
            ),
            home: Scaffold(
              backgroundColor: palette.background,
              body: RepaintBoundary(
                key: key,
                child: SelectionArea(
                  onSelectionChanged: (content) =>
                      selected = content?.plainText,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: blocks,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final truth = _truth(tester);
        // allRenderObjects maps every Element to its renderObject; wrapper
        // Elements can resolve to the same paragraph. Deduplicate by object
        // identity, then still require a unique actual owner by its text.
        final paragraphs = tester.allRenderObjects
            .whereType<RenderParagraph>()
            .toSet()
            .toList();
        final payloads = <String>[];
        final painted = <int>[];
        final rectangles = <List<Object>>[];
        for (final table in [false, true]) {
          final p = paragraphs.singleWhere(
            (p) => table
                ? _text(p) == 'status_OK'
                : _text(p).startsWith('Inline status_'),
          );
          final text = _text(p);
          final start = text.indexOf('status') + 1;
          final end =
              start + 3; // Proper substring 'tat', valid UTF-16 boundaries.
          final selection = TextSelection(baseOffset: start, extentOffset: end);
          final boxes = p.getBoxesForSelection(selection);
          expect(boxes, hasLength(1));
          final local = boxes.single.toRect();
          final global = Rect.fromPoints(
            p.localToGlobal(local.topLeft),
            p.localToGlobal(local.bottomRight),
          );
          rectangles.add([
            global.left,
            global.top,
            global.right,
            global.bottom,
          ]);
          // An actual prose click clears SelectionArea; an outside-region click
          // does not reliably clear a prior ordinary range.
          await tester.tapAt(const Offset(24, 30));
          await tester.pump(const Duration(milliseconds: 700));
          final before = await _raster(tester, key);
          final gesture = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await gesture.addPointer(location: global.centerLeft);
          await gesture.down(global.centerLeft);
          await gesture.moveTo(global.centerRight);
          await gesture.up();
          await gesture.removePointer();
          await tester.pumpAndSettle();
          expect(selected, text.substring(start, end));
          final after = await _raster(tester, key);
          copied = null;
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pumpAndSettle();
          expect(copied, 'tat');
          payloads.add(copied!);
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final box = global
              .shift(-boundary.localToGlobal(Offset.zero))
              .deflate(1);
          final width = boundary.size.width.round();
          painted.add(_changed(before, after, box, width));
          await tester.tapAt(const Offset(24, 30));
          await tester.pumpAndSettle();
          expect(selected == null || selected!.isEmpty, isTrue);
          final clear = await _raster(tester, key);
          expect(_changed(before, clear, box, width), 0);
        }
        final link = paragraphs.singleWhere(
          (p) => _text(p).contains('Adjacent strong'),
        );
        final offset = _text(link).indexOf('link');
        final linkBox = link
            .getBoxesForSelection(
              TextSelection(baseOffset: offset, extentOffset: offset + 4),
            )
            .single;
        await tester.tapAt(link.localToGlobal(linkBox.toRect().center));
        await tester.pumpAndSettle();
        expect(links, ['https://example.test/path']);
        return {
          'truth': truth,
          'rectangles': rectangles,
          'payloads': payloads,
          'painted': painted,
        };
      }

      final baseline = await exercise(true);
      final candidate = await exercise(false);
      expect(candidate['truth'], baseline['truth']);
      expect(candidate['rectangles'], baseline['rectangles']);
      expect(candidate['payloads'], baseline['payloads']);
      expect(baseline['painted'], everyElement(0));
      expect(
        candidate['painted'],
        everyElement(greaterThan(0)),
        reason:
            'actual selected code interior must paint, not only adjacent prose',
      );
      // Paint regression plus empirical browser evidence establishes visibility;
      // this nonzero assertion is not a visual-usability or real-AT certificate.
    });
  }
}
