import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/blocks.dart';
import 'package:markdown_viewer/markdown_theme.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_widget/markdown_widget.dart';

/// A document containing every element V1 promises to render.
const String sampleMarkdown = '''
# Investigation

Intro paragraph with `inline code`, a [link](https://example.test/page) and
some **bold** text.

## Findings

1. First finding
2. Second finding
   - nested bullet
     - deeper bullet

### Tasks

- [x] Completed task
- [ ] Outstanding task

> A blockquote that matters.

| Option | Cost | Notes |
| --- | --- | --- |
| A | Low | Fine |
| B | High | Slow |

```dart
void main() {
  print('hello');
}
```

A fenced block with no language at all, which is how AI-generated documents
usually present directory trees and call graphs:

```
ServiceA.DoWork(id)
  -> RepositoryB.Fetch(id)      EXISTING
  -> CalculatorC.Resolve(data)  NEW
```

A fenced block whose language the highlighter does not know:

```csharp
var result = service.DoWork(id);
```

![A diagram](https://example.test/diagram.png)

## Conclusion

Final paragraph.
''';

/// Builds the block list for arbitrary Markdown, exactly as the reader does.
({List<Widget> blocks, List<TocEntry> toc}) renderDocument(
  String markdown, {
  bool wrapCode = false,
  ReaderPalette? palette,
}) {
  final entries = <TocEntry>[];
  final blocks =
      MarkdownGenerator(
        linesMargin: const EdgeInsets.symmetric(vertical: 5),
      ).buildWidgets(
        markdown,
        config: buildMarkdownConfig(
          palette: palette ?? ReaderPalette.light,
          wrapCode: wrapCode,
          onLinkTap: (_) {},
        ),
        onTocList: (tocList) {
          entries.addAll(
            tocList.map(
              (toc) => TocEntry(
                level: headingTag2Level[toc.node.headingConfig.tag] ?? 1,
                text: toc.node.childrenSpan.toPlainText().trim(),
                blockIndex: toc.widgetIndex,
              ),
            ),
          );
        },
      );
  return (blocks: blocks, toc: entries);
}

/// The standard sample corpus.
({List<Widget> blocks, List<TocEntry> toc}) renderSample({
  bool wrapCode = false,
  ReaderPalette? palette,
}) => renderDocument(sampleMarkdown, wrapCode: wrapCode, palette: palette);

List<Widget> renderMarkdown(String markdown) => renderDocument(markdown).blocks;

