/// The web [StorageBackend]: document content in IndexedDB, with committed
/// outcomes and bounded waits (§5.3, §5.10).
///
/// The only file in the app that knows IndexedDB exists. It uses the database
/// and object store Hive opens - `markdown_viewer`, store `box` - with its own
/// connection, and stores raw JavaScript strings, which is exactly how Hive
/// stores an unciphered `String` value. So v1.6.1, reading through Hive, and
/// this build read each other's values.
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'storage_backend.dart';

StorageBackend createPlatformContentBackend() => IndexedDbStorageBackend();

/// IndexedDB content storage with a managed connection.
///
/// **Connection lifecycle.** At most one open request is pending at a time. An
/// operation waits for a usable connection for at most [openBound]; past it the
/// operation resolves [StorageOutcome.unavailable] - it was not issued - while
/// the request stays owned here. A request that succeeds late is adopted if its
/// epoch is still current and no connection is held, and closed otherwise, so
/// no connection is ever left unmanaged. `versionchange`, an unexpected `close`
/// and an `InvalidStateError` on creating a transaction invalidate the
/// connection; the next operation opens a new one.
///
/// **Never creates or upgrades the schema.** The database is opened without a
/// version, and an `upgradeneeded` aborts the request, so a database that does
/// not exist is reported unavailable rather than created.
///
/// **Transactions are bounded.** Each resolves on `complete`, `abort` or
/// `error`, within [transactionBound]; past it the outcome is
/// [StorageOutcome.indeterminate], because it may still commit. Outcomes are
/// single-assignment: a late event changes nothing already reported.
class IndexedDbStorageBackend implements StorageBackend {
  IndexedDbStorageBackend({
    this.databaseName = 'markdown_viewer',
    this.storeName = 'box',
    this.openBound = const Duration(seconds: 5),
    this.transactionBound = const Duration(seconds: 20),
  });

  final String databaseName;
  final String storeName;

  /// `T_open`.
  final Duration openBound;

  /// `T_tx`.
  final Duration transactionBound;

  web.IDBDatabase? _db;
  int _epoch = 0;
  _PendingOpen? _pending;

  /// How many `indexedDB.open` requests this backend has issued. Harness
  /// instrumentation: proves requests do not pile up while one is blocked.
  @visibleForTesting
  int openRequestCount = 0;

  /// How many late-opened connections were adopted, and how many closed.
  @visibleForTesting
  int lateAdopted = 0;
  @visibleForTesting
  int lateClosed = 0;

  /// Harness-only hook, called once a request has been issued on a
  /// transaction. The compiled storage harness uses it to abort a transaction
  /// after its request succeeds, or to hold one open. Null in the product.
  @visibleForTesting
  void Function(
    web.IDBTransaction transaction,
    web.IDBObjectStore objectStore,
    web.IDBRequest request,
    String operation,
  )?
  debugAfterRequest;

  /// Harness-only: invalidates the epoch as a stale-connection race would, so
  /// the "late connection from an old epoch is closed" branch can be reached.
  @visibleForTesting
  void debugBumpEpoch() => _epoch++;

  @visibleForTesting
  bool get debugHasConnection => _db != null;

  /// Harness-only: dispatches a `close` event on the held connection, for
  /// engines where the harness cannot make the browser close it. Exercises the
  /// same handler an abnormal closure does; it is handler-level evidence only.
  @visibleForTesting
  void debugDispatchClose() => _db?.dispatchEvent(web.Event('close'));

  @override
  Future<bool> open() async => await _connection() != null;

  /// Presence is read separately from the value, in the same transaction:
  /// IndexedDB `get` returns `undefined` both for a missing key and for a key
  /// that holds `undefined`, and a stored `null` would look absent too. A key
  /// that exists with anything other than a string is stored, unreadable data
  /// (present-undecodable), never absent (§5.3).
  @override
  Future<StorageRead> read(String key) async {
    web.IDBRequest? presence;
    final result = await _transaction('readonly', 'read', (objectStore) {
      presence = objectStore.count(key.toJS);
      return objectStore.get(key.toJS);
    });
    switch (result.outcome) {
      case StorageOutcome.committed:
        final count = presence?.result;
        if (count == null || !count.typeofEquals('number')) {
          return StorageRead.indeterminate;
        }
        if ((count as JSNumber).toDartInt == 0) return StorageRead.absent;
        final value = result.value;
        if (value != null && value.typeofEquals('string')) {
          return StorageRead.value((value as JSString).toDart);
        }
        return StorageRead.undecodable;
      case StorageOutcome.unavailable:
        return StorageRead.unavailable;
      case StorageOutcome.failed:
      case StorageOutcome.indeterminate:
        return StorageRead.indeterminate;
    }
  }

  @override
  Future<StorageOutcome> write(String key, String value) async {
    final result = await _transaction('readwrite', 'write', (objectStore) {
      return objectStore.put(value.toJS, key.toJS);
    });
    return result.outcome;
  }

  /// Issued whatever anything believes about presence: deleting an absent key
  /// succeeds in IndexedDB, so a Retry always performs a real deletion (C3).
  @override
  Future<StorageOutcome> delete(String key) async {
    final result = await _transaction('readwrite', 'delete', (objectStore) {
      return objectStore.delete(key.toJS);
    });
    return result.outcome;
  }

  // --- Transactions ---------------------------------------------------------

