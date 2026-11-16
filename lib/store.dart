import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'models.dart';
import 'retained_format.dart';
import 'retention.dart';
import 'storage/content_backend.dart';
import 'storage/storage_backend.dart';

export 'storage/storage_backend.dart';

/// Hive-backed [SettingsBackend]: the `settings` key, and nothing else.
///
/// Hive also creates and opens the IndexedDB database at startup, which the
/// content backend then uses. It never reads, writes or deletes a content key.
class HiveSettingsBackend implements SettingsBackend {
  HiveSettingsBackend(this._box);

  final Box<String> _box;

  @override
  bool get isAvailable => true;

  @override
  String? readSetting(String key) => _box.get(key);

  @override
  Future<void> writeSetting(String key, String value) => _box.put(key, value);
}

/// Everything the app retains, captured at one instant.
///
/// The app supplies this through a [RetainedStateSource] so that a write takes
/// its snapshot when it runs rather than when it was requested, and so that the
/// snapshot and the revision it describes are always captured together.
class RetainedSnapshot {
  const RetainedSnapshot({
    required this.documents,
    required this.activeId,
    required this.positions,
    required this.documentsRevision,
    required this.readingStateRevision,
  });

  static const RetainedSnapshot empty = RetainedSnapshot(
    documents: [],
    activeId: null,
    positions: {},
    documentsRevision: 0,
    readingStateRevision: 0,
  );

  final List<MarkdownDocument> documents;
  final String? activeId;
  final Map<String, ReadingPosition> positions;
  final int documentsRevision;
  final int readingStateRevision;

  bool get isEmpty => documents.isEmpty;
}

/// Returns the current retained state synchronously. Must not await.
typedef RetainedStateSource = RetainedSnapshot Function();

/// Whether a per-document removal was verified durable (§5.5).
enum RemovalOutcome { verified, notVerified }

/// The persistence boundary for document content and settings.
///
/// Document content goes through a [StorageBackend] with committed outcomes;
/// settings go through Hive. Nothing above this class knows either exists.
///
/// The DF-039 guarantees all live here and keep their meaning:
///
///   1. **Results are classified.** Every mutating operation returns what is
///      actually known about it.
///   2. **Operations are serialized and fenced.** They run in request order, one
///      at a time. A whole-store removal or a policy change bumps the content
///      generation, so a write requested before it cannot land after it.
///   3. **The retention gate lives here.** Content is never written while the
///      effective policy is OFF.
///
/// DF-020 adds the multi-document write model (§5.3): two writers, one per key,
/// that capture what they write when they run; per-key saved truth (§5.6); the
/// durable removal transaction (§5.5); and bounded settings and startup waits.
class Store implements RetentionStore {
  static const String boxName = 'markdown_viewer';
  static const String documentKey = 'document';
  static const String positionKey = 'position';
  static const String settingsKey = 'settings';
  static const List<String> contentKeys = [documentKey, positionKey];

  /// `T_set`: how long a settings write is waited for before it is reported
  /// indeterminate.
  static const Duration defaultSettingsBound = Duration(seconds: 20);

  /// `T_startup`: how long opening storage at startup is waited for.
  static const Duration defaultStartupBound = Duration(seconds: 20);

  StorageBackend? _content;
  SettingsBackend? _settings;
  bool _available = false;
  Duration _settingsBound = defaultSettingsBound;

  /// The last committed state known for each content key: what the last read
  /// observed, or what the last committed write or delete left. This is what
  /// presence and decoding are answered from - never a cache that can diverge
  /// from committed state, because it changes only on committed outcomes and
  /// reads, and becomes indeterminate whenever an outcome is unknown.
  final Map<String, StorageRead> _committed = {};

  /// Whether the `document` key is known to hold a committed version-2 set.
  /// Until it does, no version-2 reading state may be written (§5.2).
  bool _documentsKeyCurrent = false;

  /// Every durable operation is chained onto this tail.
  ///
  /// Null when nothing is pending: a `Future` belongs to the zone that created
  /// it, and a queue that always held one would anchor itself to whichever zone
  /// last touched it. Holding null at rest keeps the queue re-entrant across
  /// zones, which widget tests driving the real app need. Reset by [init].
  Future<void>? _tail;

