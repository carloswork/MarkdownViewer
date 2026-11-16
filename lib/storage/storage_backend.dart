/// The storage contract document content is written through.
///
/// Pure Dart, and deliberately free of any storage technology: it speaks only of
/// string values under string keys and of what is known about whether an
/// operation took effect. The web implementation backs it with IndexedDB; a
/// future native one could back it with SQLite or a file per key. The `Store`
/// sees only this.
///
/// The contract, C1-C8:
///
///   * **C1 committed outcome.** `write` and `delete` resolve
///     [StorageOutcome.committed] only when a later app start would observe the
///     change, [StorageOutcome.failed] when the platform reports it did not
///     happen, and [StorageOutcome.indeterminate] otherwise.
///   * **C2 committed read.** A read observes committed state, never a cache that
///     can diverge from it, and observes every outcome already returned.
///   * **C3 unconditional delete.** `delete` always issues a real deletion;
///     deleting an absent key is committed.
///   * **C4 single-key atomicity.** A write replaces one value whole or not at
///     all. Nothing is promised across keys.
///   * **C5 sequential use.** One operation at a time, from the Store's queue.
///   * **C6 opaque strings.**
///   * **C7 bounded termination.** Every operation terminates within a bound.
///     [StorageOutcome.unavailable] means it was not issued;
///     [StorageOutcome.indeterminate] means it was issued and its outcome is
///     unknown. A late outcome is never reported, a failure never blocks later
///     calls, and availability is re-evaluated on every call.
///   * **C8 no late overtaking.** An operation reported indeterminate can take
///     effect only before any operation issued after it.
library;

/// What is known about whether one write or delete took effect.
enum StorageOutcome {
  /// It took effect, and a later start would observe it.
  committed,

  /// It definitely did not take effect.
  failed,

  /// It was issued, but whether it took effect is unknown. It may still
  /// commit, though never after a later operation (C8).
  indeterminate,

  /// Storage could not be reached, so it was not issued and had no effect.
  unavailable,
}

/// What one read established about a key.
enum StorageReadKind {
  absent,
  value,

  /// Something is stored that is not a string value.
  undecodable,

  /// Presence could not be established.
  indeterminate,

  /// Storage could not be reached.
  unavailable,
}

/// The result of one committed read.
class StorageRead {
  const StorageRead._(this.kind) : value = null;

  static const StorageRead absent = StorageRead._(StorageReadKind.absent);
  static const StorageRead undecodable = StorageRead._(
    StorageReadKind.undecodable,
  );
  static const StorageRead indeterminate = StorageRead._(
    StorageReadKind.indeterminate,
  );
  static const StorageRead unavailable = StorageRead._(
    StorageReadKind.unavailable,
  );

  const StorageRead.value(String this.value) : kind = StorageReadKind.value;

  final StorageReadKind kind;

  /// The stored string, for [StorageReadKind.value] only.
  final String? value;

  /// Something is known to be stored, readable or not.
  bool get isPresent =>
      kind == StorageReadKind.value || kind == StorageReadKind.undecodable;

  /// Presence could not be established either way.
  bool get isUnknown =>
      kind == StorageReadKind.indeterminate ||
      kind == StorageReadKind.unavailable;

  @override
  String toString() =>
      kind == StorageReadKind.value ? 'value(${value!.length})' : kind.name;
}

/// Durable string storage with committed outcomes (C1-C8).
abstract class StorageBackend {
  /// Reaches storage if it can. Never throws: unreachable storage is reported
  /// as false, and the app carries on in memory.
  Future<bool> open();

  Future<StorageRead> read(String key);

  Future<StorageOutcome> write(String key, String value);

  Future<StorageOutcome> delete(String key);
}

/// Storage that is never reachable: every operation is not issued.
///
/// Non-web builds use this. They are not product targets, and no native
/// backend has been shown to meet the contract, so they run in memory only and
/// say so, exactly as a browser that refuses storage does.
class UnavailableStorageBackend implements StorageBackend {
  const UnavailableStorageBackend();

  @override
  Future<bool> open() async => false;

  @override
  Future<StorageRead> read(String key) async => StorageRead.unavailable;

  @override
  Future<StorageOutcome> write(String key, String value) async =>
      StorageOutcome.unavailable;

  @override
  Future<StorageOutcome> delete(String key) async => StorageOutcome.unavailable;
}

/// The synchronous-read key/value surface settings are stored through.
///
/// This is DF-039's original storage seam, kept for the `settings` key only.
/// Production backs it with Hive; it is not a second platform contract.
abstract class SettingsBackend {
  bool get isAvailable;

  /// Returns the stored string, or null when the key is absent. Throws when
  /// presence itself cannot be established.
  String? readSetting(String key);

  Future<void> writeSetting(String key, String value);
}
