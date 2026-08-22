import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/models.dart';

void main() {
  group('deriveTitle', () {
    test('uses the first ATX heading', () {
      expect(
        MarkdownDocument.deriveTitle('# Investigation Report\n\nBody text.'),
        'Investigation Report',
      );
    });

    test('uses a deeper heading when there is no h1', () {
      expect(MarkdownDocument.deriveTitle('### Findings\n\nBody.'), 'Findings');
    });

    test('ignores headings inside fenced code blocks', () {
      const source = '```sh\n# not a heading\n```\n\n# Real Heading\n';
      expect(MarkdownDocument.deriveTitle(source), 'Real Heading');
    });

    test('falls back to the first non-empty line', () {
      expect(
        MarkdownDocument.deriveTitle('\n\nJust a paragraph.\nMore.'),
        'Just a paragraph.',
      );
    });

    test('strips inline markers and link syntax', () {
      expect(
        MarkdownDocument.deriveTitle('# **Bold** and [a link](http://x.test)'),
        'Bold and a link',
      );
    });

    test('truncates very long titles', () {
      final title = MarkdownDocument.deriveTitle('# ${'x' * 200}');
      expect(title.length, lessThanOrEqualTo(60));
      expect(title, endsWith('…'));
    });

    test('returns Untitled for empty input', () {
      expect(MarkdownDocument.deriveTitle('   \n\n  '), 'Untitled');
    });
  });

  group('serialisation', () {
    test('document survives a JSON round trip', () {
      final original = MarkdownDocument.fromSource('# Title\n\nBody');
      final restored = MarkdownDocument.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.title, original.title);
      expect(restored.source, original.source);
      expect(
        restored.createdAt.toIso8601String(),
        original.createdAt.toIso8601String(),
      );
    });

    test('reading position survives a JSON round trip', () {
      final original = ReadingPosition(
        documentId: 'doc-1',
        blockIndex: 42,
        fraction: 0.375,
        headingText: 'Section 3',
        savedAt: DateTime.utc(2026, 8, 9, 12, 30),
      );
      final restored = ReadingPosition.fromJson(original.toJson());

      expect(restored.documentId, 'doc-1');
      expect(restored.blockIndex, 42);
      expect(restored.fraction, 0.375);
      expect(restored.headingText, 'Section 3');
      expect(restored.savedAt, original.savedAt);
    });

    test('settings survive a JSON round trip', () {
      const original = Settings(
        appearance: AppearanceMode.dark,
        fontScale: 1.25,
        wrapCode: true,
      );
      final restored = Settings.fromJson(original.toJson());

      expect(restored.appearance, AppearanceMode.dark);
      expect(restored.fontScale, 1.25);
      expect(restored.wrapCode, isTrue);
    });

    test('settings clamp an out-of-range font scale', () {
      final restored = Settings.fromJson({'fontScale': 9.0});
      expect(restored.fontScale, Settings.maxFontScale);
    });

    test('settings fall back to defaults on unknown values', () {
      final restored = Settings.fromJson({'appearance': 'nonsense'});
      expect(restored.appearance, AppearanceMode.system);
      expect(restored.fontScale, 1.0);
      expect(restored.wrapCode, isFalse);
    });
  });

  group('document identity', () {
    test('a pasted document identifies itself as pasted', () {
      final document = MarkdownDocument.fromSource('# Notes\n\ntext');
      expect(document.origin, DocumentOrigin.pasted);
      expect(document.sourceName, isNull);
      expect(document.identityLabel, 'Pasted document');
    });

    test('a file-loaded document keeps its filename', () {
      final document = MarkdownDocument.fromSource(
        '# Notes\n\ntext',
        sourceName: 'sample_large_document.md',
      );
      expect(document.origin, DocumentOrigin.file);
      expect(document.sourceName, 'sample_large_document.md');
      expect(document.identityLabel, 'sample_large_document.md');
      // The filename is metadata; the title still comes from the heading.
      expect(document.title, 'Notes');
    });

    test('identity survives a JSON round trip', () {
      final original = MarkdownDocument.fromSource(
        '# Doc',
        sourceName: 'plan.md',
      );
      final restored = MarkdownDocument.fromJson(original.toJson());

      expect(restored.sourceName, 'plan.md');
      expect(restored.origin, DocumentOrigin.file);
      expect(restored.identityLabel, 'plan.md');
    });

    test('editing preserves the origin and filename', () {
      final loaded = MarkdownDocument.fromSource(
        '# Original',
        sourceName: 'notes.md',
      );
      final edited = loaded.copyWith(
        source: '# Edited',
        title: MarkdownDocument.deriveTitle('# Edited'),
        updatedAt: DateTime.now(),
      );

      expect(edited.sourceName, 'notes.md');
      expect(edited.origin, DocumentOrigin.file);
      expect(edited.title, 'Edited');
    });

    test('a document persisted before this change still loads', () {
      // Exactly the shape written by the original V1 build: no sourceName,
      // no origin. It must read back as a pasted document, not crash.
      final legacyJson = <String, dynamic>{
        'id': '12345',
        'title': 'Legacy Document',
        'source': '# Legacy Document\n\nStored by an earlier build.',
        'createdAt': DateTime.utc(2026, 8, 1).toIso8601String(),
        'updatedAt': DateTime.utc(2026, 8, 2).toIso8601String(),
      };

      final restored = MarkdownDocument.fromJson(legacyJson);

      expect(restored.id, '12345');
      expect(restored.title, 'Legacy Document');
      expect(restored.source, contains('earlier build'));
      expect(restored.sourceName, isNull);
      expect(restored.origin, DocumentOrigin.pasted);
      expect(restored.identityLabel, 'Pasted document');
    });

    test('an unrecognised origin falls back to pasted', () {
      final restored = MarkdownDocument.fromJson({
        'id': '1',
        'title': 'T',
        'source': 's',
        'createdAt': DateTime.utc(2026).toIso8601String(),
        'updatedAt': DateTime.utc(2026).toIso8601String(),
        'origin': 'from-the-future',
      });
      expect(restored.origin, DocumentOrigin.pasted);
    });
  });
}
