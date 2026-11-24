// DF-086: manual document order. plan.md §4 rows verified here at the
// Flutter level (CP1): the session move, RO-9..RO-12, RO-15 and the append
// part of RO-14, KB-1..KB-4, KB-6, KB-7 and NS-1. Browser evidence for the
// keyboard rows is test/browser/df086_tabs.mjs; Flutter tests alone are not
// evidence that browser keyboard access works (D-005).

import 'dart:convert';
import 'dart:ui' show SemanticsRole, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/document_session.dart';
import 'package:markdown_viewer/document_tabs.dart';
import 'package:markdown_viewer/main.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/reader_screen.dart';
import 'package:markdown_viewer/retained_format.dart';
import 'package:markdown_viewer/retention.dart';
import 'package:markdown_viewer/store.dart';

import 'support/fake_storage.dart';

const wide = Size(1000, 900);
const narrow = Size(390, 844);

MarkdownDocument fileDoc(String id) => MarkdownDocument.fromSource(
  '# ${id.toUpperCase()}\n\nBody of $id.',
  id: id,
  sourceName: '$id.md',
);

ReadingPosition pos(String id, int block) => ReadingPosition(
  documentId: id,
  blockIndex: block,
  fraction: 0,
  savedAt: DateTime.utc(2026, 11, 23),
);

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Finder inTabs(Finder finder) =>
    find.descendant(of: find.byType(DocumentTabBar), matching: finder);

/// The tab labels, left to right.
List<String> tabOrder(WidgetTester tester) => [
  for (final text in tester.widgetList<Text>(inTabs(find.byType(Text))))
    text.data!,
];

String activeId(WidgetTester tester) =>
    tester.widget<ReaderScreen>(find.byType(ReaderScreen)).document.id;

/// The nearest labelled [Semantics] above [context] (as V-16's lookup).
String? labelAbove(BuildContext? context) {
  String? label;
  context?.visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is Semantics && widget.properties.label != null) {
      label = widget.properties.label;
      return false;
    }
    return true;
  });
  return label;
}

String focusedName(WidgetTester tester) {
  final focus = tester.binding.focusManager.primaryFocus;
  final tooltip = focus?.context
      ?.findAncestorWidgetOfExactType<Tooltip>()
      ?.message;
  return tooltip ?? labelAbove(focus?.context) ?? '?';
}

