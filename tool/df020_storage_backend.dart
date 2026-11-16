// ignore_for_file: avoid_web_libraries_in_flutter, invalid_use_of_visible_for_testing_member

// DF-020 V-22: the production web storage backend on real engines.
//
// Verification support, not product code. Built with
// `flutter build web --release -t tool/df020_storage_backend.dart` and driven
// by test/browser/df020_storage_backend.mjs. The page exposes
// `window.df020(step, argsJson)`, which returns a promise of a JSON string, so
// the runner can run the compiled contract suite and the cases in one page and
// orchestrate the connection-lifecycle scenarios across several.
//
// Everything storage-facing is production code: `IndexedDbStorageBackend`,
// `Store`, `HiveSettingsBackend`, and Hive opened exactly as the app opens it.
// The only harness-only mechanism is the backend's `debugAfterRequest` hook,
// used to abort a transaction after its request succeeds or to hold one open.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:flutter/rendering.dart';
import 'package:markdown_viewer/main.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/retained_format.dart';
import 'package:markdown_viewer/retention.dart';
import 'package:markdown_viewer/storage/indexed_db_storage_backend_web.dart';
import 'package:markdown_viewer/store.dart';
import 'package:web/web.dart' as web;

import '../test/support/storage_backend_contract.dart';

@JS('df020')
external set _df020(JSFunction value);

Box<String>? _box;
IndexedDbStorageBackend? _backend;
Store? _store;
_Source? _source;
bool _holding = false;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _Status('DF-020 storage harness'));
  _df020 = ((JSString step, JSString args) {
    return _dispatch(
      step.toDart,
      jsonDecode(args.toDart) as Map<String, dynamic>,
    ).then((result) => jsonEncode(result).toJS).toJS;
  }).toJS;
  web.document.body?.dataset['df020Ready'] = 'true';
}

Future<Map<String, Object?>> _dispatch(
  String step,
  Map<String, dynamic> args,
) async {
  final watch = Stopwatch()..start();
  try {
    final result = await _step(step, args);
    return {'ok': true, 'ms': watch.elapsedMilliseconds, ...result};
  } catch (error, stack) {
    return {
      'ok': false,
      'ms': watch.elapsedMilliseconds,
      'error': '$error',
      'stack': '$stack'.split('\n').take(6).join('\n'),
    };
  }
}

Future<Map<String, Object?>> _step(String step, Map<String, dynamic> args) {
  return switch (step) {
    'openHive' => _openHive(),
    'closeHive' => _closeHive(),
    'hiveGet' => Future.value({'value': _box?.get(args['key'] as String)}),
    'contract' => _contract(),
    'cases' => _cases(),
    'lcSetup' => _lcSetup(),
    'lcOp' => _lcOp(args['op'] as String, args['key'] as String? ?? 'lc-key'),
    'lcRemoval' => _lcRemoval(),
    'lcStoreOp' => _storeTimed(
      () async => {
        'outcome': (await _store!.requestDocumentsWrite()).outcome.name,
      },
    ),
    'lcWholeStore' => _storeTimed(
      () async => {'outcome': (await _store!.removeRetainedContent()).name},
    ),
    'lcSaveSettings' => _storeTimed(
      () async => {
        'outcome': (await _store!.saveSettings(
          Settings(keepForNextTime: args['keep'] as bool? ?? false),
        )).name,
      },
    ),
    'gSeed' => _gSeed(),
    'classify' => _classify(args['key'] as String),
    'homeText' => Future.value({'text': _semanticsText()}),
    'lcDisable' => _lcDisable(),
    'lcHoldNextWrite' => _lcHoldNextWrite(),
    'lcRelease' => Future(() {
      _holding = false;
      return <String, Object?>{};
    }),
    'lcStats' => Future.value(_stats()),
    'lcBumpEpoch' => Future(() {
      _backend!.debugBumpEpoch();
      return <String, Object?>{};
    }),
    'lcDispatchClose' => Future(() {
      _backend!.debugDispatchClose();
      return <String, Object?>{};
    }),
    'lcFreshStore' => _lcFreshStore(),
    'startupInit' => _startupInit(),
    _ => throw ArgumentError('unknown step $step'),
  };
}

