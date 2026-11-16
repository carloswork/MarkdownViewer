import 'dart:async';

import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/retained_format.dart';
import 'package:markdown_viewer/retention.dart';
import 'package:markdown_viewer/store.dart';

/// The startup resolution a fresh profile produces: no settings record, so the
/// retention preference is off, and nothing stored to clean up.
///
/// The default for tests that are about something other than retention. It is
/// the state a first-time visitor is in, so it is also the honest default.
const StartupResolution offStartup = StartupResolution(
  effectivePolicy: RetentionPolicy.off,
  settingsLoad: SettingsLoadResult(
    settings: Settings(),
    outcome: SettingsReadOutcome.missing,
    retentionFieldPresent: false,
  ),
  rawContentPresentAtStartup: RawKeyPresence.absent,
  legacyRecord: false,
);

/// The startup resolution for a profile whose saved choice is on, with a valid
/// retained document already on disk.
const StartupResolution onStartup = StartupResolution(
  effectivePolicy: RetentionPolicy.on,
  settingsLoad: SettingsLoadResult(
    settings: Settings(keepForNextTime: true),
    outcome: SettingsReadOutcome.loaded,
    retentionFieldPresent: true,
  ),
  rawContentPresentAtStartup: RawKeyPresence.present,
  legacyRecord: false,
);

/// An in-memory backend that behaves like a healthy browser.
///
/// It serves both storage seams from one map: the content contract
/// ([StorageBackend], C1-C8) for `document` and `position`, and the settings
/// seam ([SettingsBackend]) for `settings`. That keeps a test's view of
/// "storage" one map, as the browser's is one database.
///
/// Lets a widget test drive the real app against real storage semantics -
/// including the DF-039 retention gate - without a Hive box on disk. A real file
/// write started inside the widget-test fake-async zone never completes, which
/// is why these tests previously avoided opening the store at all; an in-memory
/// backend gives them the store's actual behaviour instead of a store that
/// silently does nothing.
class MemoryBackend implements StorageBackend, SettingsBackend {
  MemoryBackend([Map<String, String>? seed]) {
    if (seed != null) data.addAll(seed);
  }

  final Map<String, String> data = {};

  @override
  bool get isAvailable => true;

  @override
  Future<bool> open() async => true;

  @override
  String? readSetting(String key) => data[key];

  @override
  Future<void> writeSetting(String key, String value) async =>
      data[key] = value;

  @override
  Future<StorageRead> read(String key) async {
    final value = data[key];
    return value == null ? StorageRead.absent : StorageRead.value(value);
  }

  @override
  Future<StorageOutcome> write(String key, String value) async {
    data[key] = value;
    return StorageOutcome.committed;
  }

  @override
  Future<StorageOutcome> delete(String key) async {
    data.remove(key);
    return StorageOutcome.committed;
  }
}

/// How an injected write or delete behaves (§6.2: re-based on the contract).
enum InjectedOutcome {
  /// Applied, and reported committed.
  committed,

  /// Not applied, and reported failed.
  failed,

  /// Not applied, and reported indeterminate.
  indeterminate,

  /// Applied, but reported indeterminate: the outcome a timed-out operation
  /// that commits late produces.
  indeterminateApplied,
}

/// A [MemoryBackend] whose reads, writes and deletes can be made to fail, and
/// whose completion can be held open to force a chosen ordering.
///
/// The failure cases are the point of DF-039: the privacy promise rests on what
/// the app says when a delete fails or a write arrives late, and neither can be
/// produced on demand by a healthy browser.
///
/// The fake implements two seams with one map, so its `read` serves both: the
/// settings seam's synchronous read, and - through the contract wrapper
/// [ContentView] the store is handed - committed content reads.
class FakeBackend extends MemoryBackend {
  FakeBackend([super.seed]);

  /// Keys written, in the order they landed. Empty is the proof that a
  /// suppressed write never reached storage at all.
  final List<String> writes = [];

  final Set<String> failReads = {};

  /// Keys whose stored value is not a string - what a browser can hold under a
  /// key (null, undefined, another type). Read back as present-undecodable.
  final Set<String> undecodable = {};
  final Set<String> failWrites = {};
  final Set<String> failDeletes = {};
  final Map<String, Completer<void>> _stalls = {};