  Future<_Result> _transaction(
    String mode,
    String operation,
    web.IDBRequest Function(web.IDBObjectStore objectStore) issue,
  ) async {
    // One retry covers a connection that turns out to be closed only when a
    // transaction is created on it.
    for (var attempt = 0; attempt < 2; attempt++) {
      final db = await _connection();
      if (db == null) return const _Result(StorageOutcome.unavailable);

      final web.IDBTransaction transaction;
      try {
        transaction = db.transaction(storeName.toJS, mode);
      } catch (error) {
        debugPrint('IndexedDB: transaction could not be created: $error');
        if (identical(_db, db)) _invalidate();
        continue;
      }
      return _run(transaction, operation, issue);
    }
    return const _Result(StorageOutcome.unavailable);
  }

  Future<_Result> _run(
    web.IDBTransaction transaction,
    String operation,
    web.IDBRequest Function(web.IDBObjectStore objectStore) issue,
  ) {
    final result = Completer<_Result>();
    void settle(_Result value) {
      if (!result.isCompleted) {
        result.complete(value);
      } else {
        debugPrint('IndexedDB: late $operation outcome ignored: $value');
      }
    }

    final timer = Timer(transactionBound, () {
      settle(const _Result(StorageOutcome.indeterminate));
    });

    final web.IDBRequest request;
    try {
      final objectStore = transaction.objectStore(storeName);
      request = issue(objectStore);
      debugAfterRequest?.call(transaction, objectStore, request, operation);
    } catch (error) {
      // Nothing was issued, so nothing can land. Abort the empty transaction
      // rather than let it commit and be mistaken for a committed change.
      timer.cancel();
      try {
        transaction.abort();
      } catch (_) {}
      debugPrint('IndexedDB: $operation could not be issued: $error');
      return Future.value(const _Result(StorageOutcome.failed));
    }

    transaction.oncomplete = ((web.Event _) {
      timer.cancel();
      settle(_Result(StorageOutcome.committed, request.result));
    }).toJS;
    transaction.onabort = ((web.Event _) {
      timer.cancel();
      settle(const _Result(StorageOutcome.failed));
    }).toJS;
    transaction.onerror = ((web.Event _) {
      timer.cancel();
      settle(const _Result(StorageOutcome.failed));
    }).toJS;
    return result.future;
  }

  // --- Connection management ------------------------------------------------

  Future<web.IDBDatabase?> _connection() {
    final current = _db;
    if (current != null) return Future.value(current);
    final pending = _pending ??= _startOpen();
    final waiter = Completer<web.IDBDatabase?>();
    final timer = Timer(openBound, () {
      if (!waiter.isCompleted) waiter.complete(null);
    });
    pending.done.future.then((db) {
      timer.cancel();
      if (!waiter.isCompleted) waiter.complete(db);
    });
    return waiter.future;
  }

  _PendingOpen _startOpen() {
    final pending = _PendingOpen(_epoch);
    void finish(web.IDBDatabase? db) {
      if (identical(_pending, pending)) _pending = null;
      if (!pending.done.isCompleted) pending.done.complete(db);
    }

    final web.IDBOpenDBRequest request;
    try {
      openRequestCount++;
      request = web.window.indexedDB.open(databaseName);
    } catch (error) {
      debugPrint('IndexedDB: open could not be requested: $error');
      scheduleMicrotask(() => finish(null));
      return pending;
    }

    request.onupgradeneeded = ((web.Event _) {
      // Never create or upgrade the schema; that is Hive's. Aborting makes the
      // open fail, so a missing database is reported, not created.
      try {
        request.transaction?.abort();
      } catch (_) {}
    }).toJS;
    request.onblocked = ((web.Event _) {
      // Still pending. Waiters stay bounded by openBound.
    }).toJS;
    request.onerror = ((web.Event event) {
      event.preventDefault();
      finish(null);
    }).toJS;
    request.onsuccess = ((web.Event _) {
      final db = request.result as web.IDBDatabase;
      final waitedOut = pending.done.isCompleted;
      if (!db.objectStoreNames.contains(storeName)) {
        db.close();
        finish(null);
        return;
      }
      if (pending.epoch == _epoch && _db == null) {
        _adopt(db);
        if (_waitersGone(pending)) lateAdopted++;
        finish(db);
      } else {
        db.close();
        lateClosed++;
        finish(null);
      }
      if (waitedOut) debugPrint('IndexedDB: a late connection was settled.');
    }).toJS;
    return pending;
  }

  /// Whether every operation that waited for [pending] has already given up.
  /// Only used to count late adoptions for the harness.
  bool _waitersGone(_PendingOpen pending) =>
      DateTime.now().difference(pending.started) >= openBound;

  void _adopt(web.IDBDatabase db) {
    _db = db;
    db.onversionchange = ((web.Event _) {
      // Another context wants to upgrade. Get out of its way at once; the next
      // operation opens a new connection, on the new version if it committed.
      if (identical(_db, db)) _invalidate();
      db.close();
    }).toJS;
    db.onclose = ((web.Event _) {
      // Closed abnormally by the browser, for example when its storage was
      // cleared. Transactions in flight abort and resolve failed.
      if (identical(_db, db)) _invalidate();
    }).toJS;
  }

  void _invalidate() {
    _epoch++;
    _db = null;
  }
}

class _PendingOpen {
  _PendingOpen(this.epoch);
  final int epoch;
  final DateTime started = DateTime.now();
  final Completer<web.IDBDatabase?> done = Completer<web.IDBDatabase?>();
}

class _Result {
  const _Result(this.outcome, [this.value]);
  final StorageOutcome outcome;
  final JSAny? value;

  @override
  String toString() => outcome.name;
}