/// Uses a Column inside a scroll view rather than a ListView so that every
/// block is built. A lazy list would leave blocks below the test viewport
/// unbuilt and the finders would silently pass on nothing.
Widget wrapForTest(List<Widget> blocks) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: blocks,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders the sample document without throwing', (tester) async {
    final result = renderSample();
    expect(result.blocks, isNotEmpty);

    await tester.pumpWidget(wrapForTest(result.blocks));
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders a table and code blocks as their own widgets', (
    tester,
  ) async {
    await tester.pumpWidget(wrapForTest(renderSample().blocks));

    expect(find.byType(TableBlock), findsOneWidget);
    // dart, untagged, csharp
    expect(find.byType(CodeBlock), findsNWidgets(3));
  });

  group('code block language handling', () {
    // Regression group for the defect reported on 2026-08-16: a fenced block
    // with no language threw ArgumentError.notNull('language') from the
    // highlighter, which broke the rest of the document.

    Future<void> expectRenders(WidgetTester tester, String markdown) async {
      await tester.pumpWidget(wrapForTest(renderMarkdown(markdown)));
      expect(tester.takeException(), isNull);
    }

    testWidgets('a fence with no language renders', (tester) async {
      await expectRenders(tester, 'Intro.\n\n```\nplain text block\n```\n');
      expect(find.byType(CodeBlock), findsOneWidget);
    });

    testWidgets('a fence with a recognised language renders', (tester) async {
      await expectRenders(tester, 'Intro.\n\n```dart\nvoid main() {}\n```\n');
    });

    testWidgets('a fence with an unknown language renders', (tester) async {
      await expectRenders(
        tester,
        'Intro.\n\n```csharp\nvar x = 1;\n```\n\n```razor\n@page\n```\n',
      );
      expect(find.byType(CodeBlock), findsNWidgets(2));
    });

    testWidgets('malformed language tokens render', (tester) async {
      await expectRenders(
        tester,
        '```C#\nx\n```\n\n```not-a-language\ny\n```\n\n```   \nz\n```\n',
      );
    });

    testWidgets('content after a problematic fence still renders', (
      tester,
    ) async {
      const markdown = '''
# Heading before

```
untagged block that used to throw
```

## Heading after

The paragraph after the problematic block must still be here.
''';
      await expectRenders(tester, markdown);
      expect(find.textContaining('Heading after'), findsOneWidget);
      expect(find.textContaining('must still be here'), findsOneWidget);
    });

    testWidgets('a recognised language is still actually highlighted', (
      tester,
    ) async {
      // Guards against "fixing" the defect by never highlighting anything.
      final blocks = renderMarkdown(
        '```dart\nvoid main() { print(1); }\n```\n',
      );
      await tester.pumpWidget(wrapForTest(blocks));

      final richText = tester.widget<Text>(
        find
            .descendant(of: find.byType(CodeBlock), matching: find.byType(Text))
            .last,
      );
      final span = richText.textSpan as TextSpan?;
      expect(
        span,
        isNotNull,
        reason: 'highlighted code should render as a rich TextSpan',
      );
      expect(span!.children, isNotNull);
      expect(
        span.children!.length,
        greaterThan(1),
        reason: 'highlighting should produce multiple styled spans',
      );
    });

    testWidgets('an untagged fence renders as plain text, not spans', (
      tester,
    ) async {
      final blocks = renderMarkdown('```\njust plain content\n```\n');
      await tester.pumpWidget(wrapForTest(blocks));

      final text = tester.widget<Text>(
        find
            .descendant(of: find.byType(CodeBlock), matching: find.byType(Text))
            .last,
      );
      expect(text.data, contains('just plain content'));
      expect(text.textSpan, isNull);
    });
  });

  testWidgets('never builds a network image for a remote image', (
    tester,
  ) async {
    await tester.pumpWidget(wrapForTest(renderSample().blocks));

    // The privacy guarantee: a remote image in a pasted document must become a
    // local placeholder, never an Image that would issue a request.
    expect(find.byType(Image), findsNothing);
    expect(find.byType(RemoteImagePlaceholder), findsOneWidget);
  });

  test('extracts a table of contents with levels and block indices', () {
    final toc = renderSample().toc;

    expect(toc.map((e) => e.text).toList(), [
      'Investigation',
      'Findings',
      'Tasks',
      'Conclusion',
    ]);
    expect(toc.map((e) => e.level).toList(), [1, 2, 3, 2]);

    // Indices must be strictly increasing and addressable in the block list.
    final blocks = renderSample().blocks;
    for (var i = 1; i < toc.length; i++) {
      expect(toc[i].blockIndex, greaterThan(toc[i - 1].blockIndex));
    }
    for (final entry in toc) {
      expect(entry.blockIndex, inInclusiveRange(0, blocks.length - 1));
    }
  });

  test('the code-highlight guard has a sane threshold', () {
    expect(kMaxHighlightChars, greaterThan(1000));
  });

  testWidgets('renders in dark mode without throwing', (tester) async {
    final result = renderSample(palette: ReaderPalette.dark);
    await tester.pumpWidget(wrapForTest(result.blocks));
    expect(tester.takeException(), isNull);
  });

  testWidgets('code wrapping preference changes every code block', (
    tester,
  ) async {
    await tester.pumpWidget(wrapForTest(renderSample(wrapCode: true).blocks));

    final codeBlocks = tester.widgetList<CodeBlock>(find.byType(CodeBlock));
    expect(codeBlocks, isNotEmpty);
    expect(codeBlocks.every((block) => block.wrap), isTrue);
  });
}