  /// Bumped by every whole-store removal and policy change. A content write
  /// requested under an older value is not applied.
  int _contentGeneration = 0;

  /// Bumped by every settings request, so a request superseded before it is
  /// issued is never issued.
  int _settingsGeneration = 0;

  RetentionPolicy _policy = RetentionPolicy.off;

  /// Documents whose durable removal was verified or requested this page
  /// lifetime. Content containing them is never written again. IDs are never
  /// reused (§4.2), so this never needs pruning.
  final Set<String> _suppressedIds = {};

  bool _offPolicyDataUnresolved = false;

  RetainedStateSource? _source;

  int? _confirmedDocumentsRevision;
  int? _confirmedReadingStateRevision;

  _PendingWrite? _waitingDocuments;
  _PendingWrite? _waitingReadingState;

  /// Changes whenever saved truth changes, so the UI can re-derive what it
  /// claims about saved state.
  final ValueNotifier<int> savedState = ValueNotifier<int>(0);

  /// Instrumentation for the compiled storage harness: how many boxes opened
  /// after the startup bound expired and were closed again.
  static int lateBoxesClosed = 0;

  /// False when storage could not be opened - Private Browsing being the
  /// realistic case. The app then runs entirely in memory.
  bool get isAvailable => _available;

  @override
  RetentionPolicy get effectivePolicy => _policy;

  @override
  bool get offPolicyDataUnresolved => _offPolicyDataUnresolved;

  @override
  void setOffPolicyDataUnresolved(bool value) {
    _offPolicyDataUnresolved = value;
  }

  /// Sets the policy in force for this page lifetime.
  ///
  /// Bumping the content generation here is what makes an ON to OFF transition
  /// take effect immediately: writes already queued under the previous policy
  /// are invalidated the moment the policy changes.
  @override
  void applyResolvedPolicy(RetentionPolicy policy) {
    if (_policy == policy) return;
    _policy = policy;
    _contentGeneration++;
  }

  /// Opens storage. Content is not read here: the first
  /// [refreshContentPresence] - startup resolution makes it - reads both keys
  /// once, which is the two startup reads §5.11 counts. Until then presence is
  /// unknown, and reported as such.
  ///
  /// [backend] and [settings] are for tests: a test backend that also
  /// implements [SettingsBackend] serves both. Production opens Hive, bounded
  /// by [startupBound], and the platform's content backend.
  ///
  /// Also resets every queue, generation, suppression and confirmation, so a
  /// test can call this repeatedly to get an isolated store.
  Future<void> init({
    StorageBackend? backend,
    SettingsBackend? settings,
    Duration settingsBound = defaultSettingsBound,
    Duration startupBound = defaultStartupBound,
  }) async {
    _tail = null;
    _contentGeneration = 0;
    _settingsGeneration = 0;
    _policy = RetentionPolicy.off;
    _suppressedIds.clear();
    _offPolicyDataUnresolved = false;
    _source = null;
    _waitingDocuments = null;
    _waitingReadingState = null;
    _committed.clear();
    _documentsKeyCurrent = false;
    _settingsBound = settingsBound;
    _available = false;

    if (backend != null) {
      _content = backend;
      _settings =
          settings ??
          (backend is SettingsBackend ? backend as SettingsBackend : null);
    } else {
      final box = await _openSettingsBox(startupBound);
      _settings = box == null ? null : HiveSettingsBackend(box);
      _content = box == null ? null : createContentBackend();
    }

    final content = _content;
    final settingsOpen = _settings?.isAvailable ?? false;
    var contentOpen = false;
    if (settingsOpen && content != null) {
      try {
        contentOpen = await content.open();
      } catch (error) {
        debugPrint('Store: content storage could not be opened: $error');
      }
    }
    _available = settingsOpen && contentOpen;

    for (final key in contentKeys) {
      _committed[key] = _available
          ? StorageRead.indeterminate
          : StorageRead.unavailable;
    }
    _confirmedDocumentsRevision = null;
    _confirmedReadingStateRevision = null;
    _startupCreditPending = true;
    _notify();
  }

