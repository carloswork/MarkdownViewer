// DF-020 CP2: persistence (plan §5), on the contract-based fake backend.
//
// V-3..V-8, V-8r, V-8a, V-8c, V-8s, V-9a, V-9m, V-19, V-20 (store part) and
// V-23. The store is driven the way the app drives it: a DocumentSession is the
// retained-state source, writes are requested after session changes, and close
// and replacement go through removeDocuments with the session change applied in
// onVerified.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/document_session.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/retained_format.dart';
import 'package:markdown_viewer/retention.dart';
import 'package:markdown_viewer/store.dart';

import 'support/fake_storage.dart';
import 'support/storage_backend_contract.dart';

MarkdownDocument doc(String id, {String? name, String? source}) =>
    MarkdownDocument.fromSource(
      source ?? '# $id\n\nBody of $id.',
      id: id,
      sourceName: name ?? '$id.md',
    );

MarkdownDocument pasted(String id) =>
    MarkdownDocument.fromSource('# Pasted $id', id: id);

ReadingPosition pos(String id, int block) => ReadingPosition(
  documentId: id,
  blockIndex: block,
  fraction: 0.5,
  savedAt: DateTime.utc(2026, 11, 16),
);

/// The app's side of the store: a session, registered as the retained source.
class Host {
  Host(this.store, [DocumentSession? initial])
    : session = initial ?? DocumentSession.empty {
    store.registerRetainedSource(snapshot);
  }

  final Store store;
  DocumentSession session;

  RetainedSnapshot snapshot() => RetainedSnapshot(
    documents: session.documents,
    activeId: session.activeId,
    positions: session.positions,
    documentsRevision: session.documentsRevision,
    readingStateRevision: session.readingStateRevision,
  );

  Future<(WriteReceipt, WriteReceipt)> writeBoth() async {
    final documents = store.requestDocumentsWrite();
    final reading = store.requestReadingStateWrite();
    return (await documents, await reading);
  }

  Future<void> load(List<MarkdownDocument> adds) async {
    session = session.commitBatch(adds: adds, activeId: adds.first.id);
    await writeBoth();
  }

  /// Close under ON, as the app does it (§5.5): verified first, then restore.
  Future<RemovalOutcome> close(String id) async {
    final next = session.close(id);
    final outcome = await store.removeDocuments(
      {id},
      successorActiveId: next.successor,
      onVerified: () => session = next.session,
    );
    if (outcome == RemovalOutcome.verified) {
      await writeBoth();
    } else {
      await writeBoth(); // the restore write
    }
    return outcome;
  }

  /// Replacement under ON (E-1): verify removal of the replaced IDs, commit
  /// inside the operation, then write; restore on failure.
  Future<RemovalOutcome> replace(
    Map<String, MarkdownDocument> replacements, {
    List<MarkdownDocument> adds = const [],
  }) async {
    final active = [...replacements.values, ...adds].first.id;
    final outcome = await store.removeDocuments(
      replacements.keys.toSet(),
      replacing: true,
      onVerified: () => session = session.commitBatch(
        replacements: replacements,
        adds: adds,
        activeId: active,
      ),
    );
    await writeBoth();
    return outcome;
  }
}

