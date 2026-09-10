import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'models.dart';
import 'retention.dart';

/// The raw key/value surface the store writes through.
///
/// Extracted for DF-039 so the failure, partial and out-of-order cases the
/// retention contract has to be truthful about can be produced deterministically
/// in a test. Before this the only way to observe a failed write was to break a
/// real browser, which is why the failures were never surfaced at all.
abstract class StorageBackend {
  bool get isAvailable;

  /// Returns the stored string, or null when the key is absent.
  /// Throws when presence itself cannot be established.
  String? read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// Hive-backed [StorageBackend]. Maps to IndexedDB on web and to files on
/// native, so nothing here is web-specific.
class HiveStorageBackend implements StorageBackend {
  HiveStorageBackend(this._box);

  final Box<String> _box;

  @override
  bool get isAvailable => true;

  @override
  String? read(String key) => _box.get(key);

  @override
  Future<void> write(String key, String value) => _box.put(key, value);

  @override
  Future<void> delete(String key) => _box.delete(key);
}

/// The only file in the app that knows persistence exists.
///
/// Values are stored as JSON strings rather than Hive type adapters: the schema
/// is three small classes, there is no code generation to maintain, and the
/// stored data stays readable in Safari's Web Inspector during validation.
///
/// DF-039 changed three things about how this class behaves, all of them for the
/// same reason - that a storage layer which swallows its failures cannot support
/// a truthful privacy promise:
///
///   1. **Results are classified.** Every mutating method returns what actually
///      happened. The previous contract returned `Future<void>` and caught every
///      exception, so a failed delete and a successful one were indistinguishable
///      at the call site.
///   2. **Writes are serialized and fenced.** Durable operations run in the order
///      they were requested, and each content write carries the generation it was
///      issued under. A removal bumps that generation, so a write already in
///      flight cannot land afterwards and repopulate the key that was just
///      removed.
///   3. **The retention gate lives here.** Content writes are refused while
///      effective policy is OFF. Putting the gate at the persistence boundary
///      rather than at each call site means a future caller cannot bypass it by
///      forgetting to ask.
class Store implements RetentionStore {
  static const String boxName = 'markdown_viewer';
  static const String documentKey = 'document';
  static const String positionKey = 'position';
  static const String settingsKey = 'settings';

  StorageBackend? _backend;

  /// Every durable operation is chained onto this tail.
  ///
  /// This is the settlement mechanism the retention contract needs: because
  /// operations run in request order, "wait for everything already requested to
  /// finish" is just enqueueing behind them. Verification of raw-key absence
  /// therefore runs strictly after every write that preceded it, which is what
  /// makes the absence claim meaningful rather than a race.
  ///
  /// Null means nothing is pending, and a settled queue deliberately holds no
  /// future at all. A `Future` belongs to the zone that created it, so a queue
  /// that always held one would anchor itself to whichever zone last touched it
  /// - and an operation started in a later zone would then wait forever on a
  /// future that zone can never complete. Holding null at rest keeps the queue
  /// re-entrant across zones, which is what a widget test driving the real app
  /// needs. It is also reset by [init].
  Future<void>? _tail;

  /// Bumped by every removal and by [applyResolvedPolicy]. A content write that
  /// was issued under an older value is dropped rather than applied.
  int _contentGeneration = 0;

  /// Bumped by every settings write, so only the most recently requested one
  /// lands. An older completion cannot overwrite a newer confirmed preference.
  int _settingsGeneration = 0;

  RetentionPolicy _policy = RetentionPolicy.off;

  /// False when the browser refused to open the box - Private Browsing being the
  /// realistic case. The app then runs entirely in memory rather than failing.
  bool get isAvailable => _backend?.isAvailable ?? false;

  /// The backend, but only while it is actually usable.
  ///
  /// A backend that reports itself unavailable is treated exactly like no
  /// backend at all, so every method below reaches the same honest answer -
  /// `unavailable`, `indeterminate` - rather than an incidental failure result
  /// that would read as though something specific had gone wrong.
  StorageBackend? get _live => isAvailable ? _backend : null;

  @override
  RetentionPolicy get effectivePolicy => _policy;

  /// Sets the policy in force for this page lifetime.
  ///
  /// Bumping the content generation here is what makes an ON to OFF transition
  /// take effect immediately rather than eventually: writes already queued under
  /// the previous policy are invalidated at the moment the policy changes, not
  /// when they reach the front of the queue.
  @override
  void applyResolvedPolicy(RetentionPolicy policy) {
    if (_policy == policy) return;
    _policy = policy;
    _contentGeneration++;
  }