/// Runs Store operations and reports their service time - summed over the
/// queue operations they made, each from the moment it started executing -
/// and their queue wait separately (§5.11), plus how many content deletes the
/// backend actually issued.
Future<Map<String, Object?>> _storeTimed(
  Future<Map<String, Object?>> Function() run,
) async {
  final store = _store!;
  final backend = _backend;
  var deletes = 0;
  final previousHook = backend?.debugAfterRequest;
  if (backend != null && previousHook == null) {
    backend.debugAfterRequest = (tx, objectStore, request, op) {
      if (op == 'delete') deletes++;
    };
  }
  store.debugTimings.clear();
  store.debugRecordTimings = true;
  final watch = Stopwatch()..start();
  try {
    final result = await run();
    return {
      ...result,
      'serviceMs': store.debugTimings.fold<int>(
        0,
        (sum, t) => sum + t.service.inMilliseconds,
      ),
      'queueWaitMs': store.debugTimings.fold<int>(
        0,
        (sum, t) => sum + t.wait.inMilliseconds,
      ),
      'queueOperations': store.debugTimings.length,
      'endToEndMs': watch.elapsedMilliseconds,
      'deletesIssued': deletes,
      'effectivePolicy': store.effectivePolicy.name,
    };
  } finally {
    store.debugRecordTimings = false;
    if (backend != null && previousHook == null) {
      backend.debugAfterRequest = null;
    }
  }
}

Future<Map<String, Object?>> _timed(
  Future<Map<String, Object?>> Function() run,
) async {
  final watch = Stopwatch()..start();
  final result = await run();
  return {...result, 'serviceMs': watch.elapsedMilliseconds};
}

// --- Hive, opened exactly as the app opens it ---------------------------------

Future<Map<String, Object?>> _openHive() async {
  final watch = Stopwatch()..start();
  await Hive.initFlutter();
  _box = await Hive.openBox<String>(Store.boxName);
  return {'openMs': watch.elapsedMilliseconds};
}

Future<Map<String, Object?>> _closeHive() async {
  await _box?.close();
  _box = null;
  return {};
}

// --- The compiled contract suite ------------------------------------------------

/// One-shot hook: aborts the next [operation] after its request succeeds.
void _abortNext(IndexedDbStorageBackend backend, String operation) {
  backend.debugAfterRequest = (tx, store, request, op) {
    if (op != operation) return;
    backend.debugAfterRequest = null;
    request.onsuccess = ((web.Event _) => tx.abort()).toJS;
  };
}

/// One-shot hook: keeps the next write's transaction busy past [hold], then
/// lets it commit - a write that times out indeterminate and commits late.
void _holdNext(IndexedDbStorageBackend backend, Duration hold) {
  backend.debugAfterRequest = (tx, store, request, op) {
    if (op != 'write') return;
    backend.debugAfterRequest = null;
    final until = DateTime.now().add(hold);
    void again() {
      if (DateTime.now().isAfter(until)) return;
      final keepAlive = store.get('df020-keepalive'.toJS);
      keepAlive.onsuccess = ((web.Event _) => again()).toJS;
    }

    again();
  };
}

Future<Map<String, Object?>> _contract() async {
  await _openHive();
  // A short transaction bound so C8's held write times out in a few seconds;
  // every other bound is production's.
  final backend = IndexedDbStorageBackend(
    transactionBound: const Duration(seconds: 3),
  );
  final checks = storageContractChecks(
    backend,
    ContractHooks(
      reopen: () async => IndexedDbStorageBackend(),
      failNextWrite: (_) => _abortNext(backend, 'write'),
      failNextDelete: (_) => _abortNext(backend, 'delete'),
      nextWriteIndeterminateButApplied: (_) =>
          _holdNext(backend, const Duration(milliseconds: 3600)),
      unavailable: () =>
          IndexedDbStorageBackend(databaseName: 'df020-never-created'),
    ),
  );
  final results = <Map<String, Object?>>[];
  for (final check in checks) {
    final watch = Stopwatch()..start();
    try {
      await check.run();
      results.add({
        'id': check.id,
        'name': check.name,
        'pass': true,
        'ms': watch.elapsedMilliseconds,
      });
    } catch (error) {
      results.add({
        'id': check.id,
        'name': check.name,
        'pass': false,
        'error': '$error',
      });
    }
  }
  final neverCreated = await _databaseNames();
  return {
    'checks': results,
    'passed': results.every((r) => r['pass'] == true),
    'unavailableDatabaseNotCreated': !neverCreated.contains(
      'df020-never-created',
    ),
  };
}

