// DF-020 CP1, V-2: reading-position precedence.
//
// Within a page lifetime the session's position for a document is the one a
// reader resumes from, whatever storage is doing. A durable write that is
// still pending, or that failed, must never send a document back to an older
// place (DF-020 plan §4.3).
//
// Two levels:
//
//  * The real app, which still opens one document at a time: a stored
//    position older than the session's is never used once the session has
//    moved on, with position writes failing or stalled.
//  * Rapid switching between documents A and B over the real `ReaderScreen`,
//    the real `Store` and a `DocumentSession`, wired the way `main.dart` wires
//    them. The CP1 app cannot open two documents, so a small host stands in for
//    the switching that CP3 adds.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/document_session.dart';
import 'package:markdown_viewer/main.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/reader_screen.dart';
import 'package:markdown_viewer/retention.dart';
import 'package:markdown_viewer/store.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'support/fake_storage.dart';

String longSource(String name) => List.generate(
  40,
  (i) => '## $name section $i\n\nParagraph $i of $name.',
).join('\n\n');

ReadingPosition at(String id, int block) => ReadingPosition(
  documentId: id,
  blockIndex: block,
  fraction: 0,
  savedAt: DateTime.utc(2026, 11, 16),
);

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

ScrollablePositionedList readerList(WidgetTester tester) => tester
    .widget<ScrollablePositionedList>(find.byType(ScrollablePositionedList));

ReaderScreen reader(WidgetTester tester) =>
    tester.widget<ReaderScreen>(find.byType(ReaderScreen));

int? storedBlock(FakeBackend backend) {
  final raw = backend.data[Store.positionKey];
  if (raw == null) return null;
  return ReadingPosition.fromJson(
    jsonDecode(raw) as Map<String, dynamic>,
  ).blockIndex;
}

/// Scrolls the reader and waits out the position debounce, so the place is
/// reported before the test goes on.
Future<void> readOn(WidgetTester tester, double by) async {
  await tester.drag(find.byType(ScrollablePositionedList), Offset(0, by));
  await tester.pump(const Duration(milliseconds: 700));
}