  /// Whether the next content read of both keys is the startup read, which
  /// grants the startup confirmations (§5.6).
  bool _startupCreditPending = false;

  /// Opens the Hive box, waiting at most [bound]. A box that opens after the
  /// bound is closed at once: this page lifetime has already chosen to run in
  /// memory, and an open connection would block other tabs' upgrades.
  Future<Box<String>?> _openSettingsBox(Duration bound) async {
    try {
      await Hive.initFlutter();
    } catch (error) {
      debugPrint('Store unavailable, continuing in memory only: $error');
      return null;
    }
    final result = Completer<Box<String>?>();
    final timer = Timer(bound, () {
      if (!result.isCompleted) result.complete(null);
    });
    Hive.openBox<String>(boxName).then(
      (box) {
        timer.cancel();
        if (result.isCompleted) {
          lateBoxesClosed++;
          unawaited(box.close());
        } else {
          result.complete(box);
        }
      },
      onError: (Object error, StackTrace stack) {
        timer.cancel();
        debugPrint('Store unavailable, continuing in memory only: $error');
        debugPrintStack(stackTrace: stack);
        if (!result.isCompleted) result.complete(null);
      },
    );
    final box = await result.future;
    if (box == null) {
      debugPrint('Store: storage did not open in time; continuing in memory.');
    }
    return box;
  }

  int? _confirmedAtStartup(String key) {
    final read = _committed[key]!;
    if (read.kind == StorageReadKind.absent) return 0;
    if (read.kind != StorageReadKind.value) return null;
    final decodable = key == documentKey
        ? decodeDocumentKey(read.value!).isDecodable
        : decodeReadingKey(read.value!).isDecodable;
    return decodable ? 0 : null;
  }

  // --- Retained state -------------------------------------------------------

  /// Registers where the content writers take their snapshots from. The app
  /// registers its session; a write with no source has nothing to write.
  void registerRetainedSource(RetainedStateSource? source) {
    _source = source;
  }

  /// The registered source. Test seam only.
  @visibleForTesting
  RetainedStateSource? get retainedSource => _source;

  /// Unregisters [source] if it is still the one registered.
  void unregisterRetainedSource(RetainedStateSource source) {
    if (identical(_source, source)) _source = null;
  }

  @override
  bool get hasContentToRetain => !(_source?.call().isEmpty ?? true);

  /// The documents, active document and positions stored, decoded from the
  /// committed record, or null when no document set decodes.
  ///
  /// The caller decides whether it may be read at all: startup reads it only
  /// under a confirmed ON policy (I-7).
  RetainedState? loadRetained() {
    final documents = _committed[documentKey];
    if (documents == null || documents.kind != StorageReadKind.value) {
      return null;
    }
    final reading = _committed[positionKey];
    return combineRetained(
      decodeDocumentKey(documents.value!),
      reading?.kind == StorageReadKind.value
          ? decodeReadingKey(reading!.value!)
          : (reading == null || reading.kind == StorageReadKind.absent)
          ? null
          : DecodedReadingState.undecodable,
    );
  }

  /// The active stored document, or null.
  MarkdownDocument? loadDocument() => loadRetained()?.active;

  String? _idsDecodedFrom;
  Set<String>? _idsDecoded;

  /// The IDs in the committed document set, or null when the `document` key
  /// is absent, undecodable or unknown. Decoded once per committed value.
  Set<String>? get committedDocumentIds {
    final read = _committed[documentKey];
    if (read == null || read.kind != StorageReadKind.value) return null;
    if (!identical(_idsDecodedFrom, read.value)) {
      final decoded = decodeDocumentKey(read.value!);
      _idsDecodedFrom = read.value;
      _idsDecoded = decoded.isDecodable
          ? {for (final document in decoded.documents) document.id}
          : null;
    }
    return _idsDecoded;
  }