Future<List<String>> _databaseNames() async {
  final factory = web.window.indexedDB;
  final list = await factory.databases().toDart;
  return [for (final info in list.toDart) info.name];
}

// --- Cases (a)-(e) and (g), and the timing margins ------------------------------

Future<Map<String, Object?>> _cases() async {
  if (_box == null) await _openHive();
  final backend = IndexedDbStorageBackend();
  final out = <String, Object?>{};

  // (a) A shim-aborted write fails, and the previous value stays.
  await backend.write('case-a', 'before');
  _abortNext(backend, 'write');
  final aOutcome = await backend.write('case-a', 'after');
  final aRead = await backend.read('case-a');
  out['a'] = {
    'outcome': aOutcome.name,
    'read': aRead.value,
    'pass': aOutcome == StorageOutcome.failed && aRead.value == 'before',
  };

  // (b) A shim-aborted delete fails; the Retry really deletes.
  await backend.write('case-b', 'present');
  var deletes = 0;
  backend.debugAfterRequest = (tx, store, request, op) {
    if (op == 'delete') deletes++;
  };
  _abortNextKeepingCount(backend, () => deletes++);
  final bFirst = await backend.delete('case-b');
  final bStill = await backend.read('case-b');
  backend.debugAfterRequest = (tx, store, request, op) {
    if (op == 'delete') deletes++;
  };
  final bRetry = await backend.delete('case-b');
  backend.debugAfterRequest = null;
  final bAfter = await backend.read('case-b');
  out['b'] = {
    'first': bFirst.name,
    'stillPresent': bStill.value,
    'retry': bRetry.name,
    'after': bAfter.kind.name,
    'deletesIssued': deletes,
    'pass':
        bFirst == StorageOutcome.failed &&
        bStill.value == 'present' &&
        bRetry == StorageOutcome.committed &&
        bAfter.kind == StorageReadKind.absent &&
        deletes == 2,
  };

  // (c) Hive divergence: Hive's in-memory keystore keeps a value the backend
  // deleted, but committed storage - read by the backend and by a freshly
  // opened Hive box, as a v1.6.1 start would - does not.
  await _box!.put(Store.documentKey, 'seeded through Hive');
  final cDelete = await backend.delete(Store.documentKey);
  final cHiveCache = _box!.get(Store.documentKey);
  final cBackend = await backend.read(Store.documentKey);
  await _closeHive();
  await _openHive();
  final cFresh = _box!.get(Store.documentKey);
  out['c'] = {
    'delete': cDelete.name,
    'hiveKeystoreStillHolds': cHiveCache,
    'backendRead': cBackend.kind.name,
    'freshHiveBox': cFresh,
    'pass':
        cDelete == StorageOutcome.committed &&
        cHiveCache == 'seeded through Hive' &&
        cBackend.kind == StorageReadKind.absent &&
        cFresh == null,
  };

  // (d) Compatibility in both directions.
  await _box!.put('case-d-hive', 'written by Hive');
  final dFromHive = await backend.read('case-d-hive');
  await backend.write('case-d-backend', 'written by the backend');
  await _closeHive();
  await _openHive();
  final dFromBackend = _box!.get('case-d-backend');
  out['d'] = {
    'backendReadsHive': dFromHive.value,
    'hiveReadsBackend': dFromBackend,
    'pass':
        dFromHive.value == 'written by Hive' &&
        dFromBackend == 'written by the backend',
  };

  // (e) A 5 MiB value, with its latency for the margin record.
  final large = List.filled(5 * 1024 * 1024 ~/ 16, '0123456789abcdef').join();
  final eWatch = Stopwatch()..start();
  final eWrite = await backend.write('case-e', large);
  final eWriteMs = eWatch.elapsedMilliseconds;
  eWatch.reset();
  final eRead = await backend.read('case-e');
  final eReadMs = eWatch.elapsedMilliseconds;
  await backend.delete('case-e');
  out['e'] = {
    'write': eWrite.name,
    'writeMs': eWriteMs,
    'readMs': eReadMs,
    'pass': eWrite == StorageOutcome.committed && eRead.value == large,
  };

  // (g) The E-1 path: the removal transaction's second write is aborted.
  final store = Store();
  await store.init(backend: backend, settings: HiveSettingsBackend(_box!));
  store.applyResolvedPolicy(RetentionPolicy.on);
  final source = _Source([_doc('a'), _doc('b')]);
  store.registerRetainedSource(source.snapshot);
  await store.requestDocumentsWrite();
  await store.requestReadingStateWrite();
  var second = 0;
  backend.debugAfterRequest = (tx, s, request, op) {
    if (op != 'write') return;
    if (++second == 2) {
      backend.debugAfterRequest = null;
      request.onsuccess = ((web.Event _) => tx.abort()).toJS;
    }
  };
  var verifiedCalled = false;
  final gOutcome = await store.removeDocuments(
    {'b'},
    successorActiveId: 'a',
    onVerified: () => verifiedCalled = true,
  );
  backend.debugAfterRequest = null;
  final restoreDocuments = await store.requestDocumentsWrite();
  final restoreReading = await store.requestReadingStateWrite();
  final reload = Store();
  await reload.init(
    backend: IndexedDbStorageBackend(),
    settings: HiveSettingsBackend(_box!),
  );
  await reload.refreshContentPresence();
  final reloaded = reload.loadRetained();
  out['g'] = {
    'outcome': gOutcome.name,
    'onVerifiedCalled': verifiedCalled,
    'restoreConfirmed': restoreDocuments.confirmed && restoreReading.confirmed,
    'reloadedIds': reloaded?.documents.map((d) => d.id).toList(),
    'pass':
        gOutcome == RemovalOutcome.notVerified &&
        !verifiedCalled &&
        restoreDocuments.confirmed &&
        restoreReading.confirmed &&
        (reloaded?.documents.map((d) => d.id).join(',') ?? '') == 'a,b',
  };
  await backend.delete(Store.documentKey);
  await backend.delete(Store.positionKey);

  // Timing margins: open, a small commit, a settings write, a startup open.
  final mWatch = Stopwatch()..start();
  final fresh = IndexedDbStorageBackend();
  await fresh.open();
  final openMs = mWatch.elapsedMilliseconds;
  mWatch.reset();
  await fresh.write('case-margin', 'small');
  final commitMs = mWatch.elapsedMilliseconds;
  mWatch.reset();
  final settings = await store.saveSettings(const Settings());
  final settingsMs = mWatch.elapsedMilliseconds;
  await _closeHive();
  mWatch.reset();
  await _openHive();
  final startupOpenMs = mWatch.elapsedMilliseconds;
  out['margins'] = {
    'openMs': openMs,
    'commitMs': commitMs,
    'largeCommitMs': eWriteMs,
    'settingsWriteMs': settingsMs,
    'settingsOutcome': settings.name,
    'startupOpenMs': startupOpenMs,
    'bounds': {
      'T_open': 5000,
      'T_tx': 20000,
      'T_set': 20000,
      'T_startup': 20000,
    },
  };
  out['passed'] = [
    'a',
    'b',
    'c',
    'd',
    'e',
    'g',
  ].every((k) => (out[k] as Map)['pass'] == true);
  return out;
}