  /// Outcomes to inject for the next writes or deletes of a key, consumed in
  /// order. Takes precedence over [failWrites] and [failDeletes].
  final Map<String, List<InjectedOutcome>> injectWrites = {};
  final Map<String, List<InjectedOutcome>> injectDeletes = {};

  /// Fails the n-th content write of a key (1-based), counting from now.
  final Map<String, int> failNthWrite = {};
  final Map<String, int> _writeCount = {};
  final Map<String, int> _failNthBase = {};

  /// How many content deletes were really issued per key: the proof that a
  /// Retry performs a new deletion rather than trusting an earlier belief.
  final Map<String, int> deleteCalls = {};

  /// How many content reads were issued per key.
  final Map<String, int> readCalls = {};

  /// Holds the next operation on [key] open until the returned completer is
  /// completed, so a test can place a second operation behind a first
  /// deterministically instead of relying on timing.
  Completer<void> stall(String key) => _stalls[key] = Completer<void>();

  /// The settings seam: synchronous, throws when presence cannot be read.
  @override
  String? readSetting(String key) {
    if (failReads.contains(key)) {
      throw StateError('injected read failure for "$key"');
    }
    return super.readSetting(key);
  }

  /// The settings seam's write. Settings writes are not content writes, but
  /// they are recorded and fail the same way, as before.
  @override
  Future<void> writeSetting(String key, String value) async {
    await _awaitStall(key);
    if (failWrites.contains(key)) {
      throw StateError('injected write failure for "$key"');
    }
    writes.add(key);
    data[key] = value;
  }

  /// The content contract's committed read.
  @override
  Future<StorageRead> read(String key) async {
    readCalls[key] = (readCalls[key] ?? 0) + 1;
    await _awaitStall('read:$key');
    if (failReads.contains(key)) return StorageRead.indeterminate;
    if (undecodable.contains(key) && data.containsKey(key)) {
      return StorageRead.undecodable;
    }
    final value = data[key];
    return value == null ? StorageRead.absent : StorageRead.value(value);
  }

  @override
  Future<StorageOutcome> write(String key, String value) async {
    await _awaitStall(key);
    final count = _writeCount[key] = (_writeCount[key] ?? 0) + 1;
    final injected = _next(injectWrites, key);
    final failNth = failNthWrite[key];
    if (failNth != null) {
      // Counted from when it was set: the first write after that is 1.
      final target = _failNthBase[key] ??= count - 1 + failNth;
      if (count == target) {
        failNthWrite.remove(key);
        _failNthBase.remove(key);
        return StorageOutcome.failed;
      }
    }
    final mode =
        injected ??
        (failWrites.contains(key)
            ? InjectedOutcome.failed
            : InjectedOutcome.committed);
    switch (mode) {
      case InjectedOutcome.failed:
        return StorageOutcome.failed;
      case InjectedOutcome.indeterminate:
        return StorageOutcome.indeterminate;
      case InjectedOutcome.committed:
      case InjectedOutcome.indeterminateApplied:
        writes.add(key);
        data[key] = value;
        return mode == InjectedOutcome.committed
            ? StorageOutcome.committed
            : StorageOutcome.indeterminate;
    }
  }

  @override
  Future<StorageOutcome> delete(String key) async {
    await _awaitStall(key);
    deleteCalls[key] = (deleteCalls[key] ?? 0) + 1;
    final mode =
        _next(injectDeletes, key) ??
        (failDeletes.contains(key)
            ? InjectedOutcome.failed
            : InjectedOutcome.committed);
    switch (mode) {
      case InjectedOutcome.failed:
        return StorageOutcome.failed;
      case InjectedOutcome.indeterminate:
        return StorageOutcome.indeterminate;
      case InjectedOutcome.committed:
      case InjectedOutcome.indeterminateApplied:
        data.remove(key);
        return mode == InjectedOutcome.committed
            ? StorageOutcome.committed
            : StorageOutcome.indeterminate;
    }
  }

  InjectedOutcome? _next(Map<String, List<InjectedOutcome>> queue, String key) {
    final list = queue[key];
    if (list == null || list.isEmpty) return null;
    return list.removeAt(0);
  }

  Future<void> _awaitStall(String key) async {
    final stall = _stalls.remove(key);
    if (stall != null) await stall.future;
  }
}