  /// The stored position for [documentId], or null. A stored position always
  /// belongs to the document it names, so a replaced document can never pass
  /// its place to another.
  ReadingPosition? loadPosition(String documentId) {
    final reading = _committed[positionKey];
    if (reading == null || reading.kind != StorageReadKind.value) return null;
    final decoded = decodeReadingKey(reading.value!);
    final position = decoded.positions[documentId];
    return position?.documentId == documentId ? position : null;
  }

  // --- Saved truth (§5.6) ---------------------------------------------------

  /// The documents revision last confirmed stored exactly, or null when what
  /// the key holds is not known to match any revision.
  int? get confirmedDocumentsRevision => _confirmedDocumentsRevision;

  /// The reading-state revision last confirmed stored exactly, or null.
  int? get confirmedReadingStateRevision => _confirmedReadingStateRevision;

  void _credit(String key, int? revision) {
    _startupCreditPending = false;
    if (key == documentKey) {
      _confirmedDocumentsRevision = revision;
    } else {
      _confirmedReadingStateRevision = revision;
    }
    _notify();
  }

  void _notify() => savedState.value++;

  // --- Content writers (§5.3) -----------------------------------------------

  /// Requests a write of the documents projection.
  ///
  /// The write captures the session when it runs, so it covers every change
  /// made before then. At most one not-yet-started write per key waits in the
  /// queue; a request made while one waits joins it.
  @override
  Future<WriteReceipt> requestDocumentsWrite() => _requestWrite(documentKey);

  /// Requests a write of the reading state: the active document and positions.
  @override
  Future<WriteReceipt> requestReadingStateWrite() => _requestWrite(positionKey);

  Future<WriteReceipt> _requestWrite(String key) {
    if (_policy == RetentionPolicy.off) {
      return Future.value(
        WriteReceipt(
          key: key,
          outcome: WriteOutcome.suppressedByPolicy,
          revision: _currentRevision(key),
          exact: false,
        ),
      );
    }
    final waiting = key == documentKey
        ? _waitingDocuments
        : _waitingReadingState;
    if (waiting != null &&
        !waiting.started &&
        waiting.generation == _contentGeneration) {
      return waiting.receipt;
    }
    final pending = _PendingWrite(_contentGeneration);
    if (key == documentKey) {
      _waitingDocuments = pending;
    } else {
      _waitingReadingState = pending;
    }
    pending.receipt = _enqueue(() {
      pending.started = true;
      if (identical(_waitingDocuments, pending)) _waitingDocuments = null;
      if (identical(_waitingReadingState, pending)) _waitingReadingState = null;
      return _runWrite(key, pending.generation);
    });
    return pending.receipt;
  }

  int _currentRevision(String key) {
    final snapshot = _source?.call() ?? RetainedSnapshot.empty;
    return key == documentKey
        ? snapshot.documentsRevision
        : snapshot.readingStateRevision;
  }

  Future<WriteReceipt> _runWrite(String key, int generation) async {
    WriteReceipt unconfirmed(WriteOutcome outcome) {
      final receipt = WriteReceipt(
        key: key,
        outcome: outcome,
        revision: _currentRevision(key),
        exact: false,
      );
      _credit(key, null);
      return receipt;
    }

    if (generation != _contentGeneration) {
      return unconfirmed(WriteOutcome.superseded);
    }
    if (_policy == RetentionPolicy.off) {
      return unconfirmed(WriteOutcome.suppressedByPolicy);
    }
    if (!_available || _content == null) {
      return unconfirmed(WriteOutcome.unavailable);
    }
    if (_source == null) return unconfirmed(WriteOutcome.superseded);

    // §5.2 ordering: no version-2 reading state is written until the
    // documents key is known to hold a committed version-2 set.
    if (key == positionKey &&
        !_documentsKeyCurrent &&
        !_source!.call().isEmpty) {
      final documents = await _writeKey(documentKey);
      if (!documents.confirmed) return unconfirmed(WriteOutcome.deferred);
    }
    return _writeKey(key);
  }