void _abortNextKeepingCount(
  IndexedDbStorageBackend backend,
  void Function() count,
) {
  backend.debugAfterRequest = (tx, store, request, op) {
    if (op != 'delete') return;
    count();
    backend.debugAfterRequest = null;
    request.onsuccess = ((web.Event _) => tx.abort()).toJS;
  };
}

// --- Lifecycle scenario steps (orchestrated by the runner) ---------------------

Future<Map<String, Object?>> _lcSetup() async {
  if (_box == null) await _openHive();
  _backend = IndexedDbStorageBackend();
  _store = Store();
  await _store!.init(backend: _backend, settings: HiveSettingsBackend(_box!));
  _store!.applyResolvedPolicy(RetentionPolicy.on);
  _source = _Source([_doc('a'), _doc('b')]);
  _store!.registerRetainedSource(_source!.snapshot);
  final documents = await _store!.requestDocumentsWrite();
  final reading = await _store!.requestReadingStateWrite();
  return {
    'documents': documents.confirmed,
    'reading': reading.confirmed,
    ..._stats(),
  };
}

Future<Map<String, Object?>> _lcOp(String op, String key) => _timed(() async {
  final backend = _backend!;
  switch (op) {
    case 'write':
      return {
        'outcome': (await backend.write(
          key,
          'v${DateTime.now().microsecondsSinceEpoch}',
        )).name,
      };
    case 'delete':
      return {'outcome': (await backend.delete(key)).name};
    default:
      final read = await backend.read(key);
      return {'outcome': read.kind.name, 'value': read.value};
  }
});

