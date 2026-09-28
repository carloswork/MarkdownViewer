import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/markdown_theme.dart';
import 'package:markdown_viewer/reader_text_unit.dart';
import 'package:markdown_widget/markdown_widget.dart';

/// DF-052 CP1 make-or-break fidelity gate (plan.md §5.7, §15).
///
/// Proves that the occurrence-tagged render is byte-for-byte equivalent to the
/// default render across every ordinary supported owner class — the exit
/// criterion that decides whether the list-item widget-composition adapter (and
/// the heading/blockquote/cell `childrenSpan` routes) can bind common text/ID
/// ownership through public/app composition, or whether CP1 must route M-04.
///
/// Equivalence is asserted on the three deterministic render-truth metrics for
/// every `RenderParagraph` in document order — flattened text, paragraph
/// selection rectangles, and computed semantics — plus a settled
/// `SelectionArea` select-all/copy comparison (which additionally proves the
/// list marker / `SelectionContainer.disabled` exclusion is preserved).

/// A fixture exercising every owner class and route the gate must cover:
/// divider heading, no-divider heading, prose across formatting/link
/// boundaries, blockquote, aligned + linked table cells, and ordered /
/// unordered / nested / task list items, plus code and Unicode.
const String fidelityFixture = '''
# Divider heading one

## Divider heading two

### Plain heading three

Intro paragraph with `inline code`, a [link](https://example.test/p) and some
**bold** and *italic* text, then 中文搜尋測試 and emoji 😀 ❤️ 👍🏽 👨‍👩‍👧‍👦.

> A blockquote that matters, with a [quoted link](https://example.test/q).

![diagram alt](https://example.test/pics/architecture.png)

| Left | Center | Right |
| :--- | :---: | ---: |
| a1 | [cell link](https://example.test/c) | c1 |
| a1 | mid 中文 | c1 |

1. First ordered finding
2. Second ordered finding
   - nested bullet with **emphasis**
     - deeper bullet 中文
- Plain unordered item
- [x] Completed task
- [ ] Outstanding task 😀

```dart
void main() {
  print('hello 中文');
}
```
''';

List<Widget> _build(String markdown, {required bool tagged}) {
  final capture = tagged ? ReaderTextUnitCapture() : null;
  return MarkdownGenerator(
    linesMargin: const EdgeInsets.symmetric(vertical: 5),
    generators: capture?.generators ?? const [],
    onNodeAccepted: capture?.onNodeAccepted,
  ).buildWidgets(
    markdown,
    config: buildMarkdownConfig(
      palette: ReaderPalette.light,
      wrapCode: false,
      onLinkTap: (_) {},
    ),
  );
}

Widget _frame(List<Widget> blocks, {bool selectable = false}) {
  final content = SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: blocks,
    ),
  );
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 600,
          child: selectable ? SelectionArea(child: content) : content,
        ),
      ),
    ),
  );
}

List<RenderParagraph> _paragraphs(WidgetTester tester) =>
    tester.allRenderObjects.whereType<RenderParagraph>().toList();

String _paraText(RenderParagraph p) =>
    p.text.toPlainText(includeSemanticsLabels: false);

String _paraRects(RenderParagraph p) {
  final len = _paraText(p).length;
  final boxes = p.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: len),
  );
  return boxes
      .map(
        (b) =>
            '${b.left.toStringAsFixed(2)},${b.top.toStringAsFixed(2)},'
            '${b.right.toStringAsFixed(2)},${b.bottom.toStringAsFixed(2)},'
            '${b.direction}',
      )
      .join('|');
}

// Normalises recognizer identity: each build creates a fresh
// TapGestureRecognizer for links, whose toString embeds a per-instance hash
// (present even between two default renders), so compare its runtimeType and
// the semantics-visible fields, not the instance id.
String _paraSemantics(RenderParagraph p) => p.text
    .getSemanticsInformation()
    .map(
      (i) =>
          'text=${i.text}|label=${i.semanticsLabel}|'
          'placeholder=${i.isPlaceholder}|'
          'recognizer=${i.recognizer?.runtimeType}',
    )
    .join('||');

void main() {
  testWidgets(
    'tagged render matches default render: text, rectangles, semantics',
    (tester) async {
      await tester.pumpWidget(_frame(_build(fidelityFixture, tagged: false)));
      await tester.pumpAndSettle();
      final defaultParas = _paragraphs(tester);
      final defaultText = defaultParas.map(_paraText).toList();
      final defaultRects = defaultParas.map(_paraRects).toList();
      final defaultSem = defaultParas.map(_paraSemantics).toList();

      await tester.pumpWidget(_frame(_build(fidelityFixture, tagged: true)));
      await tester.pumpAndSettle();
      final taggedParas = _paragraphs(tester);
      final taggedText = taggedParas.map(_paraText).toList();
      final taggedRects = taggedParas.map(_paraRects).toList();
      final taggedSem = taggedParas.map(_paraSemantics).toList();

      // Same number of drawing paragraphs, in the same order.
      expect(
        taggedParas.length,
        defaultParas.length,
        reason: 'tagged render produced a different RenderParagraph count',
      );
      // Identical flattened text per owner (the link-added space, inline code,
      // emphasis, Chinese and emoji all fall out here).
      expect(taggedText, defaultText, reason: 'paragraph text diverged');
      // Identical paragraph selection geometry per owner.
      expect(taggedRects, defaultRects, reason: 'paragraph rectangles diverged');
      // Identical computed semantics per owner.
      expect(taggedSem, defaultSem, reason: 'paragraph semantics diverged');
    },
  );

  testWidgets('tagged render preserves settled select-all / copy text', (
    tester,
  ) async {
    String? copiedDefault;
    String? copiedTagged;
    String? sink;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            sink = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    Future<String?> selectAllCopy(List<Widget> blocks) async {
      sink = null;
      // Tear down any prior SelectionArea cleanly before mounting the next, or
      // an active selection crashes the container delegate during re-pump.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.pumpWidget(_frame(blocks, selectable: true));
      await tester.pumpAndSettle();
      // Focus the selectable region, then select-all and copy.
      await tester.tapAt(tester.getCenter(find.byType(SelectionArea)));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      return sink;
    }

    copiedDefault = await selectAllCopy(_build(fidelityFixture, tagged: false));
    copiedTagged = await selectAllCopy(_build(fidelityFixture, tagged: true));

    expect(
      copiedDefault,
      isNotNull,
      reason: 'select-all/copy produced nothing in the default render',
    );
    expect(copiedDefault, isNotEmpty);
    // The occurrence tag must not change what selection copies — including the
    // ordered-marker SelectionContainer.disabled exclusion and the checkbox.
    expect(
      copiedTagged,
      copiedDefault,
      reason: 'select-all/copy text changed under occurrence tagging',
    );
  });
}
