import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/blocks.dart';
import 'package:markdown_viewer/document_search.dart';
import 'package:markdown_viewer/markdown_theme.dart';
import 'package:markdown_viewer/reader_text_unit.dart';
import 'package:markdown_widget/markdown_widget.dart';

/// DF-052 CP1 — shared render-sourced Reader/Search unit model, structural
/// occurrence identity, capture completeness/fail-closed, index feed, and
/// revision invalidation (plan.md §§3–8; decision.md D-001/D-002; Human CP1
/// additional verification).
///
/// Capture runs during `MarkdownGenerator.buildWidgets`, which produces the
/// spans without mounting; text is read from the same span objects the renderer
/// draws, so these assertions exercise the exact CP1 capture path.

ReaderTextUnitCaptureResult captureOf(String source) {
  final capture = ReaderTextUnitCapture();
  MarkdownGenerator(
    linesMargin: const EdgeInsets.symmetric(vertical: 5),
    generators: capture.generators,
    onNodeAccepted: capture.onNodeAccepted,
  ).buildWidgets(
    source,
    config: buildMarkdownConfig(
      palette: ReaderPalette.light,
      wrapCode: false,
      onLinkTap: (_) {},
    ),
  );
  return capture.finish();
}

DocumentRevision revisionOf(
  String source, {
  String id = 'doc',
  DateTime? updatedAt,
}) => DocumentRevision.fromDocument(
  id: id,
  updatedAt: updatedAt ?? DateTime.utc(2026, 1, 1),
  source: source,
);

DocumentSearchIndex indexOf(
  String source, {
  String id = 'doc',
  DateTime? updatedAt,
}) {
  final result = captureOf(source);
  return DocumentSearchIndex.fromUnits(
    result.units,
    revision: revisionOf(source, id: id, updatedAt: updatedAt),
    complete: result.isComplete,
  );
}

DocumentSearchResult searchOf(String source, String query) {
  return indexOf(source).searchRendered(
    query,
    currentRevision: revisionOf(source),
  );
}