  /// Captures [key]'s projection from the source and writes it, or deletes the
  /// key when nothing is open. Credits the key only for an exact, committed
  /// write of the snapshot it captured.
  Future<WriteReceipt> _writeKey(String key) async {
    final snapshot = _source!.call();
    final revision = key == documentKey
        ? snapshot.documentsRevision
        : snapshot.readingStateRevision;
    final kept = [
      for (final document in snapshot.documents)
        if (!_suppressedIds.contains(document.id)) document,
    ];
    // Defence in depth: the session can never hold a suppressed ID (§5.5), so
    // this filter removing anything would make the write a projection rather
    // than the snapshot, and it is then not credited.
    final exact = kept.length == snapshot.documents.length;
    final keptIds = {for (final document in kept) document.id};
    final String? value;
    if (kept.isEmpty) {
      value = null;
    } else if (key == documentKey) {
      value = encodeDocumentSet(kept);
    } else {
      final activeId = keptIds.contains(snapshot.activeId)
          ? snapshot.activeId
          : kept.first.id;
      value = encodeReadingState(activeId, {
        for (final entry in snapshot.positions.entries)
          if (keptIds.contains(entry.key)) entry.key: entry.value,
      });
    }

    final outcome = await _store(key, value);
    final receipt = WriteReceipt(
      key: key,
      outcome: _writeOutcome(outcome),
      revision: revision,
      exact: exact,
    );
    _credit(key, receipt.confirmed ? revision : null);
    return receipt;
  }

  /// Writes or deletes one key and keeps the committed record true.
  Future<StorageOutcome> _store(String key, String? value) async {
    final StorageOutcome outcome;
    try {
      outcome = value == null
          ? await _content!.delete(key)
          : await _content!.write(key, value);
    } catch (error) {
      debugPrint('Store: content operation on "$key" threw: $error');
      _recordUnknown(key);
      return StorageOutcome.indeterminate;
    }
    switch (outcome) {
      case StorageOutcome.committed:
        _committed[key] = value == null
            ? StorageRead.absent
            : StorageRead.value(value);
        if (key == documentKey) _documentsKeyCurrent = value != null;
      case StorageOutcome.indeterminate:
        _recordUnknown(key);
      case StorageOutcome.failed:
      case StorageOutcome.unavailable:
        // Definitely not applied: the committed state is what it was.
        break;
    }
    return outcome;
  }

  void _recordUnknown(String key) {
    _committed[key] = StorageRead.indeterminate;
    if (key == documentKey) _documentsKeyCurrent = false;
  }

  static WriteOutcome _writeOutcome(StorageOutcome outcome) =>
      switch (outcome) {
        StorageOutcome.committed => WriteOutcome.saved,
        StorageOutcome.failed => WriteOutcome.failed,
        StorageOutcome.indeterminate => WriteOutcome.indeterminate,
        StorageOutcome.unavailable => WriteOutcome.unavailable,
      };

  Future<StorageRead> _readContent(String key) async {
    try {
      final read = await _content!.read(key);
      _committed[key] = read;
      if (key == documentKey) {
        _documentsKeyCurrent =
            read.kind == StorageReadKind.value &&
            isCurrentDocumentSet(read.value!);
      }
      return read;
    } catch (error) {
      debugPrint('Store: could not read "$key": $error');
      _recordUnknown(key);
      return StorageRead.indeterminate;
    }
  }

  // --- Per-document removal (§5.5) ------------------------------------------