  /// Opens durable storage. [backend] is for tests; production opens Hive.
  ///
  /// Also resets the queue, the generations and the policy, so a test can call
  /// this repeatedly to get an isolated store without reaching into privates.
  Future<void> init({StorageBackend? backend}) async {
    _tail = null;
    _contentGeneration = 0;
    _settingsGeneration = 0;
    _policy = RetentionPolicy.off;

    if (backend != null) {
      _backend = backend;
      return;
    }

    try {
      await Hive.initFlutter();
      _backend = HiveStorageBackend(await Hive.openBox<String>(boxName));
    } catch (error, stack) {
      // Never fatal. A reader that cannot persist is still a usable reader.
      debugPrint('Store unavailable, continuing in memory only: $error');
      debugPrintStack(stackTrace: stack);
      _backend = null;
    }
  }

  // --- Document -------------------------------------------------------------

  MarkdownDocument? loadDocument() {
    return _read(documentKey, MarkdownDocument.fromJson);
  }

  @override
  Future<WriteOutcome> saveDocument(MarkdownDocument document) {
    return _writeContent(documentKey, document.toJson());
  }

  // --- Reading position -----------------------------------------------------

  /// Returns the stored position only when it belongs to [documentId], so a
  /// replaced document can never inherit the previous one's position.
  ReadingPosition? loadPosition(String documentId) {
    final position = _read(positionKey, ReadingPosition.fromJson);
    if (position == null || position.documentId != documentId) return null;
    return position;
  }

  @override
  Future<WriteOutcome> savePosition(ReadingPosition position) {
    return _writeContent(positionKey, position.toJson());
  }

  // --- Raw presence and verified removal ------------------------------------

  /// Whether a raw key exists, without attempting to decode it.
  ///
  /// Presence is the honest question. A record that fails to decode is still
  /// stored data; reporting it as absent because `loadDocument` returned null is
  /// how content becomes retained but unreachable through the product.
  RawKeyPresence rawKeyPresence(String key) {
    final backend = _live;
    if (backend == null) return RawKeyPresence.indeterminate;
    try {
      final raw = backend.read(key);
      return raw == null ? RawKeyPresence.absent : RawKeyPresence.present;
    } catch (error) {
      debugPrint('Store: could not establish presence of "$key": $error');
      return RawKeyPresence.indeterminate;
    }
  }

  /// Presence of either content key, collapsed for the callers that only need
  /// to know whether any retained content exists at all.
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

  /// Removes both content keys and verifies their absence afterwards.
  ///
  /// The generation bump is synchronous and happens before anything is
  /// enqueued, so a content write that has been requested but has not yet run is
  /// invalidated the instant removal is asked for. A write that is already
  /// running is not invalidated - it is waited for, because the removal enqueues
  /// behind it - and is then deleted. Either way the verification at the end
  /// runs after every earlier operation has settled.
  @override
  Future<CleanupOutcome> removeRetainedContent() {
    _contentGeneration++;
    return _enqueue(_deleteAndVerify);
  }

  Future<CleanupOutcome> _deleteAndVerify() async {
    final backend = _live;
    if (backend == null) {
      // Nothing could have been written by this session, but what an earlier
      // session left behind cannot be read and so cannot be declared gone.
      return CleanupOutcome.indeterminate;
    }

    // Presence before the attempt, so the outcome can distinguish "removed some
    // of it" from "removed none of it". Without this an orphaned position that
    // survives its only delete would report the same partial result as a
    // document that was removed while its position survived, which are
    // different facts about how much of the removal worked.
    final before = _presentContentKeys();
    if (before == null) return CleanupOutcome.indeterminate;

    for (final key in const [documentKey, positionKey]) {
      try {
        await backend.delete(key);
      } catch (error) {
        // Kept going deliberately: a failure to delete the document is not a
        // reason to leave the position behind. The verification below decides
        // the outcome, not this exception.
        debugPrint('Store: could not delete "$key": $error');
      }
    }

    final after = _presentContentKeys();
    if (after == null) return CleanupOutcome.indeterminate;

    if (after.isEmpty) return CleanupOutcome.confirmedAbsent;
    // Everything that was there is still there: the removal achieved nothing.
    if (after.length == before.length) return CleanupOutcome.failed;
    return CleanupOutcome.partiallyPresent;
  }

