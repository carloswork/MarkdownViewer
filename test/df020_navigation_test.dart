// DF-020 CP3: navigation and Paste through the real app.
//
// V-8u, V-12..V-16, V-20 (UI part) and V-8a (UI path), DF-020 plan §6.2.
// V-17 (switch latency) is the compiled harness tool/df020_switch_timing.dart.

import 'dart:convert';
import 'dart:ui' show SemanticsRole, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/document_tabs.dart';
import 'package:markdown_viewer/main.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/reader_screen.dart';
import 'package:markdown_viewer/retained_format.dart';
import 'package:markdown_viewer/retention.dart';
import 'package:markdown_viewer/store.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'support/fake_storage.dart';

const wide = Size(1000, 900);
const narrow = Size(390, 844);

String longSource(String name) => [
  '# $name',
  for (var i = 0; i < 40; i++)
    '## $name section $i\n\n'
        '${List.filled(60, 'Paragraph $i of $name reflows with width.').join(' ')}',
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
  savedAt: DateTime.utc(2026, 11, 16),
);

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Finder inTabs(Finder finder) =>
    find.descendant(of: find.byType(DocumentTabBar), matching: finder);

ReaderScreen reader(WidgetTester tester) =>
    tester.widget<ReaderScreen>(find.byType(ReaderScreen));

/// The label of the nearest labelled [Semantics] above [context]: for a
/// focused document tab, the tab's own name.
///
/// DF-086 (disclosed V-16 lookup change, plan.md §3.5): the tab's focus node
/// now sits on its label, below the tap and material layers, which add
/// unlabelled [Semantics] widgets of their own. The nearest [Semantics] is
/// therefore no longer the tab's; the nearest labelled one is. Only this
/// lookup changed; the assertions are as accepted.
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