void main() {
  late FakeBackend backend;

  setUp(() => backend = FakeBackend());

  group('the real app', () {
    const id = 'doc-long';
    var launches = 0;

    Future<void> launch(WidgetTester tester) async {
      await store.init(backend: backend);
      final startup = await retention.resolveStartup();
      await tester.pumpWidget(
        MarkdownViewerApp(
          key: ValueKey('v2-launch-${launches++}'),
          initialSettings: startup.settingsLoad.settings,
          initialDocument: startup.effectivePolicy == RetentionPolicy.on
              ? store.loadDocument()
              : null,
          startup: startup,
        ),
      );
      await settle(tester);
    }

    void seedOn({required int storedAt}) {
      backend.data[Store.settingsKey] = jsonEncode(
        const Settings(keepForNextTime: true).toJson(),
      );
      backend.data[Store.documentKey] = jsonEncode(
        MarkdownDocument.fromSource(
          longSource('long'),
          id: id,
          sourceName: 'long.md',
        ).toJson(),
      );
      backend.data[Store.positionKey] = jsonEncode(at(id, storedAt).toJson());
    }

    Future<void> returnHome(WidgetTester tester) async {
      tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first)
        ..clearSnackBars()
        ..removeCurrentSnackBar();
      await tester.pump();
      // Reveal the menu, which reading forward hides.
      await readOn(tester, 40);
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await settle(tester);
      await tester.ensureVisible(find.text('Return to main'));
      await settle(tester);
      await tester.tap(find.text('Return to main'));
      await settle(tester);
      await settle(tester);
    }

    Future<void> continueReading(WidgetTester tester) async {
      await tester.tap(find.text('Continue reading'));
      await settle(tester);
    }

    /// The place the reader was mounted at, which must be the session's.
    int resumedAt(WidgetTester tester) {
      final session = reader(tester).sessionPosition;
      expect(session, isNotNull);
      expect(session!.documentId, id);
      expect(
        readerList(tester).initialScrollIndex,
        session.blockIndex,
        reason: 'the reader starts where the session says',
      );
      return session.blockIndex;
    }

    testWidgets('startup restores the stored place once, under ON', (
      tester,
    ) async {
      seedOn(storedAt: 25);
      await launch(tester);
      await continueReading(tester);
      expect(resumedAt(tester), 25);
    });

    testWidgets('with every position write failing, each return resumes at '
        'the session place, never the older stored one', (tester) async {
      seedOn(storedAt: 25);
      await launch(tester);
      await continueReading(tester);
      expect(resumedAt(tester), 25);

      backend.failWrites.add(Store.positionKey);
      final seen = <int>[25];
      for (final by in [-2500.0, 1200.0, -1800.0]) {
        await readOn(tester, by);
        await returnHome(tester);
        await continueReading(tester);
        final place = resumedAt(tester);
        expect(place, isNot(seen.last), reason: 'reading moved on');
        expect(place, isNot(25), reason: 'the failed write did not win');
        seen.add(place);
        await store.settlePendingOperations();
        expect(storedBlock(backend), 25, reason: 'every write failed');
      }
    });

    testWidgets('with a position write stalled, returning resumes at the '
        'session place, and the write lands later', (tester) async {
      seedOn(storedAt: 25);
      await launch(tester);
      await continueReading(tester);

      final gate = backend.stall(Store.positionKey);
      await readOn(tester, -2500);
      await returnHome(tester);
      await continueReading(tester);
      final place = resumedAt(tester);
      expect(place, isNot(25));
      expect(storedBlock(backend), 25, reason: 'the write is still held');

      // Back and forth again while it is still held. Revealing the menu to
      // return moves the place slightly, so the check is the session place
      // (inside resumedAt) and that it is not the stored one.
      await returnHome(tester);
      await continueReading(tester);
      expect(resumedAt(tester), isNot(25));

      gate.complete();
      await tester.pump();
      await store.settlePendingOperations();
      expect(storedBlock(backend), isNot(25), reason: 'the held write landed');
    });

    testWidgets('under OFF nothing is stored and the session place still '
        'resumes', (tester) async {
      await launch(tester);
      await tester.tap(find.text('Paste Markdown'));
      await settle(tester);
      await tester.enterText(find.byType(TextField), longSource('pasted'));
      await settle(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Open'));
      await settle(tester);

      await readOn(tester, -2500);
      await returnHome(tester);
      await tester.tap(find.text('Continue reading'));
      await settle(tester);

      final session = reader(tester).sessionPosition;
      expect(session, isNotNull);
      expect(session!.blockIndex, greaterThan(0));
      expect(readerList(tester).initialScrollIndex, session.blockIndex);
      await store.settlePendingOperations();
      expect(backend.data.containsKey(Store.positionKey), isFalse);
    });
  });

  group('rapid A→B→A switching', () {
    final a = MarkdownDocument.fromSource(
      longSource('A'),
      id: 'a',
      sourceName: 'A.md',
    );
    final b = MarkdownDocument.fromSource(
      longSource('B'),
      id: 'b',
      sourceName: 'B.md',
    );

    Future<_HostState> pumpHost(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await store.init(backend: backend);
      store.applyResolvedPolicy(RetentionPolicy.on);
      // An older stored place for A that the session has moved past. A reader
      // that consulted storage would land here.
      backend.data[Store.positionKey] = jsonEncode(at('a', 3).toJson());

      await tester.pumpWidget(
        _Host(
          session: DocumentSession.restored(
            documents: [a, b],
            activeId: 'a',
            positions: {'a': at('a', 30), 'b': at('b', 10)},
          ),
        ),
      );
      await settle(tester);
      return tester.state<_HostState>(find.byType(_Host));
    }

    /// Switches, pumping only [frames] frames afterwards: switches arrive
    /// before the outgoing reader's debounced report has fired, so the report
    /// comes from its disposal, after the incoming reader has mounted.
    Future<void> switchTo(
      WidgetTester tester,
      _HostState host,
      String id, {
      int frames = 1,
    }) async {
      host.show(id);
      for (var i = 0; i < frames; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    void expectMountedAtSession(WidgetTester tester, _HostState host) {
      final id = host.session.activeId!;
      expect(reader(tester).document.id, id);
      final session = host.session.positions[id];
      expect(reader(tester).sessionPosition?.blockIndex, session?.blockIndex);
      expect(readerList(tester).initialScrollIndex, session?.blockIndex ?? 0);
    }

    for (final mode in ['failing', 'stalled']) {
      testWidgets('with position writes $mode, each document resumes at its '
          'own session place every time', (tester) async {
        final host = await pumpHost(tester);
        Completer<void>? gate;
        if (mode == 'failing') {
          backend.failWrites.add(Store.positionKey);
        } else {
          gate = backend.stall(Store.positionKey);
        }

        expectMountedAtSession(tester, host);
        expect(readerList(tester).initialScrollIndex, 30);

        // Twenty rapid round trips, reading a little in each document before
        // leaving it, never waiting for a debounce.
        final drags = [-900.0, 600.0, -1500.0, 300.0];
        for (var round = 0; round < 20; round++) {
          final leaving = host.session.activeId!;
          await tester.drag(
            find.byType(ScrollablePositionedList),
            Offset(0, drags[round % drags.length]),
          );
          await tester.pump(const Duration(milliseconds: 50));
          final target = leaving == 'a' ? 'b' : 'a';
          await switchTo(tester, host, target);
          expectMountedAtSession(tester, host);

          // The outgoing reader reported on disposal, after the incoming one
          // mounted, and that report landed against its own ID only.
          await tester.pump(const Duration(milliseconds: 16));
          expect(host.session.positions.keys.toSet(), {'a', 'b'});
          expect(host.session.positions[target]!.documentId, target);
        }

        // Settle, then switch back and forth once more: every mount still
        // uses the session place, and A never returns to its stored block 3.
        await settle(tester);
        for (final id in ['b', 'a', 'b', 'a']) {
          await switchTo(tester, host, id, frames: 3);
          expectMountedAtSession(tester, host);
        }
        expect(readerList(tester).initialScrollIndex, isNot(3));
        expect(host.session.positions['a']!.blockIndex, isNot(3));

        if (mode == 'stalled') {
          expect(
            storedBlock(backend),
            3,
            reason: 'the first write is still held and nothing passed it',
          );
          gate!.complete();
          await tester.pump();
        }
        await store.settlePendingOperations();
        if (mode == 'failing') {
          expect(storedBlock(backend), 3, reason: 'every write failed');
        }
        // Storage never fed back into the session.
        expectMountedAtSession(tester, host);
      });
    }

    testWidgets('a report for a document no longer in the session is '
        'ignored and not stored', (tester) async {
      final host = await pumpHost(tester);
      await tester.drag(
        find.byType(ScrollablePositionedList),
        const Offset(0, -900),
      );
      await tester.pump(const Duration(milliseconds: 50));
      // Close A while its reader is showing and its place is unreported: B
      // takes over (D-11), and A's reader reports on disposal.
      host.close('a');
      await tester.pump();
      await tester.pump();
      expect(host.session.ids, {'b'});
      expect(host.session.positions.keys, ['b']);
      expect(host.reportsIgnored, 1);
      await store.settlePendingOperations();
      expect(storedBlock(backend), 3, reason: 'nothing written for A');
    });
  });
}

/// Stands in for the CP3 switcher: holds a [DocumentSession] and shows its
/// active document in the real [ReaderScreen], with the reader's reports
/// handled exactly as `main.dart` handles them.
class _Host extends StatefulWidget {
  const _Host({required this.session});
  final DocumentSession session;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late DocumentSession session = widget.session;
  int reportsIgnored = 0;

  void show(String id) => setState(() => session = session.activate(id));

  void close(String id) => setState(() => session = session.close(id).session);

  // The same rule as `_MarkdownViewerAppState._onPositionReported`.
  void _onPositionReported(ReadingPosition position) {
    if (!session.contains(position.documentId)) {
      reportsIgnored++;
      return;
    }
    session = session.recordPosition(position);
    unawaited(store.savePosition(position));
  }

  @override
  Widget build(BuildContext context) {
    final document = session.active!;
    return MaterialApp(
      home: ReaderScreen(
        key: ValueKey(
          '${document.id}:${document.updatedAt.microsecondsSinceEpoch}',
        ),
        document: document,
        settings: const Settings(),
        onSettingsChanged: (_) {},
        onScriptPreferenceChanged: (_) {},
        onEdit: () {},
        onLoadFile: () {},
        onReturnHome: () {},
        onPositionChanged: _onPositionReported,
        sessionPosition: session.positions[document.id],
      ),
    );
  }
}