void main() {
  late FakeBackend backend;
  late Store store;
  late RetentionController retention;
  late Host host;

  Future<void> open({Map<String, String>? seed, bool on = true}) async {
    backend = FakeBackend(seed);
    store = Store();
    await store.init(backend: backend);
    await store.refreshContentPresence();
    retention = RetentionController(store);
    host = Host(store);
    if (on) store.applyResolvedPolicy(RetentionPolicy.on);
  }

  /// A simulated reload: a new store over the same committed map.
  Future<RetainedState?> reload() async {
    final later = Store();
    await later.init(backend: backend);
    await later.refreshContentPresence();
    return later.loadRetained();
  }

  Set<String> storedIds() {
    final raw = backend.data[Store.documentKey];
    if (raw == null) return {};
    // An undecodable value holds no document ID that could be restored.
    final decoded = decodeDocumentKey(raw);
    return {for (final d in decoded.documents) d.id};
  }

  Set<String> storedPositionIds() {
    final raw = backend.data[Store.positionKey];
    if (raw == null) return {};
    return decodeReadingKey(raw).positions.keys.toSet();
  }

  /// DR-3: committed document IDs are a subset of the open IDs.
  void expectWithinSession() {
    expect(storedIds().difference(host.session.ids), isEmpty, reason: 'DR-3');
    expect(storedPositionIds().difference(host.session.ids), isEmpty);
  }

  Future<void> openThree() async {
    await open();
    await host.load([doc('a'), doc('b'), doc('c')]);
    host.session = host.session
        .recordPosition(pos('a', 1))
        .recordPosition(pos('b', 2))
        .recordPosition(pos('c', 3));
    await store.requestReadingStateWrite();
    expect(storedIds(), {'a', 'b', 'c'});
    backend.writes.clear();
  }

  bool current() =>
      store.confirmedDocumentsRevision == host.session.documentsRevision &&
      store.confirmedReadingStateRevision == host.session.readingStateRevision;

  // --- V-3 -------------------------------------------------------------------

  group('V-3: nothing is written under OFF', () {
    test(
      'load, switch, edit, replace, close and paste write nothing',
      () async {
        await open(on: false);
        host.session = host.session.commitBatch(
          adds: [doc('a'), doc('b')],
          activeId: 'a',
        );
        var (d, r) = await host.writeBoth();
        expect(d.outcome, WriteOutcome.suppressedByPolicy);
        expect(r.outcome, WriteOutcome.suppressedByPolicy);
        host.session = host.session.activate('b');
        await store.requestReadingStateWrite();
        host.session = host.session.updateDocument(
          host.session.byId('a')!.copyWith(source: 'edited'),
        );
        await store.requestDocumentsWrite();
        host.session = host.session.commitBatch(
          adds: [pasted('p')],
          activeId: 'p',
        );
        (d, r) = await host.writeBoth();
        expect(
          await store.removeDocuments({'a'}, onVerified: () => fail('no')),
          RemovalOutcome.notVerified,
        );
        expect(backend.writes, isEmpty);
        expect(backend.data.containsKey(Store.documentKey), isFalse);
        expect(backend.data.containsKey(Store.positionKey), isFalse);
      },
    );
  });

  // --- V-4 -------------------------------------------------------------------

  group('V-4: whole-store removal with v2 data', () {
    test(
      'ON to OFF verifies both keys absent and supersedes queued writes',
      () async {
        await openThree();
        final held = backend.stall(Store.documentKey);
        host.session = host.session.updateDocument(
          host.session.byId('a')!.copyWith(source: 'queued'),
        );
        final queued = store.requestDocumentsWrite();
        final queuedAfter = store.requestReadingStateWrite();
        final result = retention.disable(current: const Settings());
        held.complete();
        final outcome = await result;
        expect(outcome.contentConfirmedAbsent, isTrue);
        expect((await queuedAfter).outcome, WriteOutcome.superseded);
        await queued;
        expect(backend.data.containsKey(Store.documentKey), isFalse);
        expect(backend.data.containsKey(Store.positionKey), isFalse);
      },
    );

    test(
      'Remove saved documents verifies absence and keeps the preference ON',
      () async {
        await openThree();
        backend.data[Store.settingsKey] = jsonEncode(
          const Settings(keepForNextTime: true).toJson(),
        );
        final outcome = await retention.removeSavedDocument(
          documentIds: host.session.ids,
        );
        expect(outcome, CleanupOutcome.confirmedAbsent);
        expect(store.effectivePolicy, RetentionPolicy.on);
        expect(store.loadSettings().keepForNextTime, isTrue);
        expect(storedIds(), isEmpty);
        // The suppressed documents are never written again, even if a stale
        // session still holds them.
        final receipt = await store.requestDocumentsWrite();
        expect(receipt.exact, isFalse);
        expect(storedIds(), isEmpty);
      },
    );

    for (final failure in [
      InjectedOutcome.failed,
      InjectedOutcome.indeterminate,
    ]) {
      test('a Retry after a ${failure.name} delete issues a real delete and '
          'confirms absence once storage recovers', () async {
        await openThree();
        backend.injectDeletes[Store.documentKey] = [failure];
        final first = await retention.removeSavedDocument(
          documentIds: host.session.ids,
        );
        expect(first.isConfirmedAbsent, isFalse);
        final before = backend.deleteCalls[Store.documentKey]!;
        final retry = await retention.removeSavedDocument(
          documentIds: host.session.ids,
        );
        expect(backend.deleteCalls[Store.documentKey], before + 1);
        expect(retry, CleanupOutcome.confirmedAbsent);
      });
    }

    test('a failed Remove leaves the documents open', () async {
      await openThree();
      backend.failDeletes.add(Store.documentKey);
      final outcome = await retention.removeSavedDocument(
        documentIds: host.session.ids,
      );
      expect(outcome.isConfirmedAbsent, isFalse);
      expect(host.session.ids, {'a', 'b', 'c'});
    });
  });

  // --- V-5 / V-6 -------------------------------------------------------------

  group('V-5: no reappearance after verified removal', () {
    test('a later report or request never writes a closed ID', () async {
      await openThree();
      expect(await host.close('b'), RemovalOutcome.verified);
      // The closed reader's disposal report arrives late, and is ignored.
      final late = host.session.recordPosition(pos('b', 99));
      expect(identical(late, host.session), isTrue);
      await host.writeBoth();
      expect(storedIds(), {'a', 'c'});
      expect(storedPositionIds(), {'a', 'c'});
    });

    test('a write queued before the transaction lands first, then the '
        'transaction removes the ID', () async {
      await openThree();
      final held = backend.stall(Store.positionKey);
      host.session = host.session.recordPosition(pos('b', 7));
      final queued = store.requestReadingStateWrite();
      final next = host.session.close('b');
      final removal = store.removeDocuments(
        {'b'},
        successorActiveId: next.successor,
        onVerified: () => host.session = next.session,
      );
      held.complete();
      expect((await queued).confirmed, isTrue, reason: 'unfiltered, truthful');
      expect(await removal, RemovalOutcome.verified);
      expect(storedPositionIds(), isNot(contains('b')));
    });

    test('a write requested during the transaction sees the post-commit '
        'session', () async {
      await openThree();
      final held = backend.stall(Store.positionKey);
      final next = host.session.close('b');
      final removal = store.removeDocuments(
        {'b'},
        successorActiveId: next.successor,
        onVerified: () => host.session = next.session,
      );
      await Future<void>.delayed(Duration.zero);
      final during = store.requestDocumentsWrite();
      held.complete();
      expect(await removal, RemovalOutcome.verified);
      expect((await during).confirmed, isTrue);
      expect(storedIds(), {'a', 'c'});
    });
  });

  group('V-6: per-document removal keeps other documents\' newest state', () {
    test(
      'close B while A\'s position write is stalled: A lands, B is absent',
      () async {
        await openThree();
        final held = backend.stall(Store.positionKey);
        host.session = host.session.recordPosition(pos('a', 42));
        final aWrite = store.requestReadingStateWrite();
        final closing = host.close('b');
        held.complete();
        await aWrite;
        expect(await closing, RemovalOutcome.verified);
        final restored = await reload();
        expect(restored!.positions['a']!.blockIndex, 42);
        expect(restored.documents.map((d) => d.id), ['a', 'c']);
      },
    );
  });

  // --- V-7 -------------------------------------------------------------------

  group('V-7: saved-status matrix', () {
    test(
      'a position-only change leaves the documents confirmation current',
      () async {
        await openThree();
        final documents = store.confirmedDocumentsRevision;
        host.session = host.session.recordPosition(pos('a', 9));
        expect(current(), isFalse, reason: 'reading state is behind');
        await store.requestReadingStateWrite();
        expect(store.confirmedDocumentsRevision, documents);
        expect(current(), isTrue);
      },
    );

    test('a document-only change leaves the reading-state confirmation '
        'current', () async {
      await openThree();
      final reading = store.confirmedReadingStateRevision;
      host.session = host.session.updateDocument(
        host.session.byId('b')!.copyWith(source: 'changed'),
      );
      await store.requestDocumentsWrite();
      expect(store.confirmedReadingStateRevision, reading);
      expect(current(), isTrue);
    });

    test('three requests during one waiting write coalesce into one receipt '
        'that covers all three', () async {
      await openThree();
      final held = backend.stall(Store.documentKey);
      host.session = host.session.updateDocument(
        host.session.byId('a')!.copyWith(source: 'x'),
      );
      final executing = store.requestDocumentsWrite();
      await Future<void>.delayed(Duration.zero);
      final requests = <Future<WriteReceipt>>[];
      for (var i = 1; i <= 3; i++) {
        host.session = host.session.recordPosition(pos('a', 10 + i));
        requests.add(store.requestReadingStateWrite());
      }
      expect(identical(requests[0], requests[1]), isTrue);
      expect(identical(requests[1], requests[2]), isTrue);
      held.complete();
      await executing;
      final receipt = await requests.last;
      expect(receipt.confirmed, isTrue);
      expect(receipt.revision, host.session.readingStateRevision);
    });

    test(
      'a change made while a write is executing is not credited to it',
      () async {
        await openThree();
        final held = backend.stall(Store.positionKey);
        host.session = host.session.recordPosition(pos('a', 20));
        final executing = store.requestReadingStateWrite();
        await Future<void>.delayed(Duration.zero);
        host.session = host.session.recordPosition(pos('a', 21));
        held.complete();
        final receipt = await executing;
        expect(receipt.revision, host.session.readingStateRevision - 1);
        expect(current(), isFalse, reason: 'out of date until the next write');
        await store.requestReadingStateWrite();
        expect(current(), isTrue);
      },
    );

    test(
      'documents succeed and reading state fails, and the reverse',
      () async {
        await openThree();
        host.session = host.session
            .updateDocument(host.session.byId('a')!.copyWith(source: 'y'))
            .recordPosition(pos('a', 30));
        backend.failNthWrite[Store.positionKey] = 1;
        await host.writeBoth();
        expect(
          store.confirmedDocumentsRevision,
          host.session.documentsRevision,
        );
        expect(store.confirmedReadingStateRevision, isNull);
        await store.requestReadingStateWrite();
        host.session = host.session
            .updateDocument(host.session.byId('a')!.copyWith(source: 'z'))
            .recordPosition(pos('a', 31));
        backend.failNthWrite[Store.documentKey] = 1;
        await host.writeBoth();
        expect(store.confirmedDocumentsRevision, isNull);
        expect(
          store.confirmedReadingStateRevision,
          host.session.readingStateRevision,
        );
      },
    );

    test(
      'a removal invalidates both confirmations and the restore re-credits',
      () async {
        await openThree();
        backend.failNthWrite[Store.documentKey] = 1;
        final next = host.session.close('b');
        final removal = await store.removeDocuments(
          {'b'},
          successorActiveId: next.successor,
          onVerified: () => host.session = next.session,
        );
        expect(removal, RemovalOutcome.notVerified);
        expect(store.confirmedReadingStateRevision, isNull);
        expect(store.confirmedDocumentsRevision, isNull);
        await host.writeBoth();
        expect(current(), isTrue);
      },
    );

    test('the Cycle 2 R1 trace: a waiting documents write, a failing first '
        'transaction write, a failing documents restore', () async {
      await openThree();
      final held = backend.stall(Store.documentKey);
      host.session = host.session.updateDocument(
        host.session.byId('a')!.copyWith(source: 'w'),
      );
      final waiting = store.requestDocumentsWrite();
      final next = host.session.close('b');
      backend.injectWrites[Store.positionKey] = [InjectedOutcome.failed];
      final removal = store.removeDocuments({
        'a',
        'b',
      }, onVerified: () => fail('must not verify'));
      held.complete();
      expect((await waiting).confirmed, isTrue, reason: 'truthfully credited');
      expect(await removal, RemovalOutcome.notVerified);
      expect(next.session, isNotNull);
      backend.injectWrites[Store.documentKey] = [InjectedOutcome.failed];
      await host.writeBoth();
      expect(store.confirmedDocumentsRevision, isNull, reason: 'not retained');
      expect(current(), isFalse);
    });

    test(
      'inexact, deferred and indeterminate writes set unconfirmed',
      () async {
        // Deferred: a reading-state write on legacy data whose documents write
        // is not confirmed.
        await open(seed: {Store.documentKey: jsonEncode(doc('a').toJson())});
        host.session = DocumentSession.restored(
          documents: [doc('a')],
          activeId: 'a',
        ).recordPosition(pos('a', 5));
        backend.failNthWrite[Store.documentKey] = 1;
        final deferred = await store.requestReadingStateWrite();
        expect(deferred.outcome, WriteOutcome.deferred);
        expect(store.confirmedReadingStateRevision, isNull);
        // Indeterminate.
        backend.injectWrites[Store.documentKey] = [
          InjectedOutcome.indeterminate,
        ];
        expect(
          (await store.requestDocumentsWrite()).outcome,
          WriteOutcome.indeterminate,
        );
        expect(store.confirmedDocumentsRevision, isNull);
      },
    );

    test('startup credit: decodable keys are confirmed at 0; an undecodable '
        'reading state is not', () async {
      await open(
        seed: {
          Store.documentKey: encodeDocumentSet([doc('a')]),
          Store.positionKey: encodeReadingState('a', {'a': pos('a', 1)}),
        },
      );
      expect(store.confirmedDocumentsRevision, 0);
      expect(store.confirmedReadingStateRevision, 0);
      await open(
        seed: {
          Store.documentKey: encodeDocumentSet([doc('a')]),
        },
      );
      expect(store.confirmedReadingStateRevision, 0, reason: 'absent is exact');
      await open(
        seed: {
          Store.documentKey: encodeDocumentSet([doc('a')]),
          Store.positionKey: 'not json',
        },
      );
      expect(store.confirmedDocumentsRevision, 0);
      expect(store.confirmedReadingStateRevision, isNull);
    });
  });

  // --- V-8 / V-8r ------------------------------------------------------------

  /// The four failure points of §6.2 V-8, applied to one removal.
  final injections = <String, void Function(FakeBackend)>{
    'the reading-state write': (b) =>
        b.injectWrites[Store.positionKey] = [InjectedOutcome.failed],
    'the documents write after a reading-state success': (b) =>
        b.injectWrites[Store.documentKey] = [InjectedOutcome.failed],
    'an indeterminate read-back': (b) => b.failReads.add(Store.documentKey),
    'an undecodable read-back': (_) {},
  };

  Future<RemovalOutcome> withInjection(
    String name,
    Future<RemovalOutcome> Function() run,
  ) async {
    injections[name]!(backend);
    if (name != 'an undecodable read-back') return run();
    // A corrupt value lands between the transaction's writes and its read.
    final gate = backend.stall('read:${Store.documentKey}');
    final reads = backend.readCalls[Store.documentKey] ?? 0;
    final running = run();
    while ((backend.readCalls[Store.documentKey] ?? 0) == reads) {
      await Future<void>.delayed(Duration.zero);
    }
    backend.data[Store.documentKey] = 'corrupt between operations';
    gate.complete();
    return running;
  }

  group('V-8: close under ON', () {
    for (final name in injections.keys) {
      for (final restoreFails in [false, true]) {
        test(
          'failure at $name, restore ${restoreFails ? 'fails' : 'succeeds'}: '
          'the session is unchanged and nothing is claimed',
          () async {
            await openThree();
            final before = (
              order: host.session.ids,
              active: host.session.activeId,
            );
            host.session = host.session.activate('b');
            await store.requestReadingStateWrite();
            final next = host.session.close('b');
            var applied = false;
            final outcome = await withInjection(
              name,
              () => store.removeDocuments(
                {'b'},
                successorActiveId: next.successor,
                onVerified: () => applied = true,
              ),
            );
            expect(outcome, RemovalOutcome.notVerified);
            expect(applied, isFalse, reason: 'successor not applied');
            expect(host.session.ids, before.order);
            expect(host.session.activeId, 'b');
            backend.failReads.clear();
            if (restoreFails) {
              // The documents restore, and the documents write the reading
              // state's restore depends on (§5.2) when the key is not a known
              // v2 set.
              backend.injectWrites[Store.documentKey] = [
                InjectedOutcome.failed,
                InjectedOutcome.failed,
              ];
            }
            await host.writeBoth();
            expect(current(), !restoreFails, reason: 'retained vs out of date');
            if (!restoreFails) expect(storedIds(), {'a', 'b', 'c'});
            expectWithinSession();
          },
        );
      }
    }
  });

  group('V-8r: replacement under ON (E-1)', () {
    final batches =
        <String, (Map<String, MarkdownDocument>, List<MarkdownDocument>)>{
          'one replacement': ({'a': doc('a2', name: 'a.md')}, const []),
          'two replacements plus one addition': (
            {'a': doc('a2', name: 'a.md'), 'b': doc('b2', name: 'b.md')},
            [doc('d')],
          ),
        };
    for (final batch in batches.entries) {
      for (final name in injections.keys) {
        test('${batch.key}, failure at $name: nothing changes and no new ID is '
            'stored', () async {
          await openThree();
          final before = host.session;
          final outcome = await withInjection(
            name,
            () => host.store.removeDocuments(
              batch.value.$1.keys.toSet(),
              replacing: true,
              onVerified: () => fail('must not commit'),
            ),
          );
          expect(outcome, RemovalOutcome.notVerified);
          expect(identical(host.session, before), isTrue);
          final newIds = {
            for (final d in [...batch.value.$1.values, ...batch.value.$2]) d.id,
          };
          backend.failReads.clear();
          expect(storedIds().intersection(newIds), isEmpty);
          expectWithinSession();
          await host.writeBoth();
          expect(current(), isTrue);
          final restored = await reload();
          expect(restored!.documents.map((d) => d.id), ['a', 'b', 'c']);
        });
      }

      test(
        '${batch.key} verified: old IDs gone for good, new copies saved',
        () async {
          await openThree();
          expect(
            await host.replace(batch.value.$1, adds: batch.value.$2),
            RemovalOutcome.verified,
          );
          for (final old in batch.value.$1.keys) {
            expect(storedIds(), isNot(contains(old)));
            expect(storedPositionIds(), isNot(contains(old)));
          }
          expect(
            storedIds(),
            containsAll(
              [...batch.value.$1.values, ...batch.value.$2].map((d) => d.id),
            ),
          );
          // DR-2: a stale snapshot naming an old ID is filtered, not written.
          host.session = DocumentSession.restored(
            documents: [doc('a'), doc('c')],
            activeId: 'a',
          );
          expect((await store.requestDocumentsWrite()).exact, isFalse);
          expect(storedIds(), isNot(contains('a')));
        },
      );
    }

    test(
      'the commit runs inside the operation: a write requested between '
      'verification and the caller\'s continuation sees the new session',
      () async {
        await openThree();
        Future<WriteReceipt>? during;
        final outcome = await store.removeDocuments(
          {'a'},
          replacing: true,
          onVerified: () {
            host.session = host.session.commitBatch(
              replacements: {'a': doc('a2', name: 'a.md')},
              activeId: 'a2',
            );
            during = store.requestDocumentsWrite();
          },
        );
        expect(outcome, RemovalOutcome.verified);
        await during;
        expect(storedIds(), {'a2', 'b', 'c'});
      },
    );

    test('a failed restore leaves a truthful subset (DR-3)', () async {
      await openThree();
      backend.injectWrites[Store.documentKey] = [
        InjectedOutcome.failed,
        InjectedOutcome.failed,
      ];
      expect(
        await store.removeDocuments(
          {'a'},
          replacing: true,
          onVerified: () => fail('no'),
        ),
        RemovalOutcome.notVerified,
      );
      await host.writeBoth();
      expect(current(), isFalse);
      expectWithinSession();
    });
  });

  // --- V-8a ------------------------------------------------------------------

  group('V-8a: active persistence across a restart', () {
    test('a switch alone survives a restart', () async {
      await openThree();
      host.session = host.session.activate('b');
      await store.requestReadingStateWrite();
      expect((await reload())!.activeId, 'b');
    });

    test('closing the active B in A, B, C restores with C active', () async {
      await openThree();
      host.session = host.session.activate('b');
      await store.requestReadingStateWrite();
      expect(await host.close('b'), RemovalOutcome.verified);
      expect((await reload())!.activeId, 'c');
    });

    test('closing an inactive B keeps A active', () async {
      await openThree();
      expect(await host.close('b'), RemovalOutcome.verified);
      expect((await reload())!.activeId, 'a');
    });

    test('closing the last document removes both keys', () async {
      await open();
      await host.load([doc('a')]);
      expect(await host.close('a'), RemovalOutcome.verified);
      expect(backend.data.containsKey(Store.documentKey), isFalse);
      expect(backend.data.containsKey(Store.positionKey), isFalse);
      expect(await reload(), isNull);
    });
  });

  // --- V-8c ------------------------------------------------------------------

  group('V-8c: the contract on the fake backend', () {
    final fake = FakeBackend();
    final checks = storageContractChecks(
      fake,
      ContractHooks(
        reopen: () async => fake,
        failNextWrite: (key) =>
            fake.injectWrites[key] = [InjectedOutcome.failed],
        failNextDelete: (key) =>
            fake.injectDeletes[key] = [InjectedOutcome.failed],
        nextWriteIndeterminateButApplied: (key) =>
            fake.injectWrites[key] = [InjectedOutcome.indeterminateApplied],
        unavailable: UnavailableBackend.new,
      ),
    );
    for (final check in checks) {
      test('${check.id}: ${check.name}', check.run);
    }
  });

  group('V-8c: the Store failure matrix', () {
    final outcomes = [
      InjectedOutcome.failed,
      InjectedOutcome.indeterminate,
      InjectedOutcome.indeterminateApplied,
    ];

    /// The whole committed state a later start decodes: documents with their
    /// content, the active document and every position.
    Future<Map<String, Object?>> committed() async {
      final restored = await reload();
      if (restored == null) return {'documents': null};
      return {
        'documents': {for (final d in restored.documents) d.id: d.source},
        'active': restored.activeId,
        'positions': {
          for (final e in restored.positions.entries) e.key: e.value.blockIndex,
        },
      };
    }

    // The openThree() state: a, b, c with places 1, 2, 3, a active.
    const sources = {
      'a': '# a\n\nBody of a.',
      'b': '# b\n\nBody of b.',
      'c': '# c\n\nBody of c.',
    };
    const places = {'a': 1, 'b': 2, 'c': 3};

    for (final outcome in outcomes) {
      final applied = outcome == InjectedOutcome.indeterminateApplied;

      test('an ordinary documents write, ${outcome.name}: never credited; a '
          'reload restores exactly what committed', () async {
        await openThree();
        host.session = host.session.updateDocument(
          host.session.byId('a')!.copyWith(source: 'new a'),
        );
        backend.injectWrites[Store.documentKey] = [outcome];
        final receipt = await store.requestDocumentsWrite();
        expect(receipt.confirmed, isFalse);
        expect(store.confirmedDocumentsRevision, isNull);
        expect(await committed(), {
          'documents': {...sources, if (applied) 'a': 'new a'},
          'active': 'a',
          'positions': places,
        });
        expectWithinSession();
      });

      test('an ordinary reading-state write, ${outcome.name}: never credited; '
          'a reload restores exactly what committed', () async {
        await openThree();
        // The documents key already holds a committed v2 set, so the reading
        // state is written on its own, with no dependency write (§5.2).
        host.session = host.session.activate('c').recordPosition(pos('c', 30));
        backend.injectWrites[Store.positionKey] = [outcome];
        final receipt = await store.requestReadingStateWrite();
        expect(receipt.outcome, isNot(WriteOutcome.deferred));
        expect(
          receipt.outcome,
          applied ? WriteOutcome.indeterminate : _reported(outcome),
        );
        expect(receipt.confirmed, isFalse);
        expect(store.confirmedReadingStateRevision, isNull);
        expect(backend.writes.where((k) => k == Store.documentKey), isEmpty);
        expect(await committed(), {
          'documents': sources,
          'active': applied ? 'c' : 'a',
          'positions': {...places, if (applied) 'c': 30},
        });
        expectWithinSession();
      });

      for (final step in ['first', 'second']) {
        test('the removal transaction\'s $step write ${outcome.name}: not '
            'verified; a reload restores exactly what committed', () async {
          await openThree();
          // On migrated data the reading state goes first (§5.5 step 3).
          final key = step == 'first' ? Store.positionKey : Store.documentKey;
          backend.injectWrites[key] = [outcome];
          final result = await store.removeDocuments(
            {'b'},
            successorActiveId: 'a',
            onVerified: () => fail('must not verify'),
          );
          expect(result, RemovalOutcome.notVerified);
          expectWithinSession();

          // What committed: the reading-state projection when the first write
          // committed or was applied; the documents projection only when the
          // second was applied. A short-circuit leaves the rest untouched.
          final readingProjected = step == 'second' || applied;
          final documentsProjected = step == 'second' && applied;
          expect(await committed(), {
            'documents': {
              for (final e in sources.entries)
                if (!(documentsProjected && e.key == 'b')) e.key: e.value,
            },
            'active': 'a',
            'positions': {
              for (final e in places.entries)
                if (!(readingProjected && e.key == 'b')) e.key: e.value,
            },
          });
        });
      }

      test('the whole-store delete ${outcome.name}: no success claim, and the '
          'Retry deletes again', () async {
        await openThree();
        backend.injectDeletes[Store.documentKey] = [outcome];
        final first = await store.removeRetainedContent();
        expect(
          first.isConfirmedAbsent,
          outcome == InjectedOutcome.indeterminateApplied,
        );
        final calls = backend.deleteCalls[Store.documentKey]!;
        await store.removeRetainedContent();
        expect(backend.deleteCalls[Store.documentKey], calls + 1);
        expect(store.rawContentPresence(), RawKeyPresence.absent);
      });
    }
  });

  // --- V-8s ------------------------------------------------------------------

  group('V-8s: bounded settings settlement', () {
    Future<void> openBounded() async {
      backend = FakeBackend();
      store = Store();
      await store.init(
        backend: backend,
        settingsBound: const Duration(milliseconds: 60),
      );
      await store.refreshContentPresence();
      retention = RetentionController(store);
      host = Host(store);
    }

    test('a stalled settings write resolves indeterminate at T_set, and the '
        'next queued content operation runs', () async {
      await openBounded();
      store.applyResolvedPolicy(RetentionPolicy.on);
      host.session = host.session.commitBatch(adds: [doc('a')], activeId: 'a');
      final gate = backend.stall(Store.settingsKey);
      final settings = store.saveSettings(const Settings(wrapCode: true));
      final content = store.requestDocumentsWrite();
      expect(await settings, WriteOutcome.indeterminate);
      expect((await content).confirmed, isTrue);
      // The late completion changes nothing already reported.
      gate.complete();
      await store.settlePendingOperations();
      expect(await settings, WriteOutcome.indeterminate);
    });

    test('a request superseded before issue is never issued; writes are '
        'issued in request order', () async {
      await openBounded();
      final gate = backend.stall(Store.settingsKey);
      final first = store.saveSettings(const Settings(fontScale: 1.1));
      final superseded = store.saveSettings(const Settings(fontScale: 1.2));
      final last = store.saveSettings(const Settings(fontScale: 1.3));
      gate.complete();
      expect(await first, WriteOutcome.saved);
      expect(await superseded, WriteOutcome.superseded);
      expect(await last, WriteOutcome.saved);
      expect(backend.writes.where((k) => k == Store.settingsKey), hasLength(2));
      expect(store.loadSettings().fontScale, 1.3);
    });

    test('ON to OFF with an indeterminate OFF write still removes content and '
        'never says "could not be saved"', () async {
      await openBounded();
      store.applyResolvedPolicy(RetentionPolicy.on);
      await host.load([doc('a')]);
      backend.stall(Store.settingsKey);
      final result = await retention.disable(current: const Settings());
      expect(result.preferenceOutcome, WriteOutcome.indeterminate);
      expect(result.contentConfirmedAbsent, isTrue);
      expect(result.removedAndWillNotReturn, isFalse);
      expect(backend.data.containsKey(Store.documentKey), isFalse);
    });

    test('ON with an indeterminate preference write is never kept', () async {
      await openBounded();
      host.session = host.session.commitBatch(adds: [doc('a')], activeId: 'a');
      backend.stall(Store.settingsKey);
      final result = await retention.enable(current: const Settings());
      expect(result.preferenceOutcome, WriteOutcome.indeterminate);
      expect(result.keptForNextTime, isFalse);
      expect(result.effectivePolicy, RetentionPolicy.off);
      expect(backend.data.containsKey(Store.documentKey), isFalse);
    });
  });

  group('a stored non-string value is present, never absent', () {
    test('under ON: presence is present, nothing decodes, and the key is '
        'removable', () async {
      backend = FakeBackend({
        Store.settingsKey: jsonEncode(
          const Settings(keepForNextTime: true).toJson(),
        ),
        Store.documentKey: '(stored null)',
      });
      backend.undecodable.add(Store.documentKey);
      store = Store();
      await store.init(backend: backend);
      final startup = await RetentionController(store).resolveStartup();
      expect(startup.effectivePolicy, RetentionPolicy.on);
      expect(store.rawKeyPresence(Store.documentKey), RawKeyPresence.present);
      expect(store.rawContentPresence(), RawKeyPresence.present);
      expect(store.loadRetained(), isNull, reason: 'recovery, not a document');
      expect(
        await RetentionController(store).removeUnreadableData(),
        CleanupOutcome.confirmedAbsent,
      );
    });

    test(
      'under OFF: startup cleanup removes it rather than missing it',
      () async {
        backend = FakeBackend({Store.documentKey: '(stored undefined)'});
        backend.undecodable.add(Store.documentKey);
        store = Store();
        await store.init(backend: backend);
        final startup = await RetentionController(store).resolveStartup();
        expect(startup.rawContentPresentAtStartup, RawKeyPresence.present);
        expect(startup.cleanup, CleanupOutcome.confirmedAbsent);
        expect(backend.data.containsKey(Store.documentKey), isFalse);
      },
    );
  });

  // --- V-9a ------------------------------------------------------------------

  group('V-9a: decoder fixtures', () {
    final a = doc('a');
    final b = doc('b');
    RetainedState? combine(String documents, [String? reading]) =>
        combineRetained(
          decodeDocumentKey(documents),
          reading == null ? null : decodeReadingKey(reading),
        );

    test('a legacy object is a one-document set', () {
      final state = combine(
        jsonEncode(a.toJson()),
        jsonEncode(pos('a', 3).toJson()),
      );
      expect(state!.documents.map((d) => d.id), ['a']);
      expect(state.positions['a']!.blockIndex, 3);
    });

    test('v2 with and without activeId', () {
      expect(
        combine(
          encodeDocumentSet([a, b]),
          encodeReadingState('b', {}),
        )!.activeId,
        'b',
      );
      expect(combine(encodeDocumentSet([a, b]))!.activeId, 'a');
    });

    test('an activeId not in the set falls back to the first document', () {
      expect(
        combine(
          encodeDocumentSet([a, b]),
          encodeReadingState('zzz', {}),
        )!.activeId,
        'a',
      );
    });

    test(
      'v3, malformed, duplicate IDs and duplicate names are undecodable',
      () {
        for (final raw in [
          jsonEncode([
            'saudo-document-set',
            3,
            {
              'documents': [a.toJson()],
            },
          ]),
          jsonEncode([
            'saudo-document-set',
            2,
            {'documents': 'nope'},
          ]),
          jsonEncode(['saudo-document-set', 2]),
          'not json',
          jsonEncode([
            'saudo-document-set',
            2,
            {
              'documents': [a.toJson(), a.toJson()],
            },
          ]),
          encodeDocumentSet([
            doc('x', name: 'same.md'),
            doc('y', name: 'same.md'),
          ]),
          jsonEncode([
            'saudo-document-set',
            2,
            {'documents': []},
          ]),
          jsonEncode({'title': 'no id'}),
        ]) {
          expect(decodeDocumentKey(raw).isDecodable, isFalse, reason: raw);
        }
      },
    );

    test('two null names are valid', () {
      expect(
        decodeDocumentKey(
          encodeDocumentSet([pasted('p1'), pasted('p2')]),
        ).isDecodable,
        isTrue,
      );
    });

    test('orphan positions are dropped', () {
      final state = combine(
        encodeDocumentSet([a]),
        encodeReadingState('a', {'a': pos('a', 1), 'gone': pos('gone', 2)}),
      );
      expect(state!.positions.keys, ['a']);
    });

    test('an undecodable reading state restores at the top, first active, '
        'out of date', () {
      final state = combine(encodeDocumentSet([a, b]), 'garbage');
      expect(state!.activeId, 'a');
      expect(state.positions, isEmpty);
      expect(state.readingStateDecodable, isFalse);
    });

    test('a v2 document set with a legacy position', () {
      final state = combine(
        encodeDocumentSet([a, b]),
        jsonEncode(pos('b', 6).toJson()),
      );
      expect(state!.positions['b']!.blockIndex, 6);
      expect(state.activeId, 'a');
    });

    test('a legacy document with an absent position', () {
      final state = combine(jsonEncode(a.toJson()));
      expect(state!.documents.single.id, 'a');
      expect(state.positions, isEmpty);
    });

    test('v1.6.1 fails closed: the new shapes are not JSON objects', () {
      for (final raw in [
        encodeDocumentSet([a]),
        encodeReadingState('a', {'a': pos('a', 1)}),
      ]) {
        expect(jsonDecode(raw) is Map, isFalse);
      }
    });
  });

  // --- V-9m ------------------------------------------------------------------

  group('V-9m: migration ordering', () {
    Future<void> openLegacy() async {
      await open(
        seed: {
          Store.documentKey: jsonEncode(doc('a').toJson()),
          Store.positionKey: jsonEncode(pos('a', 2).toJson()),
        },
      );
      final retained = store.loadRetained()!;
      host.session = DocumentSession.restored(
        documents: retained.documents,
        activeId: retained.activeId,
        positions: retained.positions,
      );
    }

    test(
      'a first position-only update writes the documents key first',
      () async {
        await openLegacy();
        host.session = host.session.recordPosition(pos('a', 9));
        final receipt = await store.requestReadingStateWrite();
        expect(receipt.confirmed, isTrue);
        expect(backend.writes, [Store.documentKey, Store.positionKey]);
        expect(isCurrentDocumentSet(backend.data[Store.documentKey]!), isTrue);
      },
    );

    for (final outcome in [
      InjectedOutcome.failed,
      InjectedOutcome.indeterminate,
    ]) {
      test('an unconfirmed (${outcome.name}) documents write defers the '
          'reading state and leaves the legacy position untouched', () async {
        await openLegacy();
        final legacy = backend.data[Store.positionKey];
        backend.injectWrites[Store.documentKey] = [outcome];
        host.session = host.session.recordPosition(pos('a', 9));
        final receipt = await store.requestReadingStateWrite();
        expect(receipt.outcome, WriteOutcome.deferred);
        expect(backend.data[Store.positionKey], legacy);
        expect(current(), isFalse);
      });
    }

    test('an interruption between the two writes leaves a reachable '
        'combination: v2 document, legacy position', () async {
      await openLegacy();
      backend.injectWrites[Store.positionKey] = [InjectedOutcome.failed];
      host.session = host.session.recordPosition(pos('a', 9));
      await store.requestReadingStateWrite();
      expect(isCurrentDocumentSet(backend.data[Store.documentKey]!), isTrue);
      expect(jsonDecode(backend.data[Store.positionKey]!) is Map, isTrue);
      expect((await reload())!.positions['a']!.blockIndex, 2);
    });

    test('the legacy document with a v2 position is never produced', () async {
      await openLegacy();
      backend.injectWrites[Store.documentKey] = [InjectedOutcome.failed];
      host.session = host.session.recordPosition(pos('a', 9));
      await store.requestReadingStateWrite();
      final document = backend.data[Store.documentKey]!;
      final position = backend.data[Store.positionKey]!;
      final legacyDocument = jsonDecode(document) is Map;
      final v2Position = jsonDecode(position) is List;
      expect(legacyDocument && v2Position, isFalse);
    });

    test('a removal transaction on unmigrated data writes the documents '
        'projection first', () async {
      await open(
        seed: {
          Store.documentKey: jsonEncode(doc('a').toJson()),
          Store.positionKey: jsonEncode(pos('a', 2).toJson()),
        },
      );
      host.session = DocumentSession.restored(
        documents: [doc('a'), doc('b')],
        activeId: 'a',
      );
      await store.removeDocuments(
        {'b'},
        successorActiveId: 'a',
        onVerified: () => host.session = host.session.close('b').session,
      );
      expect(backend.writes.first, Store.documentKey);
    });
  });

  // --- V-19 ------------------------------------------------------------------

  group('V-19: edit and script preference with a stalled backend', () {
    test(
      'an edit during a stalled documents write is what ends up stored',
      () async {
        await open();
        await host.load([doc('a')]);
        final held = backend.stall(Store.documentKey);
        host.session = host.session.updateDocument(
          host.session.byId('a')!.copyWith(source: 'first edit'),
        );
        final first = store.requestDocumentsWrite();
        await Future<void>.delayed(Duration.zero);
        host.session = host.session.updateDocument(
          host.session.byId('a')!.copyWith(source: 'second edit'),
        );
        final second = store.requestDocumentsWrite();
        final third = store.requestDocumentsWrite();
        expect(identical(second, third), isTrue, reason: 'coalesced');
        held.complete();
        expect(
          (await first).revision,
          lessThan(host.session.documentsRevision),
        );
        final receipt = await second;
        expect(receipt.confirmed, isTrue);
        expect(receipt.revision, host.session.documentsRevision);
        expect((await reload())!.documents.single.source, 'second edit');
      },
    );

    test('a script preference change is stored', () async {
      await open();
      await host.load([doc('a')]);
      host.session = host.session.updateDocument(
        host.session
            .byId('a')!
            .copyWith(
              scriptPreference: DocumentScriptPreference.simplifiedChinese,
            ),
      );
      expect((await store.requestDocumentsWrite()).confirmed, isTrue);
      expect(
        (await reload())!.documents.single.scriptPreference,
        DocumentScriptPreference.simplifiedChinese,
      );
    });

    test('each edit\'s feedback reflects the write that covers it', () async {
      await open();
      await host.load([doc('a')]);
      host.session = host.session.updateDocument(
        host.session.byId('a')!.copyWith(source: 'will fail'),
      );
      backend.injectWrites[Store.documentKey] = [InjectedOutcome.failed];
      expect((await store.requestDocumentsWrite()).confirmed, isFalse);
      host.session = host.session.updateDocument(
        host.session.byId('a')!.copyWith(source: 'will land'),
      );
      expect((await store.requestDocumentsWrite()).confirmed, isTrue);
    });
  });

  // --- V-20 ------------------------------------------------------------------

  group('V-20: pasted documents (store part)', () {
    test('two pastes are saved and restored as two documents with their own '
        'places', () async {
      await open();
      final allocator = DocumentIdAllocator();
      final one = pasted(allocator.allocate());
      final two = pasted(allocator.allocate(host.session.ids));
      await host.load([one]);
      await host.load([two]);
      host.session = host.session
          .recordPosition(pos(one.id, 4))
          .recordPosition(pos(two.id, 8));
      await store.requestReadingStateWrite();
      final restored = await reload();
      expect(restored!.documents.map((d) => d.id), [one.id, two.id]);
      expect(restored.documents.every((d) => d.sourceName == null), isTrue);
      expect(restored.positions[one.id]!.blockIndex, 4);
      expect(restored.positions[two.id]!.blockIndex, 8);
      expect(host.session.byName(kPastedDocumentLabel), isNull);
    });
  });

  // --- V-23 ------------------------------------------------------------------

  group('V-23: the storage boundary (D-13)', () {
    String read(String path) =>
        File(path).readAsStringSync().replaceAll('\r\n', '\n');
    final libFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .map((f) => f.path.replaceAll('\\', '/'))
        .toList();
    const web = 'lib/storage/indexed_db_storage_backend_web.dart';

    test('only the web backend references IndexedDB', () {
      final offenders = [
        for (final path in libFiles)
          if (path != web &&
              RegExp(r'\bIDB[A-Z]\w*|indexedDB').hasMatch(read(path)))
            path,
      ];
      expect(offenders, isEmpty);
      expect(read(web), contains('IDBDatabase'));
    });

    test('the Store touches Hive only for settings', () {
      final store = read('lib/store.dart');
      final boxCalls = RegExp(
        r'_box\.(\w+)\(',
      ).allMatches(store).map((m) => m[1]);
      expect(boxCalls.toSet(), {'get', 'put'});
      final hiveSettings = store.substring(
        store.indexOf('class HiveSettingsBackend'),
        store.indexOf('class RetainedSnapshot'),
      );
      expect(
        RegExp(r'_box\.').allMatches(store).length,
        RegExp(r'_box\.').allMatches(hiveSettings).length,
        reason: 'no Hive box call outside the settings backend',
      );
      expect(store, contains('readSetting(settingsKey)'));
    });

    test('the session, the app and the screens import no storage '
        'implementation', () {
      for (final path in [
        'lib/document_session.dart',
        'lib/main.dart',
        for (final p in libFiles)
          if (p.endsWith('_screen.dart') || p.endsWith('_sheet.dart')) p,
      ]) {
        final source = read(path);
        expect(source, isNot(contains('hive')), reason: path);
        expect(source, isNot(contains('indexed_db')), reason: path);
        expect(source, isNot(contains('package:web/')), reason: path);
      }
    });

    final wholeBox = RegExp(
      r'\b(Hive|_?box|Box<\w+>)\.(clear|deleteFromDisk|compact)\(|'
      r'Hive\.deleteBoxFromDisk\(',
    );

    test('the whole-box scan detects every prohibited call (negative '
        'control)', () {
      for (final prohibited in [
        'await _box.clear();',
        'box.clear();',
        '_box.compact();',
        'await box.deleteFromDisk();',
        'Hive.deleteBoxFromDisk(name);',
        'await Hive.deleteFromDisk();',
      ]) {
        expect(wholeBox.hasMatch(prohibited), isTrue, reason: prohibited);
      }
      for (final allowed in [
        '_committed.clear();',
        '_suppressedIds.clear();',
        '_box.get(key);',
        '_box.put(key, value);',
        'checkbox.compactness',
      ]) {
        expect(wholeBox.hasMatch(allowed), isFalse, reason: allowed);
      }
    });

    test('no Hive call touches every key', () {
      for (final path in libFiles) {
        expect(wholeBox.hasMatch(read(path)), isFalse, reason: path);
      }
    });
  });
}

WriteOutcome _reported(InjectedOutcome outcome) => switch (outcome) {
  InjectedOutcome.failed => WriteOutcome.failed,
  InjectedOutcome.indeterminate => WriteOutcome.indeterminate,
  InjectedOutcome.indeterminateApplied => WriteOutcome.indeterminate,
  InjectedOutcome.committed => WriteOutcome.saved,
};