void main() {
  late FakeBackend backend;
  var launches = 0;

  void useSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// Seeds a saved set under ON, as an earlier page lifetime left it.
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
        key: ValueKey('df020-nav-${launches++}'),
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
    final focus = tester.binding.focusManager.primaryFocus;
    if (focus?.debugLabel == 'Reader menu') {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    } else {
      await tester.tap(
        find.byIcon(Icons.more_horiz_rounded),
        warnIfMissed: false,
      );
    }
    await settle(tester);
  }

  Future<void> menuAction(WidgetTester tester, String label) async {
    await openMenu(tester);
    await tester.ensureVisible(find.text(label));
    await tester.tap(find.text(label));
    await settle(tester);
    await settle(tester);
  }

  Future<void> returnHome(WidgetTester tester) async {
    tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first)
      ..clearSnackBars()
      ..removeCurrentSnackBar();
    await tester.pump();
    await menuAction(tester, 'Return to main');
  }

  Future<void> scrollReader(WidgetTester tester, double by) async {
    await tester.drag(find.byType(ScrollablePositionedList), Offset(0, by));
    await tester.pump(const Duration(milliseconds: 700));
  }

  /// The reader's actual reading position, computed exactly as the reader
  /// computes the one it reports: the top block is the lowest-index item still
  /// visible, and the fraction is how far its leading edge is above the
  /// viewport top, in viewport heights. Also returns that distance in pixels.
  ({int block, double fraction, double pixels}) topPosition(
    WidgetTester tester,
  ) {
    final list = tester.widget<ScrollablePositionedList>(
      find.byType(ScrollablePositionedList),
    );
    final positions = list.itemPositionsNotifier!.itemPositions.value;
    ItemPosition? top;
    for (final position in positions) {
      if (position.itemTrailingEdge <= 0) continue;
      if (top == null || position.index < top.index) top = position;
    }
    expect(top, isNotNull, reason: 'the reader shows a block');
    final viewport = tester
        .getSize(find.byType(ScrollablePositionedList))
        .height;
    return (
      block: top!.index,
      fraction: -top.itemLeadingEdge,
      pixels: -top.itemLeadingEdge * viewport,
    );
  }

  setUp(() => backend = FakeBackend());

  // --- V-12 --------------------------------------------------------------------

  group('V-12: Paste adds a tab; Edit applies in place', () {
    testWidgets('a second paste adds a tab and leaves the first unchanged', (
      tester,
    ) async {
      useSize(tester, wide);
      await launch(tester);
      await paste(tester, longSource('First'));
      expect(find.byType(DocumentTabBar), findsNothing, reason: 'one document');
      await returnHome(tester);
      await paste(tester, longSource('Second'));
      expect(find.text('Replace current document?'), findsNothing);
      expect(find.byType(DocumentTabBar), findsOneWidget);
      expect(inTabs(find.text('First')), findsOneWidget);
      expect(inTabs(find.text('Second')), findsOneWidget);
      expect(reader(tester).document.title, 'Second', reason: 'new is active');
    });

    testWidgets('Edit changes the active document in place, keeping the set', (
      tester,
    ) async {
      useSize(tester, wide);
      await launch(tester);
      await paste(tester, '# One\n\nBody.');
      await returnHome(tester);
      await paste(tester, '# Two\n\nBody.');
      final id = reader(tester).document.id;
      await menuAction(tester, 'Edit local copy');
      await settle(tester);
      await tester.enterText(find.byType(TextField), '# Two edited\n\nNew.');
      await settle(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await settle(tester);
      expect(reader(tester).document.id, id, reason: 'same document');
      expect(reader(tester).document.title, 'Two edited');
      expect(inTabs(find.text('One')), findsOneWidget);
      expect(inTabs(find.text('Two edited')), findsOneWidget);
    });
  });

  // --- V-13 --------------------------------------------------------------------

  group('V-13: Search and Contents follow the active document', () {
    testWidgets('a switch clears and closes Search; switching back does not '
        'restore it', (tester) async {
      // The wide condition of the plan, wide enough for the persistent pane
      // (at narrower widths Search is a modal sheet, which blocks switching
      // the way Contents does).
      useSize(tester, const Size(1280, 900));
      await launch(tester);
      await paste(tester, '# Alpha doc\n\nalpha here.');
      await returnHome(tester);
      await paste(tester, '# Beta doc\n\nbeta here.');
      await tester.tap(inTabs(find.text('Alpha doc')));
      await settle(tester);
      await menuAction(tester, 'Search document');
      await tester.enterText(find.byType(TextField), 'alpha');
      await settle(tester);
      expect(find.byType(TextField), findsOneWidget);

      await tester.tap(inTabs(find.text('Beta doc')));
      await settle(tester);
      expect(reader(tester).document.title, 'Beta doc');
      expect(find.byType(TextField), findsNothing, reason: 'Search closed');

      await tester.tap(inTabs(find.text('Alpha doc')));
      await settle(tester);
      expect(find.byType(TextField), findsNothing, reason: 'not restored');
    });

    testWidgets('Contents lists only the active document', (tester) async {
      useSize(tester, wide);
      await launch(tester);
      await paste(tester, '# Alpha doc\n\n## Alpha only\n\nx');
      await returnHome(tester);
      await paste(tester, '# Beta doc\n\n## Beta only\n\nx');
      await menuAction(tester, 'Contents');
      expect(find.text('Beta only'), findsWidgets);
      expect(find.text('Alpha only'), findsNothing);
    });
  });

  // --- V-14 --------------------------------------------------------------------

  group('V-14: the tab bar and D-11 closing', () {
    testWidgets('closing B hides the bar without moving A\'s reading place, '
        'and keeps the Reader', (tester) async {
      useSize(tester, wide);
      seedOn(['a', 'b'], active: 'a');
      await launch(tester);
      await continueReading(tester);
      expect(find.byType(DocumentTabBar), findsOneWidget);
      await scrollReader(tester, -1337);
      await scrollReader(tester, 41);
      final before = topPosition(tester);
      expect(before.fraction, greaterThan(0), reason: 'a mid-block place');
      final state = tester.state(find.byType(ReaderScreen));

      await tester.tap(find.byTooltip('Close b.md'));
      await settle(tester);

      expect(find.byType(DocumentTabBar), findsNothing);
      expect(identical(tester.state(find.byType(ReaderScreen)), state), isTrue);
      final after = topPosition(tester);
      expect(after.block, before.block, reason: 'same top block');
      expect(
        after.pixels,
        closeTo(before.pixels, 0.5),
        reason: 'the same place in it: $before -> $after',
      );
    });

    testWidgets('Close document works with one document and returns Home with '
        'no Continue reading', (tester) async {
      useSize(tester, wide);
      await launch(tester);
      await paste(tester, '# Only\n\nBody.');
      await menuAction(tester, 'Close document');
      expect(find.byType(ReaderScreen), findsNothing);
      expect(find.text('Continue reading'), findsNothing);
    });

    testWidgets('D-11: closing the active document goes right, then left; '
        'closing an inactive one keeps the active one', (tester) async {
      useSize(tester, wide);
      seedOn(['a', 'b', 'c'], active: 'b');
      await launch(tester);
      await continueReading(tester);
      expect(reader(tester).document.id, 'b');
      await tester.tap(find.byTooltip('Close b.md'));
      await settle(tester);
      expect(reader(tester).document.id, 'c', reason: 'right neighbour');
      await tester.tap(find.byTooltip('Close c.md'));
      await settle(tester);
      expect(reader(tester).document.id, 'a', reason: 'left neighbour');
      await returnHome(tester);
      await paste(tester, '# Pasted\n\nx');
      await tester.tap(inTabs(find.text('a.md')));
      await settle(tester);
      await tester.tap(find.byTooltip('Close Pasted'));
      await settle(tester);
      expect(reader(tester).document.id, 'a', reason: 'inactive close');
    });
  });

  // --- V-15 --------------------------------------------------------------------

  group('V-15: crossing the width threshold', () {
    testWidgets('wide → narrow → wide keeps the set, the active document, its '
        'place and the Reader State', (tester) async {
      useSize(tester, wide);
      seedOn(['a', 'b'], active: 'b');
      await launch(tester);
      await continueReading(tester);
      await scrollReader(tester, -1337);
      await scrollReader(tester, 41);
      final state = tester.state(find.byType(ReaderScreen));
      final before = topPosition(tester);
      expect(before.fraction, greaterThan(0), reason: 'a mid-block place');
      // Width only, so the paragraphs reflow while the height stays.
      final narrowSameHeight = Size(narrow.width, wide.height);

      tester.view.physicalSize = narrowSameHeight;
      await settle(tester);
      expect(find.byType(DocumentTabBar), findsNothing);
      expect(identical(tester.state(find.byType(ReaderScreen)), state), isTrue);
      expect(reader(tester).document.id, 'b');
      final narrowed = topPosition(tester);
      expect(narrowed.block, before.block, reason: '$before -> $narrowed');
      expect(
        narrowed.fraction,
        closeTo(before.fraction, 0.01),
        reason: '$before -> $narrowed',
      );
      await openMenu(tester);
      expect(find.text('Documents (2)'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await settle(tester);

      tester.view.physicalSize = wide;
      await settle(tester);
      expect(find.byType(DocumentTabBar), findsOneWidget);
      expect(identical(tester.state(find.byType(ReaderScreen)), state), isTrue);
      final widened = topPosition(tester);
      expect(widened.block, before.block, reason: '$before -> $widened');
      expect(
        widened.fraction,
        closeTo(before.fraction, 0.01),
        reason: '$before -> $widened',
      );
    });

    testWidgets('shrinking within the wide layout keeps the active tab in '
        'view, and the reading place', (tester) async {
      useSize(tester, const Size(1600, 900));
      final ids = [for (var i = 0; i < 10; i++) 'doc$i'];
      seedOn(ids, active: 'doc9');
      await launch(tester);
      await continueReading(tester);
      await scrollReader(tester, -1337);
      await scrollReader(tester, 41);
      final state = tester.state(find.byType(ReaderScreen));
      final before = topPosition(tester);

      bool activeTabVisible() {
        final bar = tester.getRect(find.byType(DocumentTabBar));
        final tab = tester.getRect(inTabs(find.text('doc9.md')));
        return tab.left >= bar.left - 0.5 && tab.right <= bar.right + 0.5;
      }

      expect(activeTabVisible(), isTrue, reason: 'all tabs fit at 1600 px');
      // Still wide (>= 600 px), same document count, same active document:
      // only the strip's width changes, and the tabs now overflow.
      tester.view.physicalSize = const Size(640, 900);
      await settle(tester);
      expect(find.byType(DocumentTabBar), findsOneWidget);
      expect(activeTabVisible(), isTrue, reason: 'the active tab is revealed');
      expect(identical(tester.state(find.byType(ReaderScreen)), state), isTrue);
      final after = topPosition(tester);
      expect(after.block, before.block, reason: '$before -> $after');
      expect(
        after.fraction,
        closeTo(before.fraction, 0.01),
        reason: '$before -> $after',
      );
    });

    testWidgets('narrow: the Documents sheet switches and closes under D-11', (
      tester,
    ) async {
      useSize(tester, narrow);
      seedOn(['a', 'b', 'c'], active: 'a');
      await launch(tester);
      await continueReading(tester);
      await menuAction(tester, 'Documents (3)');
      expect(find.text('b.md'), findsOneWidget);
      await tester.tap(find.text('b.md'));
      await settle(tester);
      expect(reader(tester).document.id, 'b');
      await menuAction(tester, 'Documents (3)');
      await tester.tap(find.byTooltip('Close b.md'));
      await settle(tester);
      expect(reader(tester).document.id, 'c');
    });
  });

  // --- V-16 --------------------------------------------------------------------

  group('V-16: accessibility and busy inertness', () {
    testWidgets('a tab list with selected tabs and labelled close controls', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      useSize(tester, wide);
      seedOn(['a', 'b'], active: 'b');
      await launch(tester);
      await continueReading(tester);

      final bar = tester.getSemantics(find.byType(DocumentTabBar));
      final roles = <SemanticsRole>[];
      final tabs = <SemanticsData>[];
      void walk(SemanticsNode node) {
        final data = node.getSemanticsData();
        roles.add(data.role);
        if (data.role == SemanticsRole.tab) tabs.add(data);
        node.visitChildren((child) {
          walk(child);
          return true;
        });
      }

      walk(bar);
      expect(roles, contains(SemanticsRole.tabBar));
      expect(tabs.map((t) => t.label), ['a.md', 'b.md']);
      expect(tabs.map((t) => t.flagsCollection.isSelected), [
        Tristate.isFalse,
        Tristate.isTrue,
      ]);
      expect(find.bySemanticsLabel('Close a.md'), findsOneWidget);
      expect(find.bySemanticsLabel('Close b.md'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('keyboard: Tab reaches each tab and close control in order, '
        'and Enter activates a tab', (tester) async {
      useSize(tester, wide);
      seedOn(['a', 'b'], active: 'b');
      await launch(tester);
      await continueReading(tester);
      final order = <String>[];
      for (var i = 0; i < 12; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final focus = tester.binding.focusManager.primaryFocus;
        final tooltip = focus?.context
            ?.findAncestorWidgetOfExactType<Tooltip>()
            ?.message;
        order.add(tooltip ?? labelAbove(focus?.context) ?? '?');
      }
      final aTab = order.indexOf('a.md');
      final aClose = order.indexOf('Close a.md');
      final bTab = order.indexOf('b.md');
      final bClose = order.indexOf('Close b.md');
      expect(
        [aTab, aClose, bTab, bClose].every((i) => i >= 0),
        isTrue,
        reason: '$order',
      );
      expect(
        aTab < aClose && aClose < bTab && bTab < bClose,
        isTrue,
        reason: '$order',
      );

      // Focus the a.md tab again and activate it with Enter.
      while (labelAbove(tester.binding.focusManager.primaryFocus?.context) !=
          'a.md') {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(reader(tester).document.id, 'a');
    });

    testWidgets('while a close is being verified, tabs and close controls do '
        'not act', (tester) async {
      useSize(tester, wide);
      seedOn(['a', 'b', 'c'], active: 'a');
      await launch(tester);
      await continueReading(tester);
      final gate = backend.stall(Store.positionKey);
      await tester.tap(find.byTooltip('Close b.md'));
      await tester.pump();
      // Busy: neither a switch nor another close acts.
      await tester.tap(inTabs(find.text('c.md')), warnIfMissed: false);
      await tester.tap(find.byTooltip('Close c.md'), warnIfMissed: false);
      await tester.pump();
      expect(reader(tester).document.id, 'a');
      gate.complete();
      await settle(tester);
      expect(inTabs(find.text('b.md')), findsNothing, reason: 'B closed');
      expect(inTabs(find.text('c.md')), findsOneWidget, reason: 'C untouched');
      expect(reader(tester).document.id, 'a');
    });
  });

  // --- V-8u --------------------------------------------------------------------

  group('V-8u: a close that cannot be verified', () {
    testWidgets('the tab stays, the active document is unchanged, the message '
        'claims no removal, and closing again retries', (tester) async {
      useSize(tester, wide);
      seedOn(['a', 'b'], active: 'b');
      await launch(tester);
      await continueReading(tester);
      backend.injectWrites[Store.positionKey] = [InjectedOutcome.failed];
      await tester.tap(find.byTooltip('Close b.md'));
      await settle(tester);
      expect(inTabs(find.text('b.md')), findsOneWidget, reason: 'tab stays');
      expect(reader(tester).document.id, 'b');
      expect(
        find.text(
          '"b.md" is still open. Its removal from this browser could not be '
          'confirmed.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Removed from this browser'), findsNothing);

      await tester.tap(find.byTooltip('Close b.md'));
      await settle(tester);
      expect(inTabs(find.text('b.md')), findsNothing, reason: 'retry works');
      expect(reader(tester).document.id, 'a');
    });

    testWidgets('busy and the report wait for both restore receipts, even '
        'when the documents restore fails first', (tester) async {
      useSize(tester, wide);
      seedOn(['a', 'b', 'c'], active: 'b');
      await launch(tester);
      await continueReading(tester);
      // The transaction's reading-state write fails; then the documents
      // restore fails at once while the reading-state restore is held.
      backend.injectWrites[Store.positionKey] = [InjectedOutcome.failed];
      backend.injectWrites[Store.documentKey] = [InjectedOutcome.failed];
      final held = backend.stallAfter(Store.positionKey, 1);
      await tester.tap(find.byTooltip('Close b.md'));
      await settle(tester);

      expect(
        find.textContaining('is still open'),
        findsNothing,
        reason: 'no outcome before both receipts settle',
      );
      await tester.tap(inTabs(find.text('a.md')), warnIfMissed: false);
      await tester.tap(find.byTooltip('Close c.md'), warnIfMissed: false);
      await settle(tester);
      expect(reader(tester).document.id, 'b', reason: 'still busy: inert');
      expect(inTabs(find.text('c.md')), findsOneWidget);

      held.complete();
      await settle(tester);
      expect(
        find.text(
          '"b.md" is still open. Its removal from this browser could not be '
          'confirmed. Saved documents in this browser may be out of date.',
        ),
        findsOneWidget,
      );
      await tester.tap(inTabs(find.text('a.md')));
      await settle(tester);
      expect(reader(tester).document.id, 'a', reason: 'released after both');
    });

    testWidgets('when the restore cannot be confirmed either, the message says '
        'so and Home shows out of date', (tester) async {
      useSize(tester, wide);
      seedOn(['a', 'b'], active: 'b');
      await launch(tester);
      await continueReading(tester);
      // Every reading-state write fails: the transaction's first write, the
      // restore, and the place reported on the way Home.
      backend.failWrites.add(Store.positionKey);
      await tester.tap(find.byTooltip('Close b.md'));
      await settle(tester);
      expect(
        find.textContaining(
          'Saved documents in this browser may be out of date.',
        ),
        findsOneWidget,
      );
      await returnHome(tester);
      expect(
        find.text('Latest changes not saved in this browser'),
        findsOneWidget,
      );
      expect(find.text('b.md and 1 other document'), findsOneWidget);
    });
  });

  // --- V-20 (UI) and V-8a (UI path) ----------------------------------------------

  group('V-20 and V-8a through the app', () {
    testWidgets('two pastes have their own IDs and places, are saved under ON '
        'and both restore after a relaunch', (tester) async {
      useSize(tester, wide);
      backend.data[Store.settingsKey] = jsonEncode(
        const Settings(keepForNextTime: true).toJson(),
      );
      await launch(tester);
      await paste(tester, longSource('One'));
      await scrollReader(tester, -900);
      await returnHome(tester);
      await paste(tester, longSource('Two'));
      final ids = [for (final d in store.loadRetained()!.documents) d.id];
      expect(ids.toSet(), hasLength(2));
      await returnHome(tester);
      expect(find.text('Saved in this browser'), findsOneWidget);

      await launch(tester);
      final restored = store.loadRetained()!;
      expect(restored.documents.map((d) => d.id), ids);
      expect(restored.positions[ids.first]?.blockIndex, greaterThan(0));
      expect(
        restored.positions[ids.last]?.blockIndex ?? 0,
        0,
        reason: 'the second paste has its own place, at its top',
      );
      expect(restored.activeId, ids.last);
    });

    testWidgets('a switch alone is restored as the active document', (
      tester,
    ) async {
      useSize(tester, wide);
      seedOn(['a', 'b'], active: 'a');
      await launch(tester);
      await continueReading(tester);
      await tester.tap(inTabs(find.text('b.md')));
      await settle(tester);
      await launch(tester);
      await continueReading(tester);
      expect(reader(tester).document.id, 'b');
    });

    testWidgets('closing the active B in A, B, C restores C active; closing '
        'an inactive one keeps the active one', (tester) async {
      useSize(tester, wide);
      seedOn(['a', 'b', 'c'], active: 'b');
      await launch(tester);
      await continueReading(tester);
      await tester.tap(find.byTooltip('Close b.md'));
      await settle(tester);
      await launch(tester);
      await continueReading(tester);
      expect(reader(tester).document.id, 'c');
      await tester.tap(find.byTooltip('Close a.md'));
      await settle(tester);
      await launch(tester);
      await continueReading(tester);
      expect(reader(tester).document.id, 'c');
    });

    testWidgets('closing the last document leaves nothing saved and an empty '
        'Home', (tester) async {
      useSize(tester, wide);
      seedOn(['a'], active: 'a');
      await launch(tester);
      await continueReading(tester);
      await menuAction(tester, 'Close document');
      expect(find.text('Continue reading'), findsNothing);
      expect(backend.data.containsKey(Store.documentKey), isFalse);
      expect(backend.data.containsKey(Store.positionKey), isFalse);
    });

    testWidgets(
      'Home names the active document and counts the others (S08-01)',
      (tester) async {
        useSize(tester, wide);
        await launch(tester);
        await paste(tester, '# One\n\nx');
        await returnHome(tester);
        await paste(tester, '# Two\n\nx');
        await returnHome(tester);
        await paste(tester, '# Three\n\nx');
        await returnHome(tester);
        expect(
          find.text('Pasted document and 2 other documents'),
          findsOneWidget,
        );
        expect(find.text('Current session only'), findsOneWidget);
      },
    );
  });
}
