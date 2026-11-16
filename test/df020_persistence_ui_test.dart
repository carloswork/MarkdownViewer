// DF-020 CP2: persistence through the real app (V-4 UI part, D-1 restore).
//
// The CP2 UI still opens one document at a time, but a page lifetime can start
// with a stored multi-document set. These launch MarkdownViewerApp the way
// main() does over such a set.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/main.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/reader_screen.dart';
import 'package:markdown_viewer/retained_format.dart';
import 'package:markdown_viewer/retention.dart';
import 'package:markdown_viewer/store.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'support/fake_storage.dart';

MarkdownDocument doc(String id) => MarkdownDocument.fromSource(
  '# Title $id\n\nBody of $id.',
  id: id,
  sourceName: '$id.md',
);

ReadingPosition pos(String id, int block) => ReadingPosition(
  documentId: id,
  blockIndex: block,
  fraction: 0,
  savedAt: DateTime.utc(2026, 11, 16),
);

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  late FakeBackend backend;
  var launches = 0;

  void seedTwo() {
    backend.data[Store.settingsKey] = jsonEncode(
      const Settings(keepForNextTime: true).toJson(),
    );
    backend.data[Store.documentKey] = encodeDocumentSet([doc('a'), doc('b')]);
    backend.data[Store.positionKey] = encodeReadingState('b', {
      'a': pos('a', 1),
      'b': pos('b', 2),
    });
  }

  Future<void> launch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await store.init(backend: backend);
    final startup = await retention.resolveStartup();
    await tester.pumpWidget(
      MarkdownViewerApp(
        key: ValueKey('df020-ui-${launches++}'),
        initialSettings: startup.settingsLoad.settings,
        initialDocument: startup.effectivePolicy == RetentionPolicy.on
            ? store.loadDocument()
            : null,
        startup: startup,
      ),
    );
    await settle(tester);
  }

  setUp(() => backend = FakeBackend());

  testWidgets('a stored two-document set restores with its active document '
      'and position, and is shown as saved', (tester) async {
    seedTwo();
    await launch(tester);
    expect(find.text('Saved in this browser'), findsOneWidget);
    await tester.tap(find.text('Continue reading'));
    await settle(tester);
    final reader = tester.widget<ReaderScreen>(find.byType(ReaderScreen));
    expect(reader.document.id, 'b', reason: 'the stored active document');
    expect(reader.sessionPosition?.blockIndex, 2);
  });

  testWidgets('Remove saved documents removes every saved document, verifies '
      'it, closes them all and keeps the choice ON (D-10)', (tester) async {
    seedTwo();
    await launch(tester);
    await tester.ensureVisible(find.text('Settings'));
    await tester.tap(find.text('Settings'));
    await settle(tester);
    expect(find.text('Remove saved documents'), findsOneWidget);
    await tester.ensureVisible(find.text('Remove saved documents'));
    await tester.tap(find.text('Remove saved documents'));
    await settle(tester);
    expect(find.text('Remove saved documents?'), findsOneWidget);
    expect(
      find.textContaining('and 1 other document, and your reading places'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await settle(tester);

    expect(find.text('Removed from this browser.'), findsOneWidget);
    expect(backend.data.containsKey(Store.documentKey), isFalse);
    expect(backend.data.containsKey(Store.positionKey), isFalse);
    expect(store.effectivePolicy, RetentionPolicy.on);
    expect(store.loadSettings().keepForNextTime, isTrue);
    await tester.tap(find.byTooltip('Back'));
    await settle(tester);
    expect(find.text('Continue reading'), findsNothing, reason: 'Home empty');
  });

  testWidgets('a Remove that cannot be verified leaves the documents open', (
    tester,
  ) async {
    seedTwo();
    await launch(tester);
    backend.failDeletes.add(Store.documentKey);
    await tester.ensureVisible(find.text('Settings'));
    await tester.tap(find.text('Settings'));
    await settle(tester);
    await tester.ensureVisible(find.text('Remove saved documents'));
    await tester.tap(find.text('Remove saved documents'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await settle(tester);
    expect(
      find.text('Saved reading data could not be removed.'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Back'));
    await settle(tester);
    expect(find.text('Continue reading'), findsOneWidget);
  });

  group('saved status refreshes on its own when a write lands', () {
    String longSource(String id) => [
      for (var i = 0; i < 40; i++) '## $id section $i\n\nParagraph $i.',
    ].join('\n\n');

    Future<void> readThenReturnHome(WidgetTester tester) async {
      backend.data[Store.documentKey] = encodeDocumentSet([
        MarkdownDocument.fromSource(
          longSource('a'),
          id: 'a',
          sourceName: 'a.md',
        ),
      ]);
      backend.data[Store.positionKey] = encodeReadingState('a', {});
      backend.data[Store.settingsKey] = jsonEncode(
        const Settings(keepForNextTime: true).toJson(),
      );
      await launch(tester);
      expect(find.text('Saved in this browser'), findsOneWidget);
      await tester.tap(find.text('Continue reading'));
      await settle(tester);
      await tester.drag(
        find.byType(ScrollablePositionedList),
        const Offset(0, -1500),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.drag(
        find.byType(ScrollablePositionedList),
        const Offset(0, 40),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await settle(tester);
      await tester.ensureVisible(find.text('Return to main'));
      await tester.tap(find.text('Return to main'));
      await settle(tester);
      await settle(tester);
    }

    for (final succeeds in [true, false]) {
      testWidgets('a delayed reading-state write that '
          '${succeeds ? 'succeeds' : 'fails'} updates Home without '
          'interaction', (tester) async {
        // Held: every position write waits until the test releases it.
        final gate = backend.stall(Store.positionKey);
        await readThenReturnHome(tester);
        expect(
          find.text('Latest changes not saved in this browser'),
          findsOneWidget,
          reason: 'a newer place is not yet stored',
        );
        // Home has settled: nothing on screen is waiting for a frame.
        await tester.pump(const Duration(seconds: 2));
        expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);

        if (!succeeds) backend.failWrites.add(Store.positionKey);
        gate.complete();
        await tester.idle();
        await store.settlePendingOperations();
        await tester.idle();

        expect(
          SchedulerBinding.instance.hasScheduledFrame,
          isTrue,
          reason: 'the landed receipt itself asks for the refresh',
        );
        await tester.pump();
        expect(
          find.text(
            succeeds
                ? 'Saved in this browser'
                : 'Latest changes not saved in this browser',
          ),
          findsOneWidget,
        );
      });
    }
  });
}