/// A per-document removal and its restore, as the app makes them (§5.5): the
/// transaction, then the documents and reading-state writes.
Future<Map<String, Object?>> _lcRemoval() => _storeTimed(() async {
  var verified = false;
  final outcome = await _store!.removeDocuments(
    {'b'},
    successorActiveId: 'a',
    onVerified: () => verified = true,
  );
  final restoreDocuments = _store!.requestDocumentsWrite();
  final restoreReading = _store!.requestReadingStateWrite();
  final documents = await restoreDocuments;
  final reading = await restoreReading;
  return {
    'outcome': outcome.name,
    'onVerifiedCalled': verified,
    'restoreDocuments': documents.outcome.name,
    'restoreReading': reading.outcome.name,
    'restoreConfirmed': documents.confirmed && reading.confirmed,
  };
});

Future<Map<String, Object?>> _lcDisable() => _storeTimed(() async {
  final result = await RetentionController(
    _store!,
  ).disable(current: const Settings());
  return {
    'preference': result.preferenceOutcome.name,
    'cleanup': result.cleanup?.name,
    'removedAndWillNotReturn': result.removedAndWillNotReturn,
    'contentConfirmedAbsent': result.contentConfirmedAbsent,
  };
});

/// Holds the next content write's transaction open, issuing requests on it,
/// until `lcRelease`.
Future<Map<String, Object?>> _lcHoldNextWrite() async {
  _holding = true;
  _backend!.debugAfterRequest = (tx, store, request, op) {
    if (op != 'write') return;
    _backend!.debugAfterRequest = null;
    void again() {
      if (!_holding) return;
      final keepAlive = store.get('df020-keepalive'.toJS);
      keepAlive.onsuccess = ((web.Event _) => again()).toJS;
    }

    again();
  };
  return {};
}

Future<Map<String, Object?>> _lcFreshStore() async {
  // A new page lifetime's view: a new backend connection and fresh reads.
  final backend = IndexedDbStorageBackend();
  final store = Store();
  await store.init(backend: backend, settings: HiveSettingsBackend(_box!));
  await store.refreshContentPresence();
  final settings = store.loadSettingsResult();
  return {
    'available': store.isAvailable,
    'content': store.rawContentPresence().name,
    'keepForNextTime': settings.settings.keepForNextTime,
    'settingsOutcome': settings.outcome.name,
  };
}

