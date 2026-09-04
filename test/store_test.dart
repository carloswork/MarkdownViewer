import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/han_script.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/store.dart';

/// Exercises the real Store against a real Hive box on disk.
///
/// On the VM that box is a file; in the browser the same code lands in
/// IndexedDB. This proves the round trip and the size headroom the plan calls
/// for; that the web backend really is IndexedDB is checked in the browser
/// during validation, not here.
void main() {
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('markdown_viewer_test');

    // hive_ce_flutter's initFlutter asks path_provider where to write.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => tempDir.path,
        );

    await store.init();
  });

  tearDownAll(() async {
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // Windows keeps the open box file locked. Leaving a temp directory behind
      // is not worth failing a run over.
    }
  });

  test('store opens successfully', () {
    expect(store.isAvailable, isTrue);
  });

  test('a large document survives a save and reload', () async {
    // Comfortably larger than a long AI-generated technical document, and well
    // past the ~5 MB localStorage cap that motivated using IndexedDB.
    final source = '# Big document\n\n${'lorem ipsum dolor sit amet ' * 8000}';
    expect(source.length, greaterThan(200000));

    final document = MarkdownDocument.fromSource(source);
    await store.saveDocument(document);

    final loaded = store.loadDocument();
    expect(loaded, isNotNull);
    expect(loaded!.source, source);
    expect(loaded.title, 'Big document');
    expect(loaded.id, document.id);
  });

  test('reading position round trips for the matching document', () async {
    final document = MarkdownDocument.fromSource('# Doc\n\ntext');
    await store.saveDocument(document);

    await store.savePosition(
      ReadingPosition(
        documentId: document.id,
        blockIndex: 17,
        fraction: 0.4,
        headingText: 'Somewhere',
        savedAt: DateTime.now(),
      ),
    );

    final loaded = store.loadPosition(document.id);
    expect(loaded, isNotNull);
    expect(loaded!.blockIndex, 17);
    expect(loaded.fraction, closeTo(0.4, 1e-9));
  });

  test('a position from a different document is not reused', () async {
    final document = MarkdownDocument.fromSource('# Doc\n\ntext');
    await store.saveDocument(document);
    await store.savePosition(
      ReadingPosition(
        documentId: document.id,
        blockIndex: 17,
        fraction: 0.4,
        savedAt: DateTime.now(),
      ),
    );

    expect(store.loadPosition('some-other-document'), isNull);
  });

  test('clearing the document also clears its position', () async {
    final document = MarkdownDocument.fromSource('# Doc\n\ntext');
    await store.saveDocument(document);
    await store.savePosition(
      ReadingPosition(
        documentId: document.id,
        blockIndex: 3,
        fraction: 0,
        savedAt: DateTime.now(),
      ),
    );

    await store.clearDocument();

    expect(store.loadDocument(), isNull);
    expect(store.loadPosition(document.id), isNull);
  });

  // DF-031 case 13: save, reload through Store, reopen. The preference lives
  // inside the document, so `Store` itself is unchanged - `saveDocument`
  // already serialises the whole document (plan.md §5.7.1).
  test('an explicit script preference survives a save and reload', () async {
    final document = MarkdownDocument.fromSource(
      '# 報告\n\n說編輯設與錯誤處請閱讀單',
    ).copyWith(scriptPreference: DocumentScriptPreference.simplifiedChinese);

    await store.saveDocument(document);

    // Reopen: exactly what main() does at launch and _continueReading relies on.
    final reopened = store.loadDocument();
    expect(reopened, isNotNull);
    expect(
      reopened!.scriptPreference,
      DocumentScriptPreference.simplifiedChinese,
    );
    expect(reopened.id, document.id);
    expect(reopened.updatedAt, document.updatedAt);

    // Restored AND applied: the explicit preference still beats the source,
    // which unambiguously reads Traditional.
    expect(resolveHanScript(reopened.source), HanScript.hant);
    expect(resolveHanScriptForDocument(reopened), HanScript.hans);
  });

  test(
    'a persisted auto document is re-detected from its current source',
    () async {
      final document = MarkdownDocument.fromSource('# 報告\n\n說編輯設與錯誤處請閱讀單');
      await store.saveDocument(document);

      final reopened = store.loadDocument()!;
      expect(reopened.scriptPreference, DocumentScriptPreference.auto);
      expect(resolveHanScriptForDocument(reopened), HanScript.hant);
    },
  );

  test(
    'a replacement document does not inherit the cleared preference',
    () async {
      await store.saveDocument(
        MarkdownDocument.fromSource('# First').copyWith(
          scriptPreference: DocumentScriptPreference.traditionalChinese,
        ),
      );

      // The _openDocument path: clear, then store a fromSource document.
      await store.clearDocument();
      await store.saveDocument(MarkdownDocument.fromSource('# Second'));

      final loaded = store.loadDocument()!;
      expect(loaded.title, 'Second');
      expect(
        loaded.scriptPreference,
        DocumentScriptPreference.auto,
        reason:
            'the preference lived inside the document that was cleared, so it '
            'cannot be inherited by its replacement (plan.md §5.7.3)',
      );
    },
  );

  test('settings round trip and default when absent', () async {
    expect(store.loadSettings().appearance, AppearanceMode.system);

    await store.saveSettings(
      const Settings(
        appearance: AppearanceMode.dark,
        fontScale: 1.3,
        wrapCode: true,
      ),
    );

    final loaded = store.loadSettings();
    expect(loaded.appearance, AppearanceMode.dark);
    expect(loaded.fontScale, 1.3);
    expect(loaded.wrapCode, isTrue);
  });
}