  /// The content keys currently present, or null when presence is unknowable.
  Set<String>? _presentContentKeys() {
    final present = <String>{};
    for (final key in const [documentKey, positionKey]) {
      switch (rawKeyPresence(key)) {
        case RawKeyPresence.indeterminate:
          return null;
        case RawKeyPresence.present:
          present.add(key);
        case RawKeyPresence.absent:
          break;
      }
    }
    return present;
  }

  // --- Settings -------------------------------------------------------------

  Settings loadSettings() => loadSettingsResult().settings;

  /// Reads settings and reports how confidently they were read.
  ///
  /// Distinguishes "no record yet" from "a record that will not decode":
  /// the first is a fresh install where default OFF is the correct answer, the
  /// second is an error state the user is entitled to be told about, because it
  /// means their saved choice is not being honoured.
  @override
  SettingsLoadResult loadSettingsResult() {
    final backend = _live;
    if (backend == null) {
      return const SettingsLoadResult(
        settings: Settings(),
        outcome: SettingsReadOutcome.unavailable,
        retentionFieldPresent: false,
      );
    }

    try {
      final raw = backend.read(settingsKey);
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
  @override
  Future<WriteOutcome> saveSettings(Settings settings) {
    final generation = ++_settingsGeneration;
    return _enqueue(() async {
      if (generation != _settingsGeneration) {
        // A newer settings write was requested while this one waited. Applying
        // this one now would overwrite the newer value with an older one.
        return WriteOutcome.superseded;
      }
      return _put(settingsKey, settings.toJson());
    });
  }

  // --- Plumbing -------------------------------------------------------------

  /// Content writes: gated on policy at request time, fenced at run time.
  Future<WriteOutcome> _writeContent(String key, Map<String, dynamic> value) {
    if (_policy == RetentionPolicy.off) {
      return Future<WriteOutcome>.value(WriteOutcome.suppressedByPolicy);
    }
    final generation = _contentGeneration;
    return _enqueue(() async {
      if (generation != _contentGeneration) return WriteOutcome.superseded;
      if (_policy == RetentionPolicy.off) {
        return WriteOutcome.suppressedByPolicy;
      }
      return _put(key, value);
    });
  }

  Future<WriteOutcome> _put(String key, Map<String, dynamic> value) async {
    final backend = _live;
    if (backend == null) return WriteOutcome.unavailable;
    try {
      await backend.write(key, jsonEncode(value));
      return WriteOutcome.saved;
    } catch (error) {
      debugPrint('Store: could not write "$key": $error');
      return WriteOutcome.failed;
    }
  }

  /// Runs [operation] after every previously enqueued operation has finished.
  ///
  /// [_tail] is replaced synchronously, before the first `await`, so the queue
  /// order is the call order rather than whatever order the operations happen to
  /// reach the backend in.
  ///
  /// The chain is never allowed to break. A predecessor that throws is caught
  /// here, and the gate below is completed from a `finally`, so one failed or
  /// rejected operation cannot deadlock every later write. That matters more
  /// than it looks: if the queue ever wedged, durable writes would stop silently
  /// while the app carried on as though they were landing.
  Future<T> _enqueue<T>(Future<T> Function() operation) async {
    final previous = _tail;
    final gate = Completer<void>();
    _tail = gate.future;
    if (previous != null) {
      try {
        await previous;
      } catch (_) {
        // A predecessor's failure is its caller's business, not the queue's.
      }
    }
    try {
      return await operation();
    } finally {
      gate.complete();
      // Let the queue fall back to holding nothing once it drains, so an idle
      // store keeps no zone-bound future alive.
      if (identical(_tail, gate.future)) _tail = null;
    }
  }

  /// Resolves once every operation requested before this call has finished.
  ///
  /// The explicit settlement barrier. Callers that need to state a result
  /// truthfully - and tests that need to assert one deterministically - use this
  /// rather than guessing at a delay.
  Future<void> settlePendingOperations() => _enqueue(() async {});

  T? _read<T>(String key, T Function(Map<String, dynamic>) parse) {
    final backend = _live;
    if (backend == null) return null;
    try {
      final raw = backend.read(key);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return parse(Map<String, dynamic>.from(decoded));
    } catch (error) {
      // Corrupt or stale data must degrade to "nothing decodable", never crash.
      // It does not degrade to "nothing stored": rawKeyPresence above still
      // reports the key, which is what keeps it removable.
      debugPrint('Store: could not read "$key": $error');
      return null;
    }
  }
}

/// Single instance. The app is one screen deep; a container would be ceremony.
final Store store = Store();

/// The retention contract for that instance.
final RetentionController retention = RetentionController(store);