/// The app's startup exactly as `main()` makes it - the production `store`,
/// `Store.init()` with Hive bounded by `T_startup`, `resolveStartup()` - and
/// then the production app, built from that result, with semantics on so the
/// runner can read the Home it renders.
Future<Map<String, Object?>> _startupInit() async {
  final watch = Stopwatch()..start();
  await store.init();
  final initMs = watch.elapsedMilliseconds;
  _store = store;
  final startup = await retention.resolveStartup();
  SemanticsBinding.instance.ensureSemantics();
  runApp(
    MarkdownViewerApp(
      initialSettings: startup.settingsLoad.settings,
      initialDocument: startup.effectivePolicy == RetentionPolicy.on
          ? store.loadDocument()
          : null,
      startup: startup,
    ),
  );
  for (var i = 0; i < 4; i++) {
    await WidgetsBinding.instance.endOfFrame;
  }
  await Future<void>.delayed(const Duration(milliseconds: 600));
  return {
    'homeText': _semanticsText(),
    'retainedIds': store.loadRetained()?.documents.map((d) => d.id).toList(),
    'keepForNextTime': startup.settingsLoad.settings.keepForNextTime,
    'initMs': initMs,
    'available': store.isAvailable,
    'presence': store.rawContentPresence().name,
    'retained': store.loadRetained() != null,
    'effectivePolicy': startup.effectivePolicy.name,
    'lateBoxesClosed': Store.lateBoxesClosed,
  };
}

/// How the production backend classifies whatever is stored under [key].
Future<Map<String, Object?>> _classify(String key) async {
  final read = await IndexedDbStorageBackend().read(key);
  return {'kind': read.kind.name};
}

/// Seeds identifiable ON data the way a v1.7.0 page lifetime stores it: the
/// preference through Hive, and a one-document set with a place through the
/// production backend.
Future<Map<String, Object?>> _gSeed() async {
  await _box!.put(
    Store.settingsKey,
    jsonEncode(const Settings(keepForNextTime: true).toJson()),
  );
  final backend = IndexedDbStorageBackend();
  final document = MarkdownDocument.fromSource(
    '# G seeded title\n\nBody.',
    id: 'g-doc',
    sourceName: 'g-seeded.md',
  );
  final documents = await backend.write(
    Store.documentKey,
    encodeDocumentSet([document]),
  );
  final reading = await backend.write(
    Store.positionKey,
    encodeReadingState('g-doc', {
      'g-doc': ReadingPosition(
        documentId: 'g-doc',
        blockIndex: 1,
        fraction: 0,
        savedAt: DateTime.utc(2026, 11, 16),
      ),
    }),
  );
  return {'documents': documents.name, 'reading': reading.name};
}

/// Everything the semantics tree announces: each node's label, description,
/// described-by text and text content (the df039 probe's haystack).
String _semanticsText() => [
  for (final node in web.document.querySelectorAll('flt-semantics').toList())
    [
      node.getAttribute('aria-label'),
      node.getAttribute('aria-description'),
      for (final id in (node.getAttribute('aria-describedby') ?? '').split(' '))
        if (id.isNotEmpty) web.document.getElementById(id)?.textContent,
      node.textContent,
    ].whereType<String>().where((t) => t.isNotEmpty).join(' | '),
].join('\n');

extension on web.NodeList {
  List<web.Element> toList() => [
    for (var i = 0; i < length; i++) item(i) as web.Element,
  ];
}

Map<String, Object?> _stats() => {
  'openRequests': _backend?.openRequestCount,
  'lateAdopted': _backend?.lateAdopted,
  'lateClosed': _backend?.lateClosed,
  'hasConnection': _backend?.debugHasConnection,
  'lateBoxesClosed': Store.lateBoxesClosed,
};

// --- Support ---------------------------------------------------------------------

MarkdownDocument _doc(String id) => MarkdownDocument.fromSource(
  '# $id\n\nBody of $id.',
  id: id,
  sourceName: '$id.md',
);

class _Source {
  _Source(this.documents);
  List<MarkdownDocument> documents;

  RetainedSnapshot snapshot() => RetainedSnapshot(
    documents: documents,
    activeId: documents.isEmpty ? null : documents.first.id,
    positions: const {},
    documentsRevision: 1,
    readingStateRevision: 1,
  );
}

// Keeps the encoder import honest: the harness and the product share one
// format.
final String formatVersion = '$kRetainedFormatVersion';

class _Status extends StatelessWidget {
  const _Status(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(body: Center(child: Text(message))),
  );
}
