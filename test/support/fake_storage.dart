import 'dart:async';

import 'package:markdown_viewer/models.dart';
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

/// An in-memory [StorageBackend] that behaves like a healthy browser.
///
/// Lets a widget test drive the real app against real storage semantics -
/// including the DF-039 retention gate - without a Hive box on disk. A real file
/// write started inside the widget-test fake-async zone never completes, which
/// is why these tests previously avoided opening the store at all; an in-memory
/// backend gives them the store's actual behaviour instead of a store that
/// silently does nothing.
class MemoryBackend implements StorageBackend {
  MemoryBackend([Map<String, String>? seed]) {
    if (seed != null) data.addAll(seed);
  }

  final Map<String, String> data = {};

  @override
  bool get isAvailable => true;

  @override
  String? read(String key) => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// A [MemoryBackend] whose reads, writes and deletes can be made to fail, and
/// whose completion can be held open to force a chosen ordering.
///
/// The failure cases are the point of DF-039: the privacy promise rests on what
/// the app says when a delete fails or a write arrives late, and neither can be
/// produced on demand by a healthy browser.
class FakeBackend extends MemoryBackend {
  FakeBackend([super.seed]);

  /// Keys written, in the order they landed. Empty is the proof that a
  /// suppressed write never reached storage at all.
  final List<String> writes = [];

  final Set<String> failReads = {};
  final Set<String> failWrites = {};
  final Set<String> failDeletes = {};
  final Map<String, Completer<void>> _stalls = {};

  /// Holds the next operation on [key] open until the returned completer is
  /// completed, so a test can place a second operation behind a first
  /// deterministically instead of relying on timing.
  Completer<void> stall(String key) => _stalls[key] = Completer<void>();

  @override
  String? read(String key) {
    if (failReads.contains(key)) {
      throw StateError('injected read failure for "$key"');
    }
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    await _awaitStall(key);
    if (failWrites.contains(key)) {
      throw StateError('injected write failure for "$key"');
    }
    writes.add(key);
    await super.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    await _awaitStall(key);
    if (failDeletes.contains(key)) {
      throw StateError('injected delete failure for "$key"');
    }
    await super.delete(key);
  }

  Future<void> _awaitStall(String key) async {
    final stall = _stalls.remove(key);
    if (stall != null) await stall.future;
  }
}

/// Stands in for a browser that refused to open storage at all.
class UnavailableBackend implements StorageBackend {
  @override
  bool get isAvailable => false;

  @override
  String? read(String key) => throw StateError('no storage');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('no storage');

  @override
  Future<void> delete(String key) async => throw StateError('no storage');
}