/// Stands in for a browser that refused to open storage at all.
class UnavailableBackend implements StorageBackend, SettingsBackend {
  @override
  bool get isAvailable => false;

  @override
  Future<bool> open() async => false;

  @override
  String? readSetting(String key) => throw StateError('no storage');

  @override
  Future<void> writeSetting(String key, String value) async =>
      throw StateError('no storage');

  @override
  Future<StorageRead> read(String key) async => StorageRead.unavailable;

  @override
  Future<StorageOutcome> write(String key, String value) async =>
      StorageOutcome.unavailable;

  @override
  Future<StorageOutcome> delete(String key) async => StorageOutcome.unavailable;
}

/// A retained-state source a test controls directly, for tests that exercise
/// the store without the app.
class TestRetainedSource {
  List<MarkdownDocument> documents = [];
  String? activeId;
  Map<String, ReadingPosition> positions = {};
  int documentsRevision = 0;
  int readingStateRevision = 0;

  late final RetainedStateSource source = _snapshot;

  RetainedSnapshot _snapshot() => RetainedSnapshot(
    documents: List.unmodifiable(documents),
    activeId: activeId,
    positions: Map.unmodifiable(positions),
    documentsRevision: documentsRevision,
    readingStateRevision: readingStateRevision,
  );
}

final Expando<TestRetainedSource> _testSources = Expando();

/// The single-document write calls v1.6.1's store had, for the DF-039 tests.
///
/// DF-020 removed `saveDocument` and `savePosition` from the store (§5.3): no
/// caller may hand the store a snapshot of its own any more. These adapters keep
/// the DF-039 tests' meaning by doing what the app now does - put the document
/// or place in the retained state, then request the matching writer - so the
/// tests exercise the real gated writers, generations, suppression and queue.
/// They model v1.6.1's one-document slot: saving a document makes it the only
/// one retained.
extension LegacyStoreWrites on Store {
  TestRetainedSource get testSource {
    var source = _testSources[this];
    if (source == null || !identical(retainedSource, source.source)) {
      // A fresh store (after `init`) starts with nothing retained.
      source = _testSources[this] = TestRetainedSource();
      registerRetainedSource(source.source);
    }
    return source;
  }

  /// Puts [document] (and optionally [position]) in the retained state without
  /// writing anything.
  void retainForTest(MarkdownDocument document, {ReadingPosition? position}) {
    final source = testSource;
    source.documents = [document];
    source.activeId = document.id;
    source.positions = {
      if (position != null && position.documentId == document.id)
        document.id: position,
    };
    source.documentsRevision++;
    source.readingStateRevision++;
  }

  Future<WriteOutcome> saveDocument(MarkdownDocument document) {
    final source = testSource;
    final keep = source.positions[document.id];
    retainForTest(document, position: keep);
    return requestDocumentsWrite().then((receipt) => receipt.reported);
  }

  Future<WriteOutcome> savePosition(ReadingPosition position) {
    final source = testSource;
    source.positions = {...source.positions, position.documentId: position};
    source.readingStateRevision++;
    return requestReadingStateWrite().then((receipt) => receipt.reported);
  }
}

/// `retention.enable` with [document] (and [position]) retained first.
///
/// v1.6.1's `enable` took the document to save as an argument. DF-020's writes
/// what is open (§5.4), so the test puts the document in the retained state
/// first, as opening it in the app does, and then enables.
Future<RetentionTransitionResult> enableRetaining(
  RetentionController controller, {
  required Settings current,
  MarkdownDocument? document,
  ReadingPosition? position,
}) {
  if (document != null) {
    (controller.debugStore as Store).retainForTest(
      document,
      position: position,
    );
  }
  return controller.enable(current: current);
}

/// The active document's stored place, from a raw `position` value in either
/// stored shape: v1.6.1's position object, or DF-020's reading-state envelope
/// (D-8), whose place for the active document is the one a relaunch resumes.
ReadingPosition? storedActivePosition(String raw) {
  final decoded = decodeReadingKey(raw);
  if (!decoded.isDecodable) return null;
  final active = decoded.activeId;
  if (active != null) return decoded.positions[active];
  return decoded.positions.length == 1 ? decoded.positions.values.single : null;
}
