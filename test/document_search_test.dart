import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:markdown_viewer/document_search.dart';

void main() {
  group('renderer-aligned projection', () {
    test('preserves inline adjacency and blocks structural crossings', () {
      final index = DocumentSearchIndex.build('''
# Heading *with* `code`

Alpha *bold* [link](https://hidden.example) `inline` omega.

- first item
- second item

| left | right |
| --- | --- |
| cell one | cell two |
''');

      expect(index.searchMapped('Heading with code').total, 1);
      expect(index.searchMapped('Alpha bold link inline omega').total, 1);
      expect(index.searchMapped('hidden.example').total, 0);
      expect(index.searchMapped('first item second item').total, 0);
      expect(index.searchMapped('cell one cell two').total, 0);
      expect(
        index.searchMapped('cell one').matches.single.heading,
        'Heading with code',
      );
    });

    test('retains code but excludes generated list and task chrome', () {
      final index = DocumentSearchIndex.build('''
1. numbered
- [x] checked

```dart
final value = 42;
```
''');

      expect(index.searchMapped('numbered').total, 1);
      expect(index.searchMapped('checked').total, 1);
      expect(index.searchMapped('1. numbered').total, 0);
      expect(index.searchMapped('[x]').total, 0);
      expect(index.searchMapped('final value = 42;').total, 1);
      expect(index.searchMapped('dart').total, 0);
    });

    test('covers nested lists, blockquotes, and no-text horizontal rules', () {
      final index = DocumentSearchIndex.build('''
> Quoted needle

- parent item
  - nested needle

---
''');

      expect(index.searchMapped('Quoted needle').total, 1);
      expect(index.searchMapped('nested needle').total, 1);
      expect(index.searchMapped('parent item nested needle').total, 0);
      expect(index.searchMapped('---').total, 0);
      expect(index.blocks.any((block) => block.runs.isEmpty), isTrue);
    });

    test(
      'distinguishes soft newlines and hard breaks without crossing either',
      () {
        final index = DocumentSearchIndex.build(
          'soft first\n'
          'soft second\n'
          '\n'
          'hard first  \n'
          'hard second\n',
        );

        expect(index.searchMapped('soft first').total, 1);
        expect(index.searchMapped('soft first\nsoft second').total, 0);
        expect(index.searchMapped('firstsoft').total, 0);
        expect(index.searchMapped('hard firsthard second').total, 0);
        expect(index.logicalRunCount, greaterThanOrEqualTo(3));
      },
    );

    test('indexes visible HTML literals, entities, escapes, and emoji', () {
      final index = DocumentSearchIndex.build(
        r'Literal <kbd>key</kbd>, &amp;, \*star\*, literal :rocket:, and 🚀.',
      );

      expect(index.searchMapped('<kbd>').total, 1);
      expect(index.searchMapped('key').total, 1);
      expect(index.searchMapped('&').total, 1);
      expect(index.searchMapped('*star*').total, 1);
      expect(index.searchMapped(':rocket:').total, 1);
      expect(index.searchMapped('🚀').total, 1);
    });

    test('indexes image alt and only visibly exposed remote URL', () {
      final index = DocumentSearchIndex.build('''
![remote alt](https://example.test/private.png)

![local alt](asset.png)

![](https://example.test/no-alt.png)

![uppercase](HTTP://example.test/uppercase.png)

![mixed](Https://example.test/mixed.png)
''');

      expect(index.searchMapped('remote alt').total, 1);
      expect(index.searchMapped('local alt').total, 1);
      expect(index.searchMapped('uppercase').total, 1);
      expect(index.searchMapped('mixed').total, 1);
      expect(index.searchMapped('https://example.test/private.png').total, 1);
      expect(index.searchMapped('asset.png').total, 0);
      expect(index.searchMapped('https://example.test/no-alt.png').total, 1);
      expect(index.searchMapped('HTTP://example.test/uppercase.png').total, 0);
      expect(index.searchMapped('Https://example.test/mixed.png').total, 0);
      expect(index.searchMapped('Image not available offline').total, 0);
    });

    test('mirrors generated footnote order and opaque fallback content', () {
      final index = DocumentSearchIndex.build('''
Second first[^b], then first[^a], then second again[^b].

[^a]: Alpha body.
[^b]: Beta body.
[^unused]: Hidden body.
''');

      final beta = index.searchMapped('Beta body').matches.single;
      final alpha = index.searchMapped('Alpha body').matches.single;
      expect(beta.blockIndex, alpha.blockIndex);
      expect(beta.runIndex, alpha.runIndex);
      expect(beta.start, lessThan(alpha.start));
      expect(index.searchMapped('Hidden body').total, 0);
      expect(index.searchMapped('↩').total, greaterThanOrEqualTo(2));
      expect(index.searchMapped('1').total, greaterThanOrEqualTo(1));
    });
  });

  group('literal matching and identity', () {
    test('is case-insensitive, literal, non-overlapping, and UTF-16 based', () {
      final index = DocumentSearchIndex.build(
        '## Unicode\n\nA.a A.A a.a aaaa 😀 cafe\u0301 café',
      );

      final literal = index.searchMapped('a.a');
      expect(literal.total, 3);
      expect(literal.matches.map((match) => match.ordinal), [1, 2, 3]);
      expect(index.searchMapped('aa').total, 2);

      final emoji = index.searchMapped('😀').matches.single;
      expect(emoji.end - emoji.start, 2);
      expect(index.searchMapped('café').total, 1);
      expect(index.searchMapped('cafe\u0301').total, 1);
    });

    test('trims only query edges and returns exact snippet text', () {
      final index = DocumentSearchIndex.build(
        'Heading\n=======\n\nBefore   Exact Match   after',
      );

      final result = index.searchMapped('  exact match  ');
      expect(result.query, 'exact match');
      expect(result.total, 1);
      expect(result.matches.single.snippet.match, 'Exact Match');
      expect(
        result.matches.single.snippet.plainText,
        contains('Before Exact Match after'),
      );
      expect(index.searchMapped('   ').isNeutral, isTrue);
    });

    test('orders by block, run, and offset with heading context', () {
      final index = DocumentSearchIndex.build('''
# First

needle then needle

## Second

needle
''');
      final result = index.searchMapped('needle');

      expect(result.total, 3);
      expect(result.matches.map((match) => match.ordinal), [1, 2, 3]);
      expect(result.matches[0].blockIndex, result.matches[1].blockIndex);
      expect(
        result.matches[2].blockIndex,
        greaterThan(result.matches[1].blockIndex),
      );
      expect(result.matches.map((match) => match.heading), [
        'First',
        'First',
        'Second',
      ]);
    });

    test('continues exact counting beyond the retained-anchor budget', () {
      final source = List.filled(maxRetainedSearchAnchors + 1, 'x').join(' ');
      final result = DocumentSearchIndex.build(source).searchMapped('x');

      expect(result.total, maxRetainedSearchAnchors + 1);
      expect(result.matches, hasLength(maxRetainedSearchAnchors));
      expect(result.isOverflow, isTrue);
    });
  });

  group('parser/widget mapping and safe failure', () {
    testWidgets('mixed surfaces have exact top-level ordinal parity', (
      tester,
    ) async {
      const source = '''
# Marker heading

Paragraph with *style*, `code`, [link](https://example.test), and ![alt](https://example.test/i.png).

> Quote paragraph

- one
- two

| a | b |
| - | - |
| c | d |

```dart
marker-code
```

Reference[^note].

[^note]: Footnote marker.
''';
      final index = DocumentSearchIndex.build(source);
      final widgets = MarkdownGenerator().buildWidgets(source);

      expect(index.blocks, hasLength(widgets.length));
      final available = index.search(
        'Marker heading',
        renderedBlockCount: widgets.length,
      );
      expect(available.isAvailable, isTrue);
      expect(available.message, isNull);
      expect(available.matches.single.blockIndex, 0);
      expect(index.searchMapped('marker-code').matches.single.blockIndex, 5);
      expect(
        index.searchMapped('Footnote marker').matches.single.blockIndex,
        widgets.length - 1,
      );
    });

    testWidgets(
      'retained DF-026 long fixture keeps parity and marker mapping',
      (tester) async {
        final source = File('test/fixtures/df026-long.md').readAsStringSync();
        final index = DocumentSearchIndex.build(source);
        final widgets = MarkdownGenerator().buildWidgets(source);

        expect(
          index
              .search('SECTION-01-START', renderedBlockCount: widgets.length)
              .isAvailable,
          isTrue,
        );
        final early = index.searchMapped('SECTION-01-START').matches.single;
        final late = index.searchMapped('SECTION-24-START').matches.single;
        expect(early.blockIndex, lessThan(late.blockIndex));
        expect(late.blockIndex, lessThan(widgets.length));
      },
    );

    test('mismatch fails closed without a guessed target', () {
      final index = DocumentSearchIndex.build('# Heading\n\nBody');
      final result = index.search(
        'Body',
        renderedBlockCount: index.blocks.length + 1,
      );

      expect(result.isAvailable, isFalse);
      expect(result.message, 'Search is unavailable for this document');
      expect(result.total, 0);
      expect(result.matches, isEmpty);
    });

    test('CRLF and LF produce the same semantic projection', () {
      const lf = '# Heading\n\nLine one\nline two\n';
      final crlf = lf.replaceAll('\n', '\r\n');
      final left = DocumentSearchIndex.build(lf);
      final right = DocumentSearchIndex.build(crlf);

      expect(left.blocks.length, right.blocks.length);
      expect(
        left.blocks.expand((block) => block.runs).map((run) => run.text),
        right.blocks.expand((block) => block.runs).map((run) => run.text),
      );
    });
  });
}

extension on DocumentSearchIndex {
  DocumentSearchResult searchMapped(String input) =>
      search(input, renderedBlockCount: blocks.length);
}
