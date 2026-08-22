import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
