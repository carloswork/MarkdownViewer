// DF-086: manual document order. plan.md §4 rows verified here at the
// Flutter level: the session move, RO-9..RO-12, RO-15 and the append part of
// RO-14, KB-1..KB-4, KB-6, KB-7 and NS-1 (CP1); the drag rows RO-1..RO-9 and
// RO-13 (CP2). Browser evidence for the
// keyboard rows is test/browser/df086_tabs.mjs; Flutter tests alone are not
// evidence that browser keyboard access works (D-005).

import 'dart:convert';
import 'dart:ui' show PointerDeviceKind, SemanticsRole, Tristate;

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
    if (text.data != null) text.data!,
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

    // --- CP2: drag (plan §3.3, §3.4; RO-1..RO-9, RO-13) ----------------------

    Future<void> drag(
      WidgetTester tester,
      Offset from,
      Offset to, {
      PointerDeviceKind kind = PointerDeviceKind.mouse,
      Duration longPress = Duration.zero,
      Duration hold = Duration.zero,
    }) async {
      final gesture = await tester.startGesture(from, kind: kind);
      await tester.pump();
      if (longPress > Duration.zero) await tester.pump(longPress);
      for (var i = 1; i <= 10; i++) {
        await gesture.moveTo(Offset.lerp(from, to, i / 10)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      for (
        var t = Duration.zero;
        t < hold;
        t += const Duration(milliseconds: 50)
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await gesture.up();
      await settle(tester);
      await settle(tester);
    }

    Offset tabCenter(WidgetTester tester, String label) =>
        tester.getCenter(inTabs(find.text(label)));

    testWidgets('RO-1: mouse-dragging C onto A gives C | A | B, C becomes '
        'active (D-004), and both are stored', (tester) async {
      useSize(tester, wide);
      seedOn(['a', 'b', 'c'], active: 'a');
      await launch(tester);
      await continueReading(tester);
      await drag(tester, tabCenter(tester, 'c.md'), tabCenter(tester, 'a.md'));
      expect(tabOrder(tester), ['c.md', 'a.md', 'b.md']);
      expect(activeId(tester), 'c');
      expect(storedOrder(), ['c', 'a', 'b']);
      expect(storedActive(), 'c');
    });

    testWidgets('RO-2: dragging rightwards takes the target place; the '
        'dragged tab becomes active', (tester) async {
      useSize(tester, wide);
      seedOn(['a', 'b', 'c'], active: 'b');
      await launch(tester);
      await continueReading(tester);
      await drag(tester, tabCenter(tester, 'a.md'), tabCenter(tester, 'c.md'));
      expect(tabOrder(tester), ['b.md', 'c.md', 'a.md']);
      expect(activeId(tester), 'a');
      expect(storedOrder(), ['b', 'c', 'a']);
    });

    testWidgets('RO-3 / RO-4: a click selects without reordering; a drop on '
        'its own place only activates, with no documents write', (
      tester,
    ) async {
      useSize(tester, wide);
      seedOn(['a', 'b', 'c'], active: 'a');
      await launch(tester);
      await continueReading(tester);
      backend.writes.clear();
      await tester.tap(inTabs(find.text('b.md')));
      await settle(tester);
      expect(activeId(tester), 'b');
      expect(tabOrder(tester), ['a.md', 'b.md', 'c.md']);
      expect(backend.writes, isNot(contains(Store.documentKey)));

      final c = tabCenter(tester, 'c.md');
      backend.writes.clear();
      await drag(tester, c, c + const Offset(24, 0));
      expect(activeId(tester), 'c');
      expect(tabOrder(tester), ['a.md', 'b.md', 'c.md']);
      expect(backend.writes, isNot(contains(Store.documentKey)));
      expect(storedActive(), 'c');
    });

    testWidgets('RO-5: a drag released off the strip changes nothing', (
      tester,
    ) async {
      useSize(tester, wide);
      seedOn(['a', 'b', 'c'], active: 'a');
      await launch(tester);
      await continueReading(tester);
      backend.writes.clear();
      await drag(tester, tabCenter(tester, 'c.md'), const Offset(300, 400));
      expect(tabOrder(tester), ['a.md', 'b.md', 'c.md']);
      expect(activeId(tester), 'a');
      expect(backend.writes, isNot(contains(Store.documentKey)));
      expect(storedActive(), 'a');
    });

    testWidgets('RO-6 / RO-7: on touch a swipe scrolls the strip and moves '
        'nothing; a long press then drag reorders and activates', (
      tester,
    ) async {
      useSize(tester, wide);
      final ids = [for (var i = 0; i < 10; i++) 'm$i-a-fairly-long-name'];
      seedOn(ids, active: ids.first);
      await launch(tester);
      await continueReading(tester);
      final scroll = tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byType(DocumentTabBar),
              matching: find.byType(Scrollable),
            ),
          )
          .position;
      expect(scroll.pixels, 0);
      final start = tabCenter(tester, '${ids[2]}.md');
      await drag(
        tester,
        start,
        start - const Offset(300, 0),
        kind: PointerDeviceKind.touch,
      );
      expect(scroll.pixels, greaterThan(200), reason: 'the strip scrolled');
      expect(tabOrder(tester), [for (final id in ids) '$id.md']);
      expect(activeId(tester), ids.first);

      await drag(
        tester,
        tabCenter(tester, '${ids[4]}.md'),
        tabCenter(tester, '${ids[3]}.md'),
        kind: PointerDeviceKind.touch,
        longPress: const Duration(milliseconds: 600),
      );
      expect(
        storedOrder(),
        [...ids]
          ..removeAt(4)
          ..insert(3, ids[4]),
      );
      expect(activeId(tester), ids[4]);
    });

    testWidgets('RO-8: a mouse drag held at the strip edge auto-scrolls, and '
        'the drop lands on the tab under the pointer, revealed and active', (
      tester,
    ) async {
      useSize(tester, wide);
      final ids = [for (var i = 0; i < 10; i++) 'm$i-a-fairly-long-name'];
      seedOn(ids, active: ids.first);
      await launch(tester);
      await continueReading(tester);
      final strip = tester.getRect(find.byType(DocumentTabBar));
      final from = tabCenter(tester, '${ids.first}.md');
      await drag(
        tester,
        from,
        Offset(strip.right - 5, from.dy),
        hold: const Duration(seconds: 15),
      );
      final order = storedOrder();
      final to = order.indexOf(ids.first);
      expect(to, ids.length - 1, reason: 'held until the strip end: $order');
      expect(order, [...ids.skip(1), ids.first]);
      expect(activeId(tester), ids.first);
      final dropped = tester.getRect(inTabs(find.text('${ids.first}.md')));
      expect(dropped.left, greaterThanOrEqualTo(strip.left));
      expect(dropped.right, lessThanOrEqualTo(strip.right));
    });

    testWidgets('RO-9: while a close is being verified, no drag moves or '
        'activates anything', (tester) async {
      useSize(tester, wide);
      seedOn(['a', 'b', 'c'], active: 'a');
      await launch(tester);
      await continueReading(tester);
      final gate = backend.stall(Store.positionKey);
      await tester.tap(find.byTooltip('Close b.md'));
      await tester.pump();
      final c = tabCenter(tester, 'c.md');
      final a = tabCenter(tester, 'a.md');
      final gesture = await tester.startGesture(
        c,
        kind: PointerDeviceKind.mouse,
      );
      for (var i = 1; i <= 10; i++) {
        await gesture.moveTo(Offset.lerp(c, a, i / 10)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pump();
      expect(tabOrder(tester), ['a.md', 'b.md', 'c.md']);
      expect(activeId(tester), 'a');
      gate.complete();
      await settle(tester);
      expect(tabOrder(tester), ['a.md', 'c.md']);
      expect(activeId(tester), 'a');
    });

    testWidgets('RO-13: closing the active tab after a drag goes to its right '
        'neighbour in the new order (D-11)', (tester) async {
      useSize(tester, wide);
      seedOn(['a', 'b', 'c'], active: 'a');
      await launch(tester);
      await continueReading(tester);
      await drag(tester, tabCenter(tester, 'c.md'), tabCenter(tester, 'a.md'));
      expect(tabOrder(tester), ['c.md', 'a.md', 'b.md']);
      await tester.tap(find.byTooltip('Close c.md'));
      await settle(tester);
      expect(tabOrder(tester), ['a.md', 'b.md']);
      expect(activeId(tester), 'a');
    });

    testWidgets('while dragging, the tab list still has exactly its tabs: '
        'the drag image is not in the semantics tree', (tester) async {
      final semantics = tester.ensureSemantics();
      useSize(tester, wide);
      seedOn(['a', 'b', 'c'], active: 'a');
      await launch(tester);
      await continueReading(tester);
      final c = tabCenter(tester, 'c.md');
      final gesture = await tester.startGesture(
        c,
        kind: PointerDeviceKind.mouse,
      );
      for (var i = 1; i <= 5; i++) {
        await gesture.moveTo(c - Offset(20.0 * i, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      final labels = <String>[];
      void walk(SemanticsNode node) {
        final data = node.getSemanticsData();
        if (data.role == SemanticsRole.tab) labels.add(data.label);
        node.visitChildren((child) {
          walk(child);
          return true;
        });
      }

      walk(tester.getSemantics(find.byType(DocumentTabBar)));
      expect(labels, ['a.md', 'b.md', 'c.md']);
      await gesture.up();
      await settle(tester);
      semantics.dispose();
    });
  });
}