List<ReaderTextUnit> unitsOf(String source) => captureOf(source).units;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('structural occurrence identity (§4)', () {
    test('duplicate table cells receive distinct owner ids', () {
      const source = '''
| Head |
| --- |
| dup |
| dup |
''';
      final result = searchOf(source, 'dup');
      expect(result.isAvailable, isTrue);
      expect(result.total, 2);
      final a = result.matches[0].ownerId!;
      final b = result.matches[1].ownerId!;
      expect(a, isNot(equals(b)), reason: 'equal cells must be distinct owners');
      expect(result.matches[0].blockIndex, result.matches[1].blockIndex,
          reason: 'both cells are in the same top-level table block');
    });

    test('sibling list items receive distinct owner ids', () {
      const source = '- item\n- item\n';
      final result = searchOf(source, 'item');
      expect(result.total, 2);
      expect(result.matches[0].ownerId, isNot(equals(result.matches[1].ownerId)));
    });

    test('identical paragraphs differ by block ordinal', () {
      const source = 'para\n\npara\n';
      final result = searchOf(source, 'para');
      expect(result.total, 2);
      expect(result.matches[0].blockIndex,
          isNot(equals(result.matches[1].blockIndex)));
    });

    test('repeated words in one owner differ by range', () {
      final result = searchOf('# H\n\nrepeat repeat repeat', 'repeat');
      expect(result.total, 3);
      final ranges = result.matches.map((m) => '${m.start}-${m.end}').toSet();
      expect(ranges.length, 3, reason: 'each occurrence keeps a distinct range');
      // Same owner for all three.
      expect(result.matches.map((m) => m.ownerId).toSet().length, 1);
    });

    test('owner ids are stable across a light/dark re-render', () {
      const source = '# Heading\n\nbody text\n\n- one\n- two\n';
      final light = captureOf(source).units.map((u) => u.id.toString()).toList();
      // Re-render with the dark palette; ids and text are layout-independent.
      final capture = ReaderTextUnitCapture();
      MarkdownGenerator(
        generators: capture.generators,
        onNodeAccepted: capture.onNodeAccepted,
      ).buildWidgets(
        source,
        config: buildMarkdownConfig(
          palette: ReaderPalette.dark,
          wrapCode: false,
          onLinkTap: (_) {},
        ),
      );
      final dark = capture.finish().units.map((u) => u.id.toString()).toList();
      expect(dark, light);
    });
  });

  group('rendered-text truth (§3, D-001)', () {
    test('the link-added visible space is part of Search truth (alph abet)', () {
      // Pinned LinkNode.build appends a TextSpan(" ") after the link children,
      // so the rendered text is "alph abet", not "alphabet".
      const source = '[alph](https://example.test)abet\n';
      final units = unitsOf(source);
      final prose = units.firstWhere((u) => u.kind == UnitKind.prose);
      expect(prose.text, 'alph abet');
      expect(searchOf(source, 'alph abet').total, 1,
          reason: 'rendered text is truth');
      expect(searchOf(source, 'alphabet').total, 0,
          reason: 'a literal absent from Reader text must not match');
    });

    test('inline code and emphasis do not break a visible occurrence', () {
      const source = 'the `quick` brown **fox** jumps\n';
      expect(searchOf(source, 'quick brown fox').total, 1);
    });

    test('code owner text is the displayed code.trimRight()', () {
      const source = '```dart\nvoid main() {}\n\n\n```\n';
      final units = unitsOf(source);
      final code = units.firstWhere((u) => u.kind == UnitKind.code);
      expect(code.text, 'void main() {}');
      expect(searchOf(source, 'void main').total, 1);
    });

    test('generated list markers and task checkboxes are excluded', () {
      const source = '1. First entry\n2. Second entry\n';
      final items = unitsOf(source)
          .where((u) => u.kind == UnitKind.listItem)
          .toList();
      expect(items.length, 2);
      expect(items[0].text, 'First entry');
      expect(items[1].text, 'Second entry');
      // The generated ordinal marker "1." / "2." is not searchable text.
      expect(searchOf(source, '1.').total, 0);
      expect(searchOf(source, '2.').total, 0);

      const tasks = '- [x] done alpha\n- [ ] todo beta\n';
      final taskItems = unitsOf(tasks)
          .where((u) => u.kind == UnitKind.listItem)
          .toList();
      expect(taskItems.length, 2);
      for (final item in taskItems) {
        expect(item.text, isNot(contains('[')));
        expect(item.text, isNot(contains(']')));
      }
      expect(searchOf(tasks, 'done alpha').total, 1);
      expect(searchOf(tasks, 'todo beta').total, 1);
    });

    test('a nested paragraph does not create a second overlapping owner', () {
      // A loose list item wraps its content in <p>; only the list-item owner
      // registers, so "loose" matches exactly once, not twice.
      const source = '- loose item\n\n- second\n';
      final result = searchOf(source, 'loose');
      expect(result.total, 1);
      expect(result.matches.single.ownerId!.path.length, greaterThan(1),
          reason: 'the owner is the list item, not a container');
    });

    test('a blockquote is one owner covering its inlined text', () {
      const source = '> quoted **words** here\n';
      final result = searchOf(source, 'quoted words here');
      expect(result.total, 1);
      final bq = unitsOf(source).firstWhere((u) => u.kind == UnitKind.blockquote);
      expect(bq.text, 'quoted words here');
    });
  });

  group('newline and hard-break boundaries (§7)', () {
    test('a match never crosses a source newline within an owner', () {
      const source = '> alpha\n> beta\n';
      // Rendered blockquote text contains a newline between the two lines.
      expect(searchOf(source, 'alpha').total, 1);
      expect(searchOf(source, 'beta').total, 1);
      expect(searchOf(source, 'alpha\nbeta').total, 0);
      expect(searchOf(source, 'alphabeta').total, 0);
    });
  });

  group('Unicode: Chinese and emoji (D-002)', () {
    test('Chinese search including a substring of a phrase', () {
      const source = '# 中文搜尋測試\n\n這是 中文搜尋測試 的內容\n';
      expect(searchOf(source, '搜尋').total, greaterThanOrEqualTo(2),
          reason: 'heading and body both contain 搜尋');
      expect(searchOf(source, '中文搜尋測試').total, greaterThanOrEqualTo(2));
    });

    test('mixed Latin/Chinese and Chinese across a formatting span', () {
      const source = 'Section 中**文搜**尋 done\n';
      // Rendered contiguous text is "Section 中文搜尋 done".
      expect(searchOf(source, 'Section 中文搜尋 done').total, 1);
      expect(searchOf(source, '文搜尋').total, 1,
          reason: 'match crosses the bold→text boundary');
    });

    test('exact displayed emoji sequences are searchable with intact ranges', () {
      const emojis = ['😀', '❤️', '👍🏽', '👨‍👩‍👧‍👦'];
      for (final emoji in emojis) {
        final source = 'lead $emoji tail\n';
        final result = searchOf(source, emoji);
        expect(result.total, 1, reason: 'emoji $emoji must be searchable');
        final match = result.matches.single;
        final unit = unitsOf(source).firstWhere((u) => u.kind == UnitKind.prose);
        // The indicated range must reproduce the exact original UTF-16 units.
        expect(unit.text.substring(match.start, match.end), emoji,
            reason: 'range must preserve the exact Unicode sequence');
      }
    });
  });

  group('fail-closed capture and revision invalidation (§5.2, §7)', () {
    test('incomplete capture fails closed to unavailable', () {
      final units = unitsOf('alpha beta');
      final rev = revisionOf('alpha beta');
      final index = DocumentSearchIndex.fromUnits(
        units,
        revision: rev,
        complete: false,
      );
      final result = index.searchRendered('alpha', currentRevision: rev);
      expect(result.isAvailable, isFalse);
      expect(result.matches, isEmpty);
    });

    test('a revision mismatch fails closed to unavailable', () {
      const source = 'alpha beta';
      final index = indexOf(source);
      final result = index.searchRendered(
        'alpha',
        currentRevision: revisionOf(source, updatedAt: DateTime.utc(2027)),
      );
      expect(result.isAvailable, isFalse);
      expect(result.matches, isEmpty);
    });

    test('overflow preserves the complete-or-refine contract', () {
      final source = 'x' * (maxRetainedSearchAnchors + 1);
      final result = searchOf(source, 'x');
      expect(result.total, maxRetainedSearchAnchors + 1);
      expect(result.isOverflow, isTrue);
      expect(result.matches.length, maxRetainedSearchAnchors,
          reason: 'anchors are capped but the exact count keeps counting');
    });
  });

  group('current-document / paste / edit revision lifecycle (D-002)', () {
    const opened = '# Doc\n\nkeepone and dropme here\n';
    const pasted = '# Pasted\n\nfreshone content only\n';
    const edited = '# Doc\n\nkeepone and addedthree here\n';

    test('normal open indexes the current rendered document', () {
      final result = searchOf(opened, 'dropme');
      expect(result.total, 1);
    });

    test('paste markdown becomes the new searchable rendered document', () {
      expect(searchOf(pasted, 'freshone').total, 1);
      expect(searchOf(pasted, 'dropme').total, 0);
    });

    test('editing the local copy adds new text and removes old text', () {
      expect(searchOf(edited, 'addedthree').total, 1,
          reason: 'newly visible text is searchable');
      expect(searchOf(edited, 'dropme').total, 0,
          reason: 'removed text ceases to be searchable');
    });

    test('a stale index (old revision) fails closed against the new one', () {
      final staleIndex = indexOf(opened, updatedAt: DateTime.utc(2026, 1, 1));
      final newRevision = revisionOf(edited, updatedAt: DateTime.utc(2026, 6, 1));
      final result = staleIndex.searchRendered(
        'keepone',
        currentRevision: newRevision,
      );
      expect(result.isAvailable, isFalse,
          reason: 'stale units/results are invalidated by revision change');
    });
  });

  group('remote-image placeholder text (D-004)', () {
    const remoteUrl = 'https://example.test/pics/architecture-v2.png';
    const remoteImage = '![diagram alt]($remoteUrl)\n';

    List<ReaderTextUnit> imageUnits(String source) =>
        unitsOf(source).where((u) => u.kind == UnitKind.image).toList();

    test('each displayed run is its own owner with faithful text', () {
      // Round 1 finding 1: label, status and URL are three distinct drawing
      // RenderParagraphs, so each is a separate unit — not one joined owner.
      final images = imageUnits(remoteImage);
      expect(images.map((u) => u.text).toList(), [
        'diagram alt',
        RemoteImagePlaceholder.remoteStatus,
        remoteUrl,
      ]);
      // Distinct, document-ordered structural owner ids under the image node.
      final ids = images.map((u) => u.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'ids must be distinct');
      for (var i = 1; i < ids.length; i++) {
        expect(ids[i - 1].compareTo(ids[i]) < 0, isTrue);
      }
    });

    test('DF-041 alt and remote URL coverage is preserved', () {
      // Each lands in its own owner with the whole run as its range.
      final alt = searchOf(remoteImage, 'diagram alt');
      expect(alt.total, 1);
      final altUnit = imageUnits(remoteImage).firstWhere((u) => u.text == 'diagram alt');
      expect(alt.matches.single.ownerId, altUnit.id);

      final url = searchOf(remoteImage, remoteUrl);
      expect(url.total, 1);
      final urlUnit = imageUnits(remoteImage).firstWhere((u) => u.text == remoteUrl);
      expect(url.matches.single.ownerId, urlUnit.id);
      expect(
        urlUnit.text.substring(url.matches.single.start, url.matches.single.end),
        remoteUrl,
      );
    });

    test('the generated status sentence is searchable in its own owner', () {
      final result = searchOf(remoteImage, 'Remote image not loaded');
      expect(result.total, 1);
      final statusUnit = imageUnits(remoteImage)
          .firstWhere((u) => u.text == RemoteImagePlaceholder.remoteStatus);
      expect(result.matches.single.ownerId, statusUnit.id);
    });

    test('a match never crosses between the separate run owners', () {
      // Distinct owners cannot be spanned by one literal match.
      expect(searchOf(remoteImage, 'diagram alt Remote').total, 0);
    });

    test('the fallback label owner is captured when alt is empty', () {
      const noAlt = '![](https://example.test/x.png)\n';
      final images = imageUnits(noAlt);
      expect(images.first.text, 'Image');
      expect(images.length, 3, reason: 'label, status, URL');
    });

    test('a non-remote image has label + status owners and no URL owner', () {
      const local = '![local alt](assets/pic.png)\n';
      final images = imageUnits(local);
      expect(images.map((u) => u.text).toList(), [
        'local alt',
        RemoteImagePlaceholder.localStatus,
      ]);
      expect(images.every((u) => !u.text.contains('http')), isTrue);
    });

    test('image placeholder capture is complete', () {
      expect(captureOf(remoteImage).isComplete, isTrue);
    });
  });

  group('heading context and completeness', () {
    test('units carry nearest heading context', () {
      const source = '# Title\n\nbody paragraph\n';
      final prose = unitsOf(source).firstWhere((u) => u.kind == UnitKind.prose);
      expect(prose.heading, 'Title');
    });

    test('a representative document captures completely', () {
      const source = '''
# Heading

Prose with a [link](https://example.test).

> Quote

| A | B |
| - | - |
| c | d |

1. one
2. two
   - nested

```dart
void main() {}
```
''';
      final result = captureOf(source);
      expect(result.isComplete, isTrue);
      expect(result.units, isNotEmpty);
    });
  });
}
