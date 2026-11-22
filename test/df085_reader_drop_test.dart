// DF-085: dropping Markdown files onto the Reader.
//
// The Reader at root accepts a file drop through the same batch intake as
// Home and Load from file; anything above it (a sheet, a dialog, the narrow
// Search sheet) still makes a drop ineligible. Drops are delivered through the
// production FileDropMount seam, as in test/df020_intake_test.dart. The
// browser-level classification is covered separately by
// test/browser/df020_drop_batch.mjs against the production build.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/document_tabs.dart';
import 'package:markdown_viewer/file_drop.dart';
import 'package:markdown_viewer/file_loader.dart';
import 'package:markdown_viewer/main.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/reader_screen.dart';
import 'package:markdown_viewer/retained_format.dart';
import 'package:markdown_viewer/retention.dart';
import 'package:markdown_viewer/store.dart';

import 'support/fake_storage.dart';

/// Wide enough for the persistent Search pane.
const wide = Size(1280, 900);

/// Tabs, but Search is a modal sheet.
const medium = Size(900, 900);

/// Phone portrait: the Documents switcher and the Search sheet.
const narrow = Size(390, 844);

String longSource(String name) => [
  '# $name',
  for (var i = 0; i < 40; i++) '## $name section $i\n\nParagraph $i of $name.',
].join('\n\n');

MarkdownDocument fileDoc(String id) => MarkdownDocument.fromSource(
  longSource(id.toUpperCase()),
  id: id,
  sourceName: '$id.md',
);

ReadingPosition pos(String id, int block) => ReadingPosition(
  documentId: id,
  blockIndex: block,
  fraction: 0,
  savedAt: DateTime.utc(2026, 11, 22),
);

FileCandidate file(String name, [String? contents]) => FileCandidate(
  name,
  () async => contents ?? '# New $name\n\nLoaded copy of $name.',
);

/// Candidates that count how often they are read.
class CountingBatch {
  CountingBatch(this.names);
  final List<String> names;
  var reads = 0;
  List<FileCandidate> get candidates => [
    for (final name in names)
      FileCandidate(name, () async {
        reads++;
        return '# $name';
      }),
  ];
}

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

ReaderScreen reader(WidgetTester tester) =>
    tester.widget<ReaderScreen>(find.byType(ReaderScreen));

List<String?> tabNames(WidgetTester tester) => [
  for (final d
      in tester.widget<DocumentTabBar>(find.byType(DocumentTabBar)).documents)
    d.sourceName,
];

String? activeTab(WidgetTester tester) =>
    tester.widget<DocumentTabBar>(find.byType(DocumentTabBar)).activeId;

Finder inTabs(Finder finder) =>
    find.descendant(of: find.byType(DocumentTabBar), matching: finder);