void main() {
  group('DocumentSession.move', () {
    DocumentSession three({String active = 'a'}) => DocumentSession.restored(
      documents: [fileDoc('a'), fileDoc('b'), fileDoc('c')],
      activeId: active,
      positions: {'a': pos('a', 1), 'c': pos('c', 3)},
    );

    List<String> ids(DocumentSession s) => [for (final d in s.documents) d.id];

    test('moves right, left and to first, keeping the others in order', () {
      final s = three();
      expect(ids(s.move('a', 2)), ['b', 'c', 'a']);
      expect(ids(s.move('a', 1)), ['b', 'a', 'c']);
      expect(ids(s.move('c', 0)), ['c', 'a', 'b']);
      expect(ids(s.move('c', 1)), ['a', 'c', 'b']);
    });

    test('changes only the order: active, positions and the reading-state '
        'revision are kept; the documents revision is bumped', () {
      final s = three(active: 'b');
      final moved = s.move('c', 0);
      expect(moved.activeId, 'b');
      expect(moved.positions, s.positions);
      expect(moved.documentsRevision, s.documentsRevision + 1);
      expect(moved.readingStateRevision, s.readingStateRevision);
      expect(
        moved.documents.map((d) => d.source),
        containsAll(s.documents.map((d) => d.source)),
      );
    });

    test('clamps the target, returns the same value for no move, and throws '
        'for a document that is not open', () {
      final s = three();
      expect(ids(s.move('a', 99)), ['b', 'c', 'a']);
      expect(ids(s.move('c', -5)), ['c', 'a', 'b']);
      expect(identical(s.move('b', 1), s), isTrue);
      expect(() => s.move('z', 0), throwsArgumentError);
    });
  });

  group('app', () {
    late FakeBackend backend;
    var launches = 0;

    setUp(() => backend = FakeBackend());

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
        for (final (i, id) in ids.indexed) id: pos(id, i),
      });
    }

    List<String> storedOrder() => [
      for (final d in decodeDocumentKey(
        backend.data[Store.documentKey]!,
      ).documents)
        d.id,
    ];

    String? storedActive() =>
        decodeReadingKey(backend.data[Store.positionKey]!).activeId;

    Future<void> launch(WidgetTester tester) async {
      await store.init(backend: backend);
      final startup = await retention.resolveStartup();
      await tester.pumpWidget(
        MarkdownViewerApp(
          key: ValueKey('df086-${launches++}'),
          initialSettings: startup.settingsLoad.settings,
          initialDocument: startup.effectivePolicy == RetentionPolicy.on
              ? store.loadDocument()
              : null,
          startup: startup,
        ),
      );
      await settle(tester);
    }

    Future<void> continueReading(WidgetTester tester) async {
      await tester.tap(find.text('Continue reading'));
      await settle(tester);
    }

    Future<void> paste(WidgetTester tester, String source) async {
      await tester.ensureVisible(find.text('Paste Markdown'));
      await tester.tap(find.text('Paste Markdown'));
      await settle(tester);
      await tester.enterText(find.byType(TextField), source);
      await settle(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Open'));
      await settle(tester);
    }

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(
        find.byIcon(Icons.more_horiz_rounded),
        warnIfMissed: false,
      );
      await settle(tester);
    }

    Future<void> openMove(WidgetTester tester) async {
      await openMenu(tester);
      await tester.ensureVisible(find.text('Move document'));
      await tester.tap(find.text('Move document'));
      await settle(tester);
      await settle(tester);
    }

    Future<void> move(WidgetTester tester, String action) async {
      await openMove(tester);
      await tester.tap(find.text(action));
      await settle(tester);
    }

    bool enabled(WidgetTester tester, String action) =>
        tester.widget<ListTile>(find.widgetWithText(ListTile, action)).enabled;

    testWidgets('Move document sits after Close document and before Return '
        'to main, and only with two or more documents (UX-3)', (tester) async {
      useSize(tester, wide);
      seedOn(['a', 'b'], active: 'a');
      await launch(tester);
      await continueReading(tester);
      await openMenu(tester);
      final close = tester.getTopLeft(find.text('Close document')).dy;
      final moveTile = tester.getTopLeft(find.text('Move document')).dy;
      final home = tester.getTopLeft(find.text('Return to main')).dy;
      expect(close < moveTile && moveTile < home, isTrue);
      await tester.tapAt(const Offset(10, 10));
      await settle(tester);

      await tester.tap(find.byTooltip('Close b.md'));
      await settle(tester);
      await openMenu(tester);
      expect(find.text('Move document'), findsNothing);
      expect(find.text('Return to main'), findsOneWidget);
    });

    testWidgets('KB-4 / RO-10: wide Move to first, left and right change '
        'the order, keep the moved document active, are stored, and are '
        'restored', (tester) async {
      useSize(tester, wide);
      seedOn(['a', 'b', 'c'], active: 'b');
      await launch(tester);
      await continueReading(tester);
      expect(tabOrder(tester), ['a.md', 'b.md', 'c.md']);

      await openMove(tester);
      expect(find.text('Move to first'), findsOneWidget);
      expect(find.text('Move left'), findsOneWidget);
      expect(find.text('Move right'), findsOneWidget);
      expect(find.text('Move up'), findsNothing);
      await tester.tap(find.text('Move right'));
      await settle(tester);
      expect(tabOrder(tester), ['a.md', 'c.md', 'b.md']);
      expect(activeId(tester), 'b');
      expect(storedOrder(), ['a', 'c', 'b']);
      expect(storedActive(), 'b');

      await move(tester, 'Move left');
      expect(tabOrder(tester), ['a.md', 'b.md', 'c.md']);
      await move(tester, 'Move to first');
      expect(tabOrder(tester), ['b.md', 'a.md', 'c.md']);
      expect(activeId(tester), 'b');
      expect(storedOrder(), ['b', 'a', 'c']);

      // A new page lifetime restores the manual order and the active one.
      await launch(tester);
      await continueReading(tester);
      expect(tabOrder(tester), ['b.md', 'a.md', 'c.md']);
      expect(activeId(tester), 'b');
    });

    testWidgets('an unavailable move is disabled, is still a (disabled) '
        'button to assistive technology, and does nothing', (tester) async {
      final semantics = tester.ensureSemantics();
      useSize(tester, wide);
      seedOn(['a', 'b'], active: 'a');
      await launch(tester);
      await continueReading(tester);
      await openMove(tester);
      expect(enabled(tester, 'Move to first'), isFalse);
      expect(enabled(tester, 'Move left'), isFalse);
      expect(enabled(tester, 'Move right'), isTrue);
      for (final (label, isEnabled) in [
        ('Move to first', false),
        ('Move left', false),
        ('Move right', true),
      ]) {
        final data = tester
            .getSemantics(find.widgetWithText(ListTile, label))
            .getSemanticsData();
        expect(data.label, label);
        expect(data.flagsCollection.isButton, isTrue, reason: label);
        expect(
          data.flagsCollection.isEnabled,
          isEnabled ? Tristate.isTrue : Tristate.isFalse,
          reason: label,
        );
      }
      semantics.dispose();
      await tester.tap(find.text('Move to first'), warnIfMissed: false);
      await settle(tester);
      expect(find.text('Move to first'), findsOneWidget, reason: 'sheet open');
      await tester.tap(find.text('Move right'));
      await settle(tester);
      expect(tabOrder(tester), ['b.md', 'a.md']);
      await openMove(tester);
      expect(enabled(tester, 'Move right'), isFalse);
      expect(enabled(tester, 'Move left'), isTrue);
    });

    testWidgets('NS-1: narrow offers Move up and Move down, and the Documents '
        'sheet shows the new order', (tester) async {
      useSize(tester, narrow);
      seedOn(['a', 'b', 'c'], active: 'a');
      await launch(tester);
      await continueReading(tester);
      expect(find.byType(DocumentTabBar), findsNothing);
      await openMove(tester);
      expect(find.text('Move up'), findsOneWidget);
      expect(find.text('Move down'), findsOneWidget);
      expect(find.text('Move left'), findsNothing);
      expect(enabled(tester, 'Move up'), isFalse);
      await tester.tap(find.text('Move down'));
      await settle(tester);
      expect(activeId(tester), 'a');
      expect(storedOrder(), ['b', 'a', 'c']);

      await openMenu(tester);
      await tester.tap(find.text('Documents (3)'));
      await settle(tester);
      await settle(tester);
      final rows = [
        for (final tile in tester.widgetList<ListTile>(
          find.descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(ListTile),
          ),
        ))
          (tile.title! as Text).data!,
      ];
      expect(rows, ['b.md', 'a.md', 'c.md']);
    });

    testWidgets('RO-11: under OFF a move writes nothing', (tester) async {
      useSize(tester, wide);
      await launch(tester);
      await paste(tester, '# One\n\nFirst.');
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await settle(tester);
      await tester.tap(find.text('Return to main'));
      await settle(tester);
      await settle(tester);
      await paste(tester, '# Two\n\nSecond.');
      expect(tabOrder(tester), ['One', 'Two']);
      backend.writes.clear();
      await move(tester, 'Move to first');
      expect(tabOrder(tester), ['Two', 'One']);
      expect(backend.writes, isNot(contains(Store.documentKey)));
      expect(backend.writes, isNot(contains(Store.positionKey)));
      expect(backend.data.containsKey(Store.documentKey), isFalse);
    });

    testWidgets('RO-12: under ON a failed documents write keeps the new order '
        'and reports the existing message once', (tester) async {
      useSize(tester, wide);
      seedOn(['a', 'b', 'c'], active: 'c');
      await launch(tester);
      await continueReading(tester);
      backend.injectWrites[Store.documentKey] = [InjectedOutcome.failed];
      await move(tester, 'Move to first');
      expect(tabOrder(tester), ['c.md', 'a.md', 'b.md']);
      expect(activeId(tester), 'c');
      expect(
        find.text('Your changes could not be saved in this browser.'),
        findsOneWidget,
      );
      expect(storedOrder(), ['a', 'b', 'c'], reason: 'the write failed');
    });

    testWidgets('RO-14 (append) / RO-15: a document added after a manual '
        'move is appended after the manual order and becomes active', (
      tester,
    ) async {
      useSize(tester, wide);
      seedOn(['a', 'b'], active: 'b');
      await launch(tester);
      await continueReading(tester);
      expect(tabOrder(tester), ['a.md', 'b.md'], reason: 'D-2 load order');
      await move(tester, 'Move to first');
      expect(tabOrder(tester), ['b.md', 'a.md']);
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await settle(tester);
      await tester.tap(find.text('Return to main'));
      await settle(tester);
      await settle(tester);
      await paste(tester, '# Pasted\n\nNew.');
      expect(tabOrder(tester), ['b.md', 'a.md', 'Pasted']);
      expect(storedOrder().sublist(0, 2), ['b', 'a']);
    });

    testWidgets('RO-9: while a close is being verified, Move document and '
        'keyboard activation do not act', (tester) async {
      useSize(tester, wide);
      seedOn(['a', 'b', 'c'], active: 'a');
      await launch(tester);
      await continueReading(tester);
      // Focus the c.md tab by keyboard.
      for (var i = 0; i < 20 && focusedName(tester) != 'c.md'; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(focusedName(tester), 'c.md');

      final gate = backend.stall(Store.positionKey);
      await tester.tap(find.byTooltip('Close b.md'));
      await tester.pump();
      // Busy: Enter and Space on the focused tab do not switch.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(activeId(tester), 'a');
      // Busy: Move document opens nothing and moves nothing.
      await tester.tap(
        find.byIcon(Icons.more_horiz_rounded),
        warnIfMissed: false,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      if (find.text('Move document').evaluate().isNotEmpty) {
        await tester.tap(find.text('Move document'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(find.text('Move to first'), findsNothing);
      expect(tabOrder(tester), ['a.md', 'b.md', 'c.md']);

      gate.complete();
      await settle(tester);
      expect(tabOrder(tester), ['a.md', 'c.md']);
      expect(activeId(tester), 'a');
    });

    testWidgets('KB-1..KB-3: each tab is a focusable tab node; Tab and '
        'Shift+Tab visit tab, close control, next tab in exact reverse; '
        'Space and Enter activate without reordering', (tester) async {
      final semantics = tester.ensureSemantics();
      useSize(tester, wide);
      seedOn(['a', 'b', 'c'], active: 'a');
      await launch(tester);
      await continueReading(tester);

      final tabs = <SemanticsData>[];
      void walk(SemanticsNode node) {
        final data = node.getSemanticsData();
        if (data.role == SemanticsRole.tab) tabs.add(data);
        node.visitChildren((child) {
          walk(child);
          return true;
        });
      }

      walk(tester.getSemantics(find.byType(DocumentTabBar)));
      expect(tabs.map((t) => t.label), ['a.md', 'b.md', 'c.md']);
      for (final tab in tabs) {
        expect(tab.flagsCollection.isFocused, isNot(Tristate.none));
        expect(tab.hasAction(SemanticsAction.focus), isTrue);
      }
      for (final name in ['a.md', 'b.md', 'c.md']) {
        expect(find.bySemanticsLabel('Close $name'), findsOneWidget);
      }

      final forward = <String>[];
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        forward.add(focusedName(tester));
      }
      expect(forward, [
        'a.md',
        'Close a.md',
        'b.md',
        'Close b.md',
        'c.md',
        'Close c.md',
      ]);
      final backward = <String>[];
      for (var i = 0; i < 5; i++) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        backward.add(focusedName(tester));
      }
      expect(backward, ['c.md', 'Close b.md', 'b.md', 'Close a.md', 'a.md']);

      // Focus b.md: Space activates it; then c.md: Enter activates it.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focusedName(tester), 'b.md');
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await settle(tester);
      expect(activeId(tester), 'b');
      expect(focusedName(tester), 'b.md', reason: 'focus stays on the tab');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focusedName(tester), 'c.md');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(activeId(tester), 'c');
      expect(tabOrder(tester), ['a.md', 'b.md', 'c.md'], reason: 'no reorder');
      semantics.dispose();
    });

    testWidgets('KB-6: a keyboard-focused tab draws a 2 px outline; a '
        'pointer-selected one does not', (tester) async {
      useSize(tester, wide);
      seedOn(['a', 'b'], active: 'a');
      await launch(tester);
      await continueReading(tester);

      BorderSide outline(String name) {
        final material = tester.widget<Material>(
          find
              .ancestor(
                of: inTabs(find.text(name)),
                matching: find.byType(Material),
              )
              .first,
        );
        return (material.shape! as RoundedRectangleBorder).side;
      }

      await tester.tap(inTabs(find.text('b.md')));
      await settle(tester);
      expect(outline('b.md'), BorderSide.none);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      for (var i = 0; i < 6 && focusedName(tester) != 'a.md'; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(focusedName(tester), 'a.md');
      expect(outline('a.md').width, 2);
      expect(outline('a.md').style, BorderStyle.solid);
      expect(outline('b.md'), BorderSide.none);
    });

    testWidgets('KB-7 (PC-5): the Reader menu button is a button named '
        '"Reader menu", with no visible change', (tester) async {
      final semantics = tester.ensureSemantics();
      useSize(tester, wide);
      seedOn(['a'], active: 'a');
      await launch(tester);
      await continueReading(tester);
      final button = find.bySemanticsLabel('Reader menu');
      expect(button, findsOneWidget);
      final data = tester.getSemantics(button).getSemanticsData();
      expect(data.flagsCollection.isButton, isTrue);
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      // Nothing visible was added: same icon, no tooltip or text.
      expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);
      expect(find.byTooltip('Reader menu'), findsNothing);
      expect(find.text('Reader menu'), findsNothing);
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await settle(tester);
      expect(find.text('Return to main'), findsOneWidget);
      semantics.dispose();
    });
  });
}
