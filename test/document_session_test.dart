// DF-020 CP1: the multi-document session model and the ID allocator.
//
// Pure Dart. V-1 (allocation) and the session invariant tests from the DF-020
// plan, §4.1-§4.2 and §6.2.

import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/document_session.dart';
import 'package:markdown_viewer/models.dart';

MarkdownDocument doc(String id, {String? name}) =>
    MarkdownDocument.fromSource('# $id', id: id, sourceName: name);

ReadingPosition pos(String id, int block, {double fraction = 0}) =>
    ReadingPosition(
      documentId: id,
      blockIndex: block,
      fraction: fraction,
      savedAt: DateTime.utc(2026, 11, 16),
    );

/// A, B and C loaded as one batch, A active.
DocumentSession abc() => DocumentSession.empty.commitBatch(
  adds: [
    doc('a', name: 'A.md'),
    doc('b', name: 'B.md'),
    doc('c', name: 'C.md'),
  ],
  activeId: 'a',
);

List<String> order(DocumentSession session) => [
  for (final document in session.documents) document.id,
];

/// Every invariant from plan §4.1, checked directly on a value.
void expectInvariants(DocumentSession session) {
  final ids = order(session);
  expect(ids.toSet().length, ids.length, reason: 'IDs are unique');
  if (session.isEmpty) {
    expect(session.activeId, isNull);
  } else {
    expect(ids, contains(session.activeId));
  }
  for (final entry in session.positions.entries) {
    expect(ids, contains(entry.key), reason: 'positions are for open IDs');
    expect(entry.value.documentId, entry.key);
  }
  final names = [
    for (final document in session.documents)
      if (document.sourceName != null) document.sourceName!,
  ];
  expect(names.toSet().length, names.length, reason: 'non-null names unique');
}