String? searchQuery(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller?.text;

const unsupported =
    'Cannot open "notes.rtf". Choose a Markdown file (.md, .markdown or .txt).';

void main() {
  late FakeBackend backend;

  /// The app's own eligibility, as the adapter sees it.
  late bool Function() eligible;

  /// Delivers like the web adapter: only when eligible.
  late void Function(List<FileCandidate>) drop;

  /// The app's drop callback itself, bypassing the adapter's gate.
  late void Function(List<FileCandidate>) onCandidates;

  var launches = 0;

  setUp(() => backend = FakeBackend());
  tearDown(() => pickMarkdownFiles = openMarkdownFiles);

  FileDropLease mount({
    required bool Function() eligible,
    required void Function(bool) onHover,
    required void Function(List<FileCandidate>) onCandidates,
    required void Function(String) onRejected,
  }) {
    _eligible = eligible;
    _onCandidates = onCandidates;
    return FileDropLease(() {});
  }

  void useSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  void seedOn(List<String> ids, {required String active}) {
    backend.data[Store.settingsKey] = jsonEncode(
      const Settings(keepForNextTime: true).toJson(),
    );
    backend.data[Store.documentKey] = encodeDocumentSet([
      for (final id in ids) fileDoc(id),
    ]);
    backend.data[Store.positionKey] = encodeReadingState(active, {
      for (final (i, id) in ids.indexed) id: pos(id, 2 + i * 5),
    });
  }

  Future<void> launch(WidgetTester tester) async {
    await store.init(backend: backend);
    final startup = await retention.resolveStartup();
    await tester.pumpWidget(
      MarkdownViewerApp(
        key: ValueKey('df085-${launches++}'),
        initialSettings: startup.settingsLoad.settings,
        initialDocument: startup.effectivePolicy == RetentionPolicy.on
            ? store.loadDocument()
            : null,
        startup: startup,
        fileDropMount: mount,
      ),
    );
    eligible = _eligible;
    onCandidates = _onCandidates;
    drop = (batch) {
      if (eligible()) onCandidates(batch);
    };
    await settle(tester);
    backend.writes.clear();
  }

  Future<void> loadFromHome(WidgetTester tester, List<FileCandidate> b) async {
    pickMarkdownFiles = () async => b;
    await tester.ensureVisible(find.text('Load from file'));
    await tester.tap(find.text('Load from file'));
    await settle(tester);
  }

  Future<void> continueReading(WidgetTester tester) async {
    await tester.tap(find.text('Continue reading'));
    await settle(tester);
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await settle(tester);
  }

  Future<void> menuAction(WidgetTester tester, String label) async {
    await openMenu(tester);
    await tester.ensureVisible(find.text(label));
    await tester.tap(find.text(label));
    await settle(tester);
    await settle(tester);
  }

  Future<void> dropAndSettle(WidgetTester tester, List<FileCandidate> b) async {
    drop(b);
    await settle(tester);
    await settle(tester);
  }

  void expectOnScreen(WidgetTester tester, Finder finder, Size size) {
    final rect = tester.getRect(finder);
    expect(
      rect.left >= 0 &&
          rect.top >= 0 &&
          rect.right <= size.width &&
          rect.bottom <= size.height,
      isTrue,
      reason: 'inside the viewport: $rect',
    );
  }

  group('Reader drop: accepted at root', () {
    testWidgets('a drop appends in D-2 order, the first new one is active, '
        'nothing is asked, and the Reader stays', (tester) async {
      useSize(tester, medium);
      await launch(tester);
      await loadFromHome(tester, [file('x.md')]);
      expect(eligible(), isTrue, reason: 'the Reader at root is eligible');

      await dropAndSettle(tester, [file('c.md'), file('b.md')]);

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(tabNames(tester), ['x.md', 'b.md', 'c.md']);
      expect(reader(tester).document.sourceName, 'b.md');
      expect(activeTab(tester), reader(tester).document.id);
      expect(reader(tester).sessionPosition, isNull, reason: 'starts at top');
    });

    testWidgets('narrow: a drop works with the Documents switcher', (
      tester,
    ) async {
      useSize(tester, narrow);
      await launch(tester);
      await loadFromHome(tester, [file('a.md')]);
      await dropAndSettle(tester, [file('c.md'), file('b.md')]);
      expect(reader(tester).document.sourceName, 'b.md');
      await openMenu(tester);
      expect(find.text('Documents (3)'), findsOneWidget);
    });

    testWidgets(
      'a matching name asks from the Reader; Cancel changes nothing',
      (tester) async {
        useSize(tester, medium);
        await launch(tester);
        await loadFromHome(tester, [file('a.md', '# Old a'), file('b.md')]);
        final before = [tabNames(tester), activeTab(tester)];
        final source = reader(tester).document.source;

        await dropAndSettle(tester, [file('a.md', '# Newer a'), file('c.md')]);
        expect(find.text('Replace current document?'), findsOneWidget);
        expect(eligible(), isFalse, reason: 'the dialog is above the Reader');
        await tester.tap(find.text('Cancel'));
        await settle(tester);

        expect([tabNames(tester), activeTab(tester)], before);
        expect(reader(tester).document.source, source);
        expect(find.byType(ReaderScreen), findsOneWidget);
        expect(eligible(), isTrue);
      },
    );

    testWidgets('a confirmed replacement from a Reader drop takes the slot', (
      tester,
    ) async {
      useSize(tester, medium);
      await launch(tester);
      await loadFromHome(tester, [file('a.md', '# Old a'), file('b.md')]);
      await dropAndSettle(tester, [file('a.md', '# Newer a')]);
      await tester.tap(find.widgetWithText(FilledButton, 'Replace'));
      await settle(tester);
      await settle(tester);
      expect(tabNames(tester), ['a.md', 'b.md']);
      expect(reader(tester).document.source, '# Newer a');
    });

    testWidgets('under ON a Reader drop is saved, and a relaunch restores the '
        'set, the active document and the other places (D-1)', (tester) async {
      useSize(tester, medium);
      seedOn(['a', 'b'], active: 'b');
      await launch(tester);
      await continueReading(tester);
      expect(reader(tester).document.id, 'b');

      await dropAndSettle(tester, [file('c.md')]);
      expect(tabNames(tester), ['a.md', 'b.md', 'c.md']);
      final active = activeTab(tester);

      await launch(tester);
      await continueReading(tester);
      expect(tabNames(tester), ['a.md', 'b.md', 'c.md']);
      expect(activeTab(tester), active);
      expect(reader(tester).document.sourceName, 'c.md');
      await tester.tap(inTabs(find.text('b.md')));
      await settle(tester);
      expect(reader(tester).sessionPosition?.blockIndex, 7);
    });

    testWidgets('R-3.2: under OFF a Reader drop writes no document or '
        'reading state', (tester) async {
      useSize(tester, medium);
      await launch(tester);
      await loadFromHome(tester, [file('a.md')]);
      backend.writes.clear();
      await dropAndSettle(tester, [file('c.md')]);
      expect(reader(tester).document.sourceName, 'c.md');
      expect(
        backend.writes.where(
          (key) => key == Store.documentKey || key == Store.positionKey,
        ),
        isEmpty,
      );
    });
  });

  group('S-1: wide, Search pane open, valid drop', () {
    testWidgets('the drop is applied, the first new document is active, Search '
        'closes, its query is gone and is not restored, and the other '
        'documents keep their places', (tester) async {
      useSize(tester, wide);
      seedOn(['a', 'b'], active: 'b');
      await launch(tester);
      await continueReading(tester);
      await menuAction(tester, 'Search document');
      await tester.enterText(find.byType(TextField), 'Paragraph');
      await settle(tester);
      expect(eligible(), isTrue, reason: 'the pane is not a route');

      await dropAndSettle(tester, [file('d.md'), file('c.md')]);

      expect(tabNames(tester), ['a.md', 'b.md', 'c.md', 'd.md']);
      expect(reader(tester).document.sourceName, 'c.md');
      expect(find.byType(TextField), findsNothing, reason: 'Search closed');

      await tester.tap(inTabs(find.text('b.md')));
      await settle(tester);
      expect(find.byType(TextField), findsNothing, reason: 'not restored');
      expect(reader(tester).sessionPosition?.blockIndex, 7);
      await tester.tap(inTabs(find.text('a.md')));
      await settle(tester);
      expect(reader(tester).sessionPosition?.blockIndex, 2);

      await menuAction(tester, 'Search document');
      expect(searchQuery(tester), isEmpty, reason: 'the query was cleared');
    });
  });

  group('S-2 / R-3.4: wide, Search pane open, rejected drop', () {
    for (final (label, batch, message) in [
      (
        'an unsupported name',
        [file('plan.md'), file('implementation.md'), file('notes.rtf')],
        unsupported,
      ),
      (
        'an empty .txt',
        [file('plan.md'), file('notes.txt', '  ')],
        '"notes.txt" is empty.',
      ),
      (
        'two files with one name (D-5)',
        [file('x.md'), file('x.md')],
        'Cannot open these files: more than one is named "x.md".',
      ),
    ]) {
      testWidgets('$label: nothing changes, Search and its query stay, and '
          'the message is on screen', (tester) async {
        useSize(tester, wide);
        await launch(tester);
        await loadFromHome(tester, [
          file('a.md', '# A\n\nalpha here'),
          file('b.md', '# B\n\nalpha too'),
        ]);
        final before = [
          tabNames(tester),
          activeTab(tester),
          reader(tester).document.id,
        ];
        await menuAction(tester, 'Search document');
        await tester.enterText(find.byType(TextField), 'alpha');
        await settle(tester);

        await dropAndSettle(tester, batch);

        expect(find.text(message), findsOneWidget);
        expectOnScreen(tester, find.text(message), wide);
        expect([
          tabNames(tester),
          activeTab(tester),
          reader(tester).document.id,
        ], before);
        expect(find.byType(TextField), findsOneWidget, reason: 'Search open');
        expect(searchQuery(tester), 'alpha', reason: 'query unchanged');
      });
    }

    testWidgets('a readable, non-empty .txt is valid and loads (PC-2)', (
      tester,
    ) async {
      useSize(tester, wide);
      await launch(tester);
      await loadFromHome(tester, [file('a.md')]);
      await dropAndSettle(tester, [file('notes.txt', '# Notes')]);
      expect(reader(tester).document.sourceName, 'notes.txt');
    });

    testWidgets('under ON, storage is byte-identical after the rejection', (
      tester,
    ) async {
      useSize(tester, wide);
      seedOn(['a', 'b'], active: 'b');
      await launch(tester);
      await continueReading(tester);
      await menuAction(tester, 'Search document');
      await tester.enterText(find.byType(TextField), 'Paragraph');
      await settle(tester);
      await settle(tester);
      final before = Map<String, String>.of(backend.data);

      await dropAndSettle(tester, [file('c.md'), file('photo.png')]);

      expect(backend.data, before);
      expect(searchQuery(tester), 'Paragraph');
    });
  });

  group('S-3 / S-4: the Search sheet is open, so a drop is ineligible', () {
    for (final size in [narrow, medium]) {
      for (final (label, names) in [
        ('valid', ['c.md']),
        ('invalid', ['c.md', 'notes.rtf']),
      ]) {
        testWidgets('${size.width.toInt()} px, $label batch: nothing is read, '
            'nothing changes, no message, the sheet stays open', (
          tester,
        ) async {
          useSize(tester, size);
          await launch(tester);
          await loadFromHome(tester, [file('a.md', '# A\n\nalpha')]);
          expect(eligible(), isTrue, reason: 'nothing above the Reader yet');
          await menuAction(tester, 'Search document');
          expect(find.byType(TextField), findsOneWidget);
          expect(eligible(), isFalse, reason: 'the Search sheet is a route');

          // Past the adapter's gate, straight into the app's callback: the
          // app re-checks eligibility before anything is read.
          final batch = CountingBatch(names);
          onCandidates(batch.candidates);
          await settle(tester);
          await settle(tester);

          expect(batch.reads, 0);
          expect(find.byType(SnackBar), findsNothing);
          expect(find.byType(TextField), findsOneWidget, reason: 'sheet open');
          expect(reader(tester).document.sourceName, 'a.md');
        });
      }
    }

    testWidgets('Contents and the Reader menu make a drop ineligible too', (
      tester,
    ) async {
      useSize(tester, medium);
      await launch(tester);
      await loadFromHome(tester, [file('a.md', '# A\n\n## One\n\nx')]);
      await menuAction(tester, 'Contents');
      expect(find.text('One'), findsWidgets);
      expect(eligible(), isFalse, reason: 'Contents is a sheet');
      await tester.tapAt(const Offset(10, 10));
      await settle(tester);
      await openMenu(tester);
      expect(eligible(), isFalse, reason: 'the Reader menu is a sheet');
    });
  });

  group('S-5: narrow, Search closed, rejected drop', () {
    testWidgets('the message is inside the viewport and wraps rather than '
        'truncating; nothing changes', (tester) async {
      useSize(tester, narrow);
      await launch(tester);
      await loadFromHome(tester, [file('a.md')]);

      await dropAndSettle(tester, [file('c.md'), file('notes.rtf')]);

      expect(find.text(unsupported), findsOneWidget);
      expectOnScreen(tester, find.byType(SnackBar), narrow);
      final text = tester.getRect(find.text(unsupported));
      final bar = tester.getRect(find.byType(SnackBar));
      expect(text.left >= bar.left && text.right <= bar.right, isTrue);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text(unsupported),
      );
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(reader(tester).document.sourceName, 'a.md');
    });
  });

  group('S-8: the mobile Reader picker, unsupported file', () {
    testWidgets('iOS, 390 px: the batch is rejected with a readable message, '
        'nothing changes, the Reader stays usable', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        useSize(tester, narrow);
        await launch(tester);
        await loadFromHome(tester, [file('a.md')]);
        pickMarkdownFiles = () async => [file('c.md'), file('notes.rtf')];

        await menuAction(tester, 'Load from file');

        expect(find.text(unsupported), findsOneWidget);
        expectOnScreen(tester, find.byType(SnackBar), narrow);
        expect(reader(tester).document.sourceName, 'a.md');
        expect(eligible(), isTrue, reason: 'the Reader is usable again');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('R-3.1: a Reader drop whose replacement removal is not verified', () {
    testWidgets('under ON: the truthful error, the Reader stays, and the set, '
        'the active document and its place are unchanged (E-1)', (
      tester,
    ) async {
      useSize(tester, medium);
      seedOn(['a', 'b', 'd'], active: 'd');
      await launch(tester);
      await continueReading(tester);
      backend.injectWrites[Store.documentKey] = [InjectedOutcome.failed];

      await dropAndSettle(tester, [file('a.md')]);
      await tester.tap(find.widgetWithText(FilledButton, 'Replace'));
      await settle(tester);
      await settle(tester);

      expect(find.textContaining('could not be confirmed'), findsOneWidget);
      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(tabNames(tester), ['a.md', 'b.md', 'd.md']);
      expect(activeTab(tester), 'd');
      expect(reader(tester).sessionPosition?.blockIndex, 12);
    });
  });

  group('R-3.3: a second drop while a Reader drop is reading', () {
    testWidgets('is not delivered, the tabs are inert, and only the first '
        'batch is applied (S10-08)', (tester) async {
      useSize(tester, medium);
      await launch(tester);
      await loadFromHome(tester, [file('a.md'), file('b.md')]);
      final gate = Completer<void>();
      drop([
        FileCandidate('c.md', () async {
          await gate.future;
          return '# C';
        }),
      ]);
      await tester.pump();
      expect(eligible(), isFalse, reason: 'a load is in flight');

      final second = CountingBatch(['z.md']);
      drop(second.candidates);
      onCandidates(second.candidates);
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing, reason: 'ignored silently');
      expect(find.text('Finish the current operation first.'), findsNothing);
      final active = activeTab(tester);
      await tester.tap(inTabs(find.text('b.md')));
      await tester.pump();
      expect(activeTab(tester), active, reason: 'tabs inert during the load');

      gate.complete();
      await settle(tester);
      await settle(tester);
      expect(second.reads, 0);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('Finish the current operation first.'), findsNothing);
      expect(tabNames(tester), ['a.md', 'b.md', 'c.md']);
      expect(reader(tester).document.sourceName, 'c.md');
    });
  });
}

late bool Function() _eligible;
late void Function(List<FileCandidate>) _onCandidates;
