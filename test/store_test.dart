import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/han_script.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/retention.dart';
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

  setUp(() async {
    // DF-039 gates every durable content write on effective retention policy,
    // which defaults to OFF. These tests are about the durable round trip, so
    // they run under ON; the gate itself is asserted separately below and in
    // retention_test.dart.
    store.applyResolvedPolicy(RetentionPolicy.on);
    await store.removeRetainedContent();
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

    expect(await store.removeRetainedContent(), CleanupOutcome.confirmedAbsent);

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

      // The _openDocument path: remove, then store a fromSource document.
      await store.removeRetainedContent();
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

  // --- DF-039 ---------------------------------------------------------------

  test(
    'content writes are suppressed against real storage while OFF',
    () async {
      store.applyResolvedPolicy(RetentionPolicy.off);

      final document = MarkdownDocument.fromSource('# Not for next time');
      expect(
        await store.saveDocument(document),
        WriteOutcome.suppressedByPolicy,
      );
      expect(
        await store.savePosition(
          ReadingPosition(
            documentId: document.id,
            blockIndex: 2,
            fraction: 0,
            savedAt: DateTime.now(),
          ),
        ),
        WriteOutcome.suppressedByPolicy,
      );

      // The proof that matters is at the raw-key level, not the decoded one.
      expect(store.rawKeyPresence(Store.documentKey), RawKeyPresence.absent);
      expect(store.rawKeyPresence(Store.positionKey), RawKeyPresence.absent);
      expect(store.rawContentPresence(), RawKeyPresence.absent);
    },
  );

  test('settings still persist against real storage while OFF', () async {
    store.applyResolvedPolicy(RetentionPolicy.off);

    expect(
      await store.saveSettings(
        const Settings(appearance: AppearanceMode.dark, keepForNextTime: false),
      ),
      WriteOutcome.saved,
    );
    expect(store.loadSettings().appearance, AppearanceMode.dark);
  });

  test('the retention preference round trips against real storage', () async {
    expect(
      await store.saveSettings(const Settings(keepForNextTime: true)),
      WriteOutcome.saved,
    );

    final result = store.loadSettingsResult();
    expect(result.outcome, SettingsReadOutcome.loaded);
    expect(result.retentionFieldPresent, isTrue);
    expect(result.settings.keepForNextTime, isTrue);
    expect(result.storedKeepForNextTime, isTrue);

    expect(
      await store.saveSettings(const Settings(keepForNextTime: false)),
      WriteOutcome.saved,
    );
    expect(store.loadSettingsResult().settings.keepForNextTime, isFalse);
  });

  test('removal against real storage verifies absence', () async {
    final document = MarkdownDocument.fromSource('# Doc');
    expect(await store.saveDocument(document), WriteOutcome.saved);
    expect(
      await store.savePosition(
        ReadingPosition(
          documentId: document.id,
          blockIndex: 1,
          fraction: 0,
          savedAt: DateTime.now(),
        ),
      ),
      WriteOutcome.saved,
    );
    expect(store.rawContentPresence(), RawKeyPresence.present);

    expect(await store.removeRetainedContent(), CleanupOutcome.confirmedAbsent);
    expect(store.rawKeyPresence(Store.documentKey), RawKeyPresence.absent);
    expect(store.rawKeyPresence(Store.positionKey), RawKeyPresence.absent);
  });

  test('an undecodable record is still present, and still removable', () async {
    // Written through the backend directly: this is the corrupt-data case, and
    // the point is that `loadDocument` returning null must not be read as
    // "nothing stored", or the data would be unreachable and unremovable.
    await store.saveDocument(MarkdownDocument.fromSource('# Doc'));
    final backend = HiveStorageBackend(Hive.box<String>(Store.boxName));
    await backend.write(Store.documentKey, 'not json at all');

    expect(store.loadDocument(), isNull);
    expect(store.rawKeyPresence(Store.documentKey), RawKeyPresence.present);

    expect(await store.removeRetainedContent(), CleanupOutcome.confirmedAbsent);
    expect(store.rawKeyPresence(Store.documentKey), RawKeyPresence.absent);
  });
}