  /// Removes [ids] from both keys and verifies it by a committed read before
  /// the session changes (E-1, D-6).
  ///
  /// Runs as one queue operation. When removal is verified, [onVerified] - the
  /// app's synchronous session change - runs inside that operation, so no
  /// write can start between verification and the change. When it is not
  /// verified the session is never touched, and the caller restores.
  ///
  /// [successorActiveId] is the active document after a close (D-11); for a
  /// replacement pass [replacing], and the current active document is kept
  /// unless it is being replaced.
  Future<RemovalOutcome> removeDocuments(
    Set<String> ids, {
    String? successorActiveId,
    bool replacing = false,
    required void Function() onVerified,
  }) {
    final generation = _contentGeneration;
    return _enqueue(() async {
      if (generation != _contentGeneration ||
          _policy != RetentionPolicy.on ||
          !_available ||
          _content == null ||
          _source == null) {
        return RemovalOutcome.notVerified;
      }

      // The projection: the session without [ids].
      final snapshot = _source!.call();
      final remaining = [
        for (final document in snapshot.documents)
          if (!ids.contains(document.id)) document,
      ];
      final remainingIds = {for (final document in remaining) document.id};
      final String? activeId;
      if (remaining.isEmpty) {
        activeId = null;
      } else if (replacing) {
        activeId = remainingIds.contains(snapshot.activeId)
            ? snapshot.activeId
            : remaining.first.id;
      } else {
        activeId = remainingIds.contains(successorActiveId)
            ? successorActiveId
            : remaining.first.id;
      }
      final documentsValue = remaining.isEmpty
          ? null
          : encodeDocumentSet(remaining);
      final readingValue = remaining.isEmpty
          ? null
          : encodeReadingState(activeId, {
              for (final entry in snapshot.positions.entries)
                if (remainingIds.contains(entry.key)) entry.key: entry.value,
            });

      // Reading state first, so a documents write that does not confirm
      // leaves every old document's content and at worst loses places. On
      // unmigrated data the documents projection goes first (§5.2).
      final order = _documentsKeyCurrent
          ? [(positionKey, readingValue), (documentKey, documentsValue)]
          : [(documentKey, documentsValue), (positionKey, readingValue)];

      var confirmed = true;
      for (final (key, value) in order) {
        // This key now holds, or may hold, a projection.
        _credit(key, null);
        if (await _store(key, value) != StorageOutcome.committed) {
          confirmed = false;
          break;
        }
      }
      if (!confirmed) return RemovalOutcome.notVerified;

      // Verification by committed read (C2): every key absent, or decodable
      // and free of every removed ID.
      final documentsRead = await _readContent(documentKey);
      final readingRead = await _readContent(positionKey);
      if (!_freeOf(documentsRead, ids, isDocuments: true) ||
          !_freeOf(readingRead, ids, isDocuments: false)) {
        return RemovalOutcome.notVerified;
      }

      _suppressedIds.addAll(ids);
      onVerified();
      return RemovalOutcome.verified;
    });
  }

  static bool _freeOf(
    StorageRead read,
    Set<String> ids, {
    required bool isDocuments,
  }) {
    if (read.kind == StorageReadKind.absent) return true;
    if (read.kind != StorageReadKind.value) return false;
    if (isDocuments) {
      final decoded = decodeDocumentKey(read.value!);
      return decoded.isDecodable &&
          decoded.documents.every((document) => !ids.contains(document.id));
    }
    final decoded = decodeReadingKey(read.value!);
    return decoded.isDecodable &&
        !ids.contains(decoded.activeId) &&
        decoded.positions.keys.every((id) => !ids.contains(id));
  }

  // --- Raw presence and whole-store removal ---------------------------------

  /// Whether a content key is stored, from the committed record, without
  /// decoding it.
  ///
  /// A record that does not decode is still stored data; reporting it absent
  /// is how content becomes retained but unreachable.
  RawKeyPresence rawKeyPresence(String key) {
    if (!_available) return RawKeyPresence.indeterminate;
    final read = _committed[key];
    if (read == null) return RawKeyPresence.indeterminate;
    if (read.isPresent) return RawKeyPresence.present;
    if (read.kind == StorageReadKind.absent) return RawKeyPresence.absent;
    return RawKeyPresence.indeterminate;
  }

  /// Re-reads both content keys by committed read (C2), after everything
  /// already queued, so presence reflects what is stored now.
  ///
  /// Startup and the enable interlock decide on presence, and each reads both
  /// keys to do so (§5.11 counts these reads).
  @override
  Future<void> refreshContentPresence() => _enqueue(() async {
    if (!_available || _content == null) return;
    for (final key in contentKeys) {
      await _readContent(key);
    }
    if (_startupCreditPending) {
      _startupCreditPending = false;
      // A key read at startup and found decodable is confirmed at revision 0,
      // the revision every page lifetime's session starts at (§5.6). An absent
      // key is confirmed too: it decodes exactly to an empty session.
      _confirmedDocumentsRevision = _confirmedAtStartup(documentKey);
      _confirmedReadingStateRevision = _confirmedAtStartup(positionKey);
      _notify();
    }
  });