void main() {
  group('empty and restored sessions', () {
    test('the empty session has nothing open and nothing active', () {
      final session = DocumentSession.empty;
      expect(session.isEmpty, isTrue);
      expect(session.documents, isEmpty);
      expect(session.activeId, isNull);
      expect(session.active, isNull);
      expect(session.positions, isEmpty);
      expect(session.documentsRevision, 0);
      expect(session.readingStateRevision, 0);
      expectInvariants(session);
    });

    test('a restored session starts at revision zero', () {
      final session = DocumentSession.restored(
        documents: [doc('a', name: 'A.md')],
        activeId: 'a',
        positions: {'a': pos('a', 7)},
      );
      expect(session.active!.id, 'a');
      expect(session.positions['a']!.blockIndex, 7);
      expect(session.documentsRevision, 0);
      expect(session.readingStateRevision, 0);
      expectInvariants(session);
    });

    test('a restored session that breaks an invariant is refused', () {
      expect(
        () => DocumentSession.restored(
          documents: [doc('a'), doc('a')],
          activeId: 'a',
        ),
        throwsArgumentError,
        reason: 'duplicate ID',
      );
      expect(
        () => DocumentSession.restored(documents: [doc('a')]),
        throwsArgumentError,
        reason: 'no active document while one is open',
      );
      expect(
        () => DocumentSession.restored(
          documents: [doc('a')],
          activeId: 'missing',
        ),
        throwsArgumentError,
        reason: 'active ID not open',
      );
      expect(
        () => DocumentSession.restored(documents: const [], activeId: 'a'),
        throwsArgumentError,
        reason: 'active ID with nothing open',
      );
      expect(
        () => DocumentSession.restored(
          documents: [doc('a')],
          activeId: 'a',
          positions: {'b': pos('b', 1)},
        ),
        throwsArgumentError,
        reason: 'position for a document that is not open',
      );
      expect(
        () => DocumentSession.restored(
          documents: [doc('a'), doc('b')],
          activeId: 'a',
          positions: {'a': pos('b', 1)},
        ),
        throwsArgumentError,
        reason: 'position filed under another document',
      );
      expect(
        () => DocumentSession.restored(
          documents: [
            doc('a', name: 'A.md'),
            doc('b', name: 'A.md'),
          ],
          activeId: 'a',
        ),
        throwsArgumentError,
        reason: 'duplicate non-null filename',
      );
    });
  });

  group('immutability', () {
    test('collections cannot be modified in place', () {
      final session = abc().recordPosition(pos('a', 3));
      expect(() => session.documents.add(doc('x')), throwsUnsupportedError);
      expect(
        () => session.positions['a'] = pos('a', 9),
        throwsUnsupportedError,
      );
      expect(() => session.positions.remove('a'), throwsUnsupportedError);
    });

    test('caller lists and maps are copied, not aliased', () {
      final adds = [doc('a'), doc('b')];
      final positions = {'a': pos('a', 1)};
      final session = DocumentSession.restored(
        documents: adds,
        activeId: 'a',
        positions: positions,
      );
      adds.add(doc('c'));
      positions['b'] = pos('b', 2);
      expect(order(session), ['a', 'b']);
      expect(session.positions.keys, ['a']);
    });

    test('every operation returns a new value and leaves the old one as it '
        'was', () {
      final before = abc().recordPosition(pos('b', 4));
      final snapshot = (
        order(before),
        before.activeId,
        Map.of(before.positions),
        before.documentsRevision,
        before.readingStateRevision,
      );

      final results = [
        before.activate('c'),
        before.close('b').session,
        before.updateDocument(doc('a', name: 'A.md').copyWith(source: 'x')),
        before.recordPosition(pos('a', 9)),
        before.commitBatch(adds: [doc('d')], activeId: 'd'),
        before.commitBatch(
          replacements: {'a': doc('a2', name: 'A.md')},
          activeId: 'a2',
        ),
      ];

      for (final result in results) {
        expect(identical(result, before), isFalse);
      }
      expect(order(before), snapshot.$1);
      expect(before.activeId, snapshot.$2);
      expect(before.positions, snapshot.$3);
      expect(before.documentsRevision, snapshot.$4);
      expect(before.readingStateRevision, snapshot.$5);
    });
  });

  group('commitBatch', () {
    test('adds append in the given order and the named document is active', () {
      final first = abc();
      final session = first.commitBatch(
        adds: [
          doc('d', name: 'D.md'),
          doc('e', name: 'E.md'),
        ],
        activeId: 'd',
      );
      expect(order(session), ['a', 'b', 'c', 'd', 'e']);
      expect(session.activeId, 'd');
      expectInvariants(session);
    });

    test('a replacement takes the replaced slot and drops its position', () {
      final session = abc()
          .recordPosition(pos('a', 5))
          .recordPosition(pos('b', 6))
          .commitBatch(
            replacements: {'b': doc('b2', name: 'B.md')},
            adds: [doc('d', name: 'D.md')],
            activeId: 'b2',
          );
      expect(order(session), ['a', 'b2', 'c', 'd']);
      expect(session.activeId, 'b2');
      expect(session.positions.keys, [
        'a',
      ], reason: 'the new copy starts at the top');
      expect(session.byName('B.md')!.id, 'b2');
      expectInvariants(session);
    });

    test('bumps both revisions exactly once', () {
      final before = abc();
      final after = before.commitBatch(adds: [doc('d')], activeId: 'd');
      expect(after.documentsRevision, before.documentsRevision + 1);
      expect(after.readingStateRevision, before.readingStateRevision + 1);
    });

    test('refuses, unchanged, anything that would break an invariant', () {
      final session = abc();
      final attempts = <String, DocumentSession Function()>{
        'empty batch': () => session.commitBatch(activeId: 'a'),
        'duplicate ID with an open document': () =>
            session.commitBatch(adds: [doc('a')], activeId: 'a'),
        'duplicate ID inside the batch': () =>
            session.commitBatch(adds: [doc('d'), doc('d')], activeId: 'd'),
        'an add named like an open document': () => session.commitBatch(
          adds: [doc('d', name: 'A.md')],
          activeId: 'd',
        ),
        'two adds with the same name': () => session.commitBatch(
          adds: [
            doc('d', name: 'D.md'),
            doc('e', name: 'D.md'),
          ],
          activeId: 'd',
        ),
        'a replacement named like another open document': () =>
            session.commitBatch(
              replacements: {'a': doc('a2', name: 'B.md')},
              activeId: 'a2',
            ),
        'replacing a document that is not open': () => session.commitBatch(
          replacements: {'missing': doc('x')},
          activeId: 'x',
        ),
        'an active ID outside the batch': () =>
            session.commitBatch(adds: [doc('d')], activeId: 'a'),
        'an active ID that is not open at all': () =>
            session.commitBatch(adds: [doc('d')], activeId: 'missing'),
      };
      for (final entry in attempts.entries) {
        expect(entry.value, throwsArgumentError, reason: entry.key);
      }
      expect(order(session), ['a', 'b', 'c']);
      expect(session.activeId, 'a');
    });

    test('a replacement may keep the replaced document\'s name', () {
      final session = abc().commitBatch(
        replacements: {'a': doc('a2', name: 'A.md')},
        activeId: 'a2',
      );
      expect(session.byName('A.md')!.id, 'a2');
    });
  });

  group('activate', () {
    test('makes a document active and bumps only the reading state', () {
      final before = abc();
      final after = before.activate('c');
      expect(after.activeId, 'c');
      expect(after.active!.id, 'c');
      expect(order(after), order(before));
      expect(after.documentsRevision, before.documentsRevision);
      expect(after.readingStateRevision, before.readingStateRevision + 1);
      expectInvariants(after);
    });

    test('activating the active document changes nothing', () {
      final before = abc();
      expect(identical(before.activate('a'), before), isTrue);
    });

    test('an ID that is not open, or was closed, is refused', () {
      final session = abc();
      expect(() => session.activate('missing'), throwsArgumentError);
      final closed = session.close('b').session;
      expect(() => closed.activate('b'), throwsArgumentError);
      expect(() => DocumentSession.empty.activate('a'), throwsArgumentError);
    });
  });

  group('close and the D-11 successor', () {
    test('closing an inactive document leaves the active one unchanged', () {
      final result = abc().close('b');
      expect(result.successor, 'a');
      expect(result.session.activeId, 'a');
      expect(order(result.session), ['a', 'c']);
      expectInvariants(result.session);
    });

    test('closing the active document activates its right neighbour', () {
      final result = abc().activate('b').close('b');
      expect(result.successor, 'c');
      expect(result.session.activeId, 'c');
      expect(order(result.session), ['a', 'c']);
    });

    test('closing the active first document activates the second', () {
      final result = abc().close('a');
      expect(result.successor, 'b');
      expect(order(result.session), ['b', 'c']);
    });

    test('closing the active last document activates its left neighbour', () {
      final result = abc().activate('c').close('c');
      expect(result.successor, 'b');
      expect(result.session.activeId, 'b');
    });

    test('closing an inactive last document keeps the active one', () {
      final result = abc().activate('b').close('c');
      expect(result.successor, 'b');
    });

    test('closing the only document empties the session', () {
      final result = DocumentSession.empty
          .commitBatch(
            adds: [doc('a', name: 'A.md')],
            activeId: 'a',
          )
          .recordPosition(pos('a', 2))
          .close('a');
      expect(result.successor, isNull);
      expect(result.session.isEmpty, isTrue);
      expect(result.session.activeId, isNull);
      expect(result.session.positions, isEmpty);
      expectInvariants(result.session);
    });

    test('S04-02: B active in A, B, C - closing B shows C', () {
      final result = abc().activate('b').close('b');
      expect(result.session.active!.sourceName, 'C.md');
    });

    test('the closed document\'s position goes, the others stay', () {
      final result = abc()
          .recordPosition(pos('a', 1))
          .recordPosition(pos('b', 2))
          .recordPosition(pos('c', 3))
          .close('b');
      expect(result.session.positions.keys.toSet(), {'a', 'c'});
      expect(result.session.positions['a']!.blockIndex, 1);
      expect(result.session.positions['c']!.blockIndex, 3);
    });

    test('bumps both revisions exactly once', () {
      final before = abc();
      final after = before.close('c').session;
      expect(after.documentsRevision, before.documentsRevision + 1);
      expect(after.readingStateRevision, before.readingStateRevision + 1);
    });

    test('an ID that is not open, or was already closed, is refused', () {
      final session = abc();
      expect(() => session.close('missing'), throwsArgumentError);
      final once = session.close('b').session;
      expect(() => once.close('b'), throwsArgumentError);
      expect(() => DocumentSession.empty.close('a'), throwsArgumentError);
    });

    test('closing every document in turn always leaves a valid session', () {
      var session = abc().activate('b');
      final seen = <String?>[];
      while (!session.isEmpty) {
        final result = session.close(session.activeId!);
        seen.add(result.successor);
        session = result.session;
        expectInvariants(session);
      }
      expect(seen, ['c', 'a', null]);
    });
  });

  group('updateDocument', () {
    test('replaces in place, keeps order, active and position, and bumps only '
        'the documents revision', () {
      final before = abc().activate('b').recordPosition(pos('b', 8));
      final edited = before
          .byId('b')!
          .copyWith(
            source: '# b edited',
            updatedAt: DateTime.utc(2026, 11, 17),
          );
      final after = before.updateDocument(edited);
      expect(order(after), ['a', 'b', 'c']);
      expect(after.byId('b')!.source, '# b edited');
      expect(after.activeId, 'b');
      expect(after.positions['b']!.blockIndex, 8);
      expect(after.documentsRevision, before.documentsRevision + 1);
      expect(after.readingStateRevision, before.readingStateRevision);
    });

    test('a script-preference change is an update like any other', () {
      final before = abc();
      final after = before.updateDocument(
        before
            .byId('a')!
            .copyWith(
              scriptPreference: DocumentScriptPreference.traditionalChinese,
            ),
      );
      expect(
        after.byId('a')!.scriptPreference,
        DocumentScriptPreference.traditionalChinese,
      );
      expect(after.documentsRevision, before.documentsRevision + 1);
    });

    test('a document that is not open is refused', () {
      expect(() => abc().updateDocument(doc('missing')), throwsArgumentError);
    });

    test('an update that would duplicate a filename is refused', () {
      final renamed = MarkdownDocument(
        id: 'a',
        title: 'a',
        source: 'a',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        sourceName: 'B.md',
      );
      expect(() => abc().updateDocument(renamed), throwsArgumentError);
    });
  });

  group('recordPosition', () {
    test('records per document and bumps only the reading state', () {
      final before = abc();
      final after = before.recordPosition(pos('b', 12, fraction: .25));
      expect(after.positions['b']!.blockIndex, 12);
      expect(after.positions['b']!.fraction, .25);
      expect(after.documentsRevision, before.documentsRevision);
      expect(after.readingStateRevision, before.readingStateRevision + 1);
      expectInvariants(after);
    });

    test('each document keeps its own position', () {
      final session = abc()
          .recordPosition(pos('a', 10))
          .recordPosition(pos('b', 99))
          .activate('b')
          .activate('a');
      expect(session.positions['a']!.blockIndex, 10);
      expect(session.positions['b']!.blockIndex, 99);
    });

    test('a position for a document that is not open is ignored', () {
      final before = abc();
      expect(
        identical(before.recordPosition(pos('missing', 4)), before),
        isTrue,
      );
      final closed = before.close('b').session;
      expect(identical(closed.recordPosition(pos('b', 4)), closed), isTrue);
      expect(closed.positions.containsKey('b'), isFalse);
      final replaced = before.commitBatch(
        replacements: {'a': doc('a2', name: 'A.md')},
        activeId: 'a2',
      );
      expect(identical(replaced.recordPosition(pos('a', 4)), replaced), isTrue);
    });

    test('an unchanged place changes nothing, whenever it was reported', () {
      final before = abc().recordPosition(pos('a', 3, fraction: .5));
      final again = ReadingPosition(
        documentId: 'a',
        blockIndex: 3,
        fraction: .5,
        savedAt: DateTime.utc(2030),
      );
      expect(identical(before.recordPosition(again), before), isTrue);
    });

    test('a later report replaces an earlier one', () {
      final session = abc()
          .recordPosition(pos('a', 3))
          .recordPosition(pos('a', 40));
      expect(session.positions['a']!.blockIndex, 40);
    });
  });

  group('byName (M2)', () {
    test('finds an open document by exact filename only', () {
      final session = abc();
      expect(session.byName('B.md')!.id, 'b');
      expect(session.byName('b.md'), isNull, reason: 'S13-02: exact match');
      expect(session.byName('D.md'), isNull);
    });

    test('pasted documents have no name and are never found', () {
      final session = DocumentSession.empty
          .commitBatch(adds: [doc('p1'), doc('p2')], activeId: 'p1')
          .commitBatch(adds: [doc('p3')], activeId: 'p3');
      expect(session.documents, hasLength(3), reason: 'many null names');
      expect(session.byName(kPastedDocumentLabel), isNull);
      expect(session.byName(''), isNull);
      expectInvariants(session);
    });
  });

  group('revisions are monotonic across a mixed sequence', () {
    test('neither counter ever decreases, and each moves only when its state '
        'does', () {
      var session = DocumentSession.empty;
      final steps = <DocumentSession Function(DocumentSession)>[
        (s) => s.commitBatch(
          adds: [
            doc('a', name: 'A.md'),
            doc('b'),
          ],
          activeId: 'a',
        ),
        (s) => s.recordPosition(pos('a', 1)),
        (s) => s.recordPosition(pos('a', 1)),
        (s) => s.activate('b'),
        (s) => s.activate('b'),
        (s) => s.recordPosition(pos('gone', 1)),
        (s) => s.updateDocument(s.byId('b')!.copyWith(source: 'x')),
        (s) => s.commitBatch(
          replacements: {'a': doc('a2', name: 'A.md')},
          activeId: 'a2',
        ),
        (s) => s.close('b').session,
        (s) => s.close('a2').session,
      ];
      for (final step in steps) {
        final next = step(session);
        expect(
          next.documentsRevision,
          greaterThanOrEqualTo(session.documentsRevision),
        );
        expect(
          next.readingStateRevision,
          greaterThanOrEqualTo(session.readingStateRevision),
        );
        expectInvariants(next);
        session = next;
      }
      expect(session.isEmpty, isTrue);
      expect(session.documentsRevision, 5);
      expect(session.readingStateRevision, 6);
    });
  });

  group('V-1: DocumentIdAllocator', () {
    test('1,000 allocations inside one clock tick are distinct', () {
      final allocator = DocumentIdAllocator(clock: () => 1700000000000000);
      final ids = [for (var i = 0; i < 1000; i++) allocator.allocate()];
      expect(ids.toSet(), hasLength(1000));
    });

    test('a batch inside one clock tick is distinct, and so are later '
        'batches', () {
      final allocator = DocumentIdAllocator(clock: () => 1700000000000000);
      final all = <String>{};
      for (var batch = 0; batch < 40; batch++) {
        final ids = allocator.allocateBatch(25, all);
        expect(ids, hasLength(25));
        all.addAll(ids);
      }
      expect(all, hasLength(1000));
    });

    test('never issues a reserved, restored, suppressed or in-use ID', () {
      const tick = 1700000000000000;
      final allocator = DocumentIdAllocator(clock: () => tick);
      // What a page lifetime has to protect: a document restored from an
      // earlier one (any format, including a legacy plain number), and the ID
      // of a document whose removal was claimed.
      final restoredLegacy = '$tick';
      final restoredV2 = '$tick-0';
      final suppressed = '$tick-1';
      allocator.reserve([restoredLegacy, restoredV2, suppressed]);
      // And documents open now, or allocated for a batch not yet committed.
      final inUse = {'$tick-2', '$tick-3'};
      final pending = allocator.allocateBatch(500, inUse);
      final more = allocator.allocateBatch(500, {...inUse, ...pending});
      final issued = [...pending, ...more];

      expect(issued.toSet(), hasLength(1000));
      for (final forbidden in [
        restoredLegacy,
        restoredV2,
        suppressed,
        ...inUse,
      ]) {
        expect(issued, isNot(contains(forbidden)), reason: forbidden);
      }
      expect(
        issued.first,
        '$tick-4',
        reason: 'the reserved candidates were skipped',
      );
      expect(allocator.isReserved(suppressed), isTrue);
    });

    test('a clock that goes backwards cannot re-issue an earlier ID', () {
      var now = 2000;
      final allocator = DocumentIdAllocator(clock: () => now);
      final early = allocator.allocateBatch(10);
      now = 1000;
      final late = allocator.allocateBatch(10);
      now = 2000;
      final again = allocator.allocateBatch(10);
      expect({...early, ...late, ...again}, hasLength(30));
    });

    test('the real clock: 10,000 back-to-back allocations are distinct', () {
      final allocator = DocumentIdAllocator();
      final ids = <String>{};
      for (var i = 0; i < 10000; i++) {
        ids.add(allocator.allocate(ids));
      }
      expect(ids, hasLength(10000));
    });

    test('allocated IDs pass through fromSource unchanged, and two pastes '
        'get different IDs', () {
      final allocator = DocumentIdAllocator(clock: () => 1);
      final first = MarkdownDocument.fromSource('x', id: allocator.allocate());
      final second = MarkdownDocument.fromSource('x', id: allocator.allocate());
      expect(first.id, '1-0');
      expect(second.id, '1-1');
      expect(first.sourceName, isNull);
      expect(second.sourceName, isNull);
      // Both can be open at once: null names never collide.
      final session = DocumentSession.empty.commitBatch(
        adds: [first, second],
        activeId: first.id,
      );
      expect(session.documents, hasLength(2));
    });

    test('a negative count is refused and zero issues nothing', () {
      final allocator = DocumentIdAllocator();
      expect(() => allocator.allocateBatch(-1), throwsArgumentError);
      expect(allocator.allocateBatch(0), isEmpty);
    });
  });
}