  /// Presence of either content key.
  @override
  RawKeyPresence rawContentPresence() {
    final document = rawKeyPresence(documentKey);
    final position = rawKeyPresence(positionKey);
    if (document == RawKeyPresence.present ||
        position == RawKeyPresence.present) {
      return RawKeyPresence.present;
    }
    if (document == RawKeyPresence.indeterminate ||
        position == RawKeyPresence.indeterminate) {
      return RawKeyPresence.indeterminate;
    }
    return RawKeyPresence.absent;
  }

  /// Removes both content keys and verifies their absence by committed read.
  ///
  /// The generation bump is synchronous and happens before anything is
  /// enqueued, so a write requested but not yet running is invalidated the
  /// instant removal is asked for. Deletes are unconditional (C3), so a Retry
  /// always issues real deletions whatever was believed before.
  ///
  /// [suppressDocumentId] and [suppressDocumentIds] name documents the user
  /// removed: nothing containing them is written again.
  @override
  Future<CleanupOutcome> removeRetainedContent({
    String? suppressDocumentId,
    Iterable<String> suppressDocumentIds = const [],
  }) {
    _contentGeneration++;
    if (suppressDocumentId != null) _suppressedIds.add(suppressDocumentId);
    _suppressedIds.addAll(suppressDocumentIds);
    return _enqueue(_deleteAndVerify);
  }

  Future<CleanupOutcome> _deleteAndVerify() async {
    _credit(documentKey, null);
    _credit(positionKey, null);
    if (!_available || _content == null) {
      // Nothing could have been written by this session, but what an earlier
      // session left behind cannot be read and so cannot be declared gone.
      return CleanupOutcome.indeterminate;
    }
    // Presence before the attempt, so the outcome can tell "removed some of
    // it" from "removed none of it". A read that fails does not stop the
    // delete: they can fail independently.
    final before = await _presentContentKeys();
    for (final key in contentKeys) {
      final outcome = await _store(key, null);
      if (outcome != StorageOutcome.committed) {
        // Kept going deliberately: a failure on one key is not a reason to
        // leave the other behind. Verification decides the outcome.
        debugPrint('Store: delete of "$key" was ${outcome.name}');
      }
    }
    final after = await _presentContentKeys();
    if (after == null) return CleanupOutcome.indeterminate;
    if (after.isEmpty) return CleanupOutcome.confirmedAbsent;
    if (before == null || after.length == before.length) {
      return CleanupOutcome.failed;
    }
    return CleanupOutcome.partiallyPresent;
  }

  /// The content keys present by committed read, or null when presence is
  /// unknowable.
  Future<Set<String>?> _presentContentKeys() async {
    final present = <String>{};
    var unknown = false;
    for (final key in contentKeys) {
      final read = await _readContent(key);
      if (read.isUnknown) unknown = true;
      if (read.isPresent) present.add(key);
    }
    return unknown ? null : present;
  }

  // --- Settings -------------------------------------------------------------

  Settings loadSettings() => loadSettingsResult().settings;

  /// Reads settings and reports how confidently they were read.
  ///
  /// Distinguishes "no record yet" from "a record that will not decode": the
  /// first is a fresh install where default OFF is correct, the second means
  /// the saved choice is not being honoured, which the user is told.
  @override
  SettingsLoadResult loadSettingsResult() {
    final backend = _available ? _settings : null;
    if (backend == null) {
      return const SettingsLoadResult(
        settings: Settings(),
        outcome: SettingsReadOutcome.unavailable,
        retentionFieldPresent: false,
      );
    }
    try {
      final raw = backend.readSetting(settingsKey);
      if (raw == null || raw.isEmpty) {
        return const SettingsLoadResult(
          settings: Settings(),
          outcome: SettingsReadOutcome.missing,
          retentionFieldPresent: false,
        );
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return const SettingsLoadResult(
          settings: Settings(),
          outcome: SettingsReadOutcome.unreadable,
          retentionFieldPresent: false,
        );
      }
      final map = Map<String, dynamic>.from(decoded);
      return SettingsLoadResult(
        settings: Settings.fromJson(map),
        outcome: SettingsReadOutcome.loaded,
        retentionFieldPresent: map.containsKey(Settings.keepForNextTimeKey),
      );
    } catch (error) {
      debugPrint('Store: could not read settings: $error');
      return const SettingsLoadResult(
        settings: Settings(),
        outcome: SettingsReadOutcome.unreadable,
        retentionFieldPresent: false,
      );
    }
  }

  /// Persists settings. Never gated on retention policy: appearance and the
  /// retention choice itself must survive whatever happens to content.
  ///
  /// The wait for the write is bounded by `T_set` (§5.3). Past it the outcome
  /// is [WriteOutcome.indeterminate] - the write may still land, and since
  /// IndexedDB commits writes in the order they were created, it can only land
  /// before any later one. A request superseded before it is issued is never
  /// issued.
  @override
  Future<WriteOutcome> saveSettings(Settings settings) {
    final generation = ++_settingsGeneration;
    return _enqueue(() async {
      if (generation != _settingsGeneration) return WriteOutcome.superseded;
      final backend = _available ? _settings : null;
      if (backend == null) return WriteOutcome.unavailable;
      return _boundedSettingsWrite(backend, jsonEncode(settings.toJson()));
    });
  }

  Future<WriteOutcome> _boundedSettingsWrite(
    SettingsBackend backend,
    String value,
  ) {
    final result = Completer<WriteOutcome>();
    final timer = Timer(_settingsBound, () {
      if (!result.isCompleted) result.complete(WriteOutcome.indeterminate);
    });
    Future<void> write;
    try {
      write = backend.writeSetting(settingsKey, value);
    } catch (error) {
      write = Future.error(error);
    }
    write.then(
      (_) {
        timer.cancel();
        if (!result.isCompleted) result.complete(WriteOutcome.saved);
      },
      onError: (Object error) {
        timer.cancel();
        debugPrint('Store: could not write settings: $error');
        if (!result.isCompleted) result.complete(WriteOutcome.failed);
      },
    );
    return result.future;
  }

  // --- Plumbing -------------------------------------------------------------

  /// Runs [operation] after every previously enqueued operation has finished.
  ///
  /// [_tail] is replaced synchronously, before the first `await`, so queue
  /// order is call order. A predecessor that throws cannot break the chain:
  /// if the queue ever wedged, durable writes would stop silently while the
  /// app carried on as though they were landing.
  Future<T> _enqueue<T>(Future<T> Function() operation) async {
    final previous = _tail;
    final gate = Completer<void>();
    _tail = gate.future;
    final clock = debugRecordTimings ? (Stopwatch()..start()) : null;
    if (previous != null) {
      try {
        await previous;
      } catch (_) {
        // A predecessor's failure is its caller's business, not the queue's.
      }
    }
    final waited = clock?.elapsed;
    clock?.reset();
    try {
      return await operation();
    } finally {
      if (clock != null) {
        debugTimings.add((wait: waited!, service: clock.elapsed));
      }
      gate.complete();
      if (identical(_tail, gate.future)) _tail = null;
    }
  }

  /// Harness instrumentation (§5.11): when set, each queue operation records
  /// its queue wait and its service time - from the moment it starts
  /// executing - into [debugTimings]. Off in the product.
  @visibleForTesting
  bool debugRecordTimings = false;

  @visibleForTesting
  final List<({Duration wait, Duration service})> debugTimings = [];

  /// Resolves once every operation requested before this call has finished.
  Future<void> settlePendingOperations() => _enqueue(() async {});
}

class _PendingWrite {
  _PendingWrite(this.generation);
  final int generation;
  bool started = false;
  late Future<WriteReceipt> receipt;
}

/// Single instance. The app is one screen deep; a container would be ceremony.
final Store store = Store();

/// The retention contract for that instance.
final RetentionController retention = RetentionController(store);
