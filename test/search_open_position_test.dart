import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/main.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/reader_screen.dart';
import 'package:markdown_viewer/retention.dart';
import 'package:markdown_viewer/store.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'support/fake_storage.dart';

/// Where the Reader stands after Search opens, and after the layout changes
/// while Search is open.
///
/// The contract: opening or closing Search must not disturb the Reader's
/// current content position unless the user deliberately navigates (selecting
/// a result, Previous/Next). That holds for the visible position, the
/// page-lifetime position and, under Keep for next time, the stored position.
/// Moving between the persistent pane and the sheet while Search is open keeps
/// the position too. Keyboard focus is not part of the contract: opening
/// Search still focuses the Search field.
///
/// Y is the Reader's live top visible block just before the action; X is where
/// the Reader was when it was mounted. "Preserved" means the top visible block
/// after the action is within ±1 block of Y and, when X and Y are more than 2
/// blocks apart, is not X. Every route prints one `DF065 {json}` observation
/// line with the raw positions before it asserts anything.
void main() {
  const wide = Size(1400, 900);
  const narrow = Size(800, 800);
  const k = 10; // mount-time restore section
  const x = 18; // first result section

  setUp(() async {
    await store.init(backend: MemoryBackend());
  });

  // --- Fixture ---------------------------------------------------------------

  const tokens = {18: 'zebraeighteen', 22: 'zebratwentytwo'};

  String fixtureSource() {
    final buffer = StringBuffer('# DF-065 fixture\n\n');
    for (var s = 1; s <= 30; s++) {
      buffer.write('## Part $s\n\n');
      final token = tokens[s];
      if (token != null) buffer.write('Result marker $token here.\n\n');
      for (var p = 0; p < 6; p++) {
        buffer.write(
          '${List.filled(9, 'Paragraph $p of part $s carries ordinary reading '
          'text so that every section is taller than the viewport.').join(' ')}'
          '\n\n',
        );
      }
    }
    return buffer.toString();
  }

  final source = fixtureSource();
  final document = MarkdownDocument.fromSource(source, id: 'df065');

  /// First block index of each `## Part N`, using the same generator and TOC
  /// callback the Reader uses (`reader_screen.dart` `_rebuildBlocksIfNeeded`).
  final sectionStart = <int, int>{};
  MarkdownGenerator(
    linesMargin: const EdgeInsets.symmetric(vertical: 5),
  ).buildWidgets(
    source,
    onTocList: (toc) {
      for (final entry in toc) {
        final text = entry.node.childrenSpan.toPlainText().trim();
        final match = RegExp(r'^Part (\d+)$').firstMatch(text);
        if (match != null) {
          sectionStart[int.parse(match.group(1)!)] = entry.widgetIndex;
        }
      }
    },
  );

  int sectionOf(int block) {
    var found = 0;
    sectionStart.forEach((section, start) {
      if (start <= block && section > found) found = section;
    });
    return found;
  }

  ReadingPosition positionAt(int section) => ReadingPosition(
    documentId: document.id,
    blockIndex: sectionStart[section]!,
    fraction: 0,
    savedAt: DateTime(2026, 9, 26),
  );

  // --- Harness ---------------------------------------------------------------

  void useViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> settle(WidgetTester tester, {int frames = 12}) async {
    await tester.pump();
    for (var frame = 0; frame < frames; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  final reported = <ReadingPosition>[];

  Future<void> pumpReader(
    WidgetTester tester, {
    ReadingPosition? sessionPosition,
  }) async {
    reported.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderScreen(
          document: document,
          settings: const Settings(),
          onSettingsChanged: (_) {},
          onScriptPreferenceChanged: (_) {},
          onEdit: () {},
          onLoadFile: () {},
          onReturnHome: () {},
          onPositionChanged: reported.add,
          sessionPosition: sessionPosition,
        ),
      ),
    );
    await settle(tester);
  }

  State listState(WidgetTester tester) =>
      tester.state(find.byType(ScrollablePositionedList));

  List<ItemPosition> visibleItems(WidgetTester tester) {
    final list = tester.widget<ScrollablePositionedList>(
      find.byType(ScrollablePositionedList),
    );
    final items =
        list.itemPositionsNotifier!.itemPositions.value
            .where((p) => p.itemLeadingEdge < 1 && p.itemTrailingEdge > 0)
            .toList()
          ..sort((a, b) => a.index.compareTo(b.index));
    return items;
  }

  int topBlock(WidgetTester tester) => visibleItems(tester).first.index;

  bool locatorAttached() => find
      .byKey(const ValueKey('active-search-locator'))
      .evaluate()
      .isNotEmpty;

  Map<String, Object?> snapshot(WidgetTester tester) => {
    'topBlock': topBlock(tester),
    'topSection': sectionOf(topBlock(tester)),
    'pane': find.byKey(const ValueKey('search-pane')).evaluate().isNotEmpty,
    'sheet': find.byKey(const ValueKey('search-sheet')).evaluate().isNotEmpty,
    'focus': tester.binding.focusManager.primaryFocus?.debugLabel,
  };

  void record(String route, Map<String, Object?> data) {
    debugPrint('DF065 ${jsonEncode({'route': route, ...data})}');
  }

  /// The DF-065 criterion: within ±1 block of Y, and not X when X and Y are
  /// more than 2 blocks apart.
  void expectPreserved(Map y, Map post, {required int xBlock}) {
    final yBlock = y['topBlock'] as int;
    final postBlock = post['topBlock'] as int;
    expect(
      (postBlock - yBlock).abs(),
      lessThanOrEqualTo(1),
      reason: 'within ±1 block of Y ($yBlock), got $postBlock',
    );
    if ((yBlock - xBlock).abs() > 2) {
      expect(postBlock, isNot(xBlock), reason: 'must not land on X');
    }
  }

  /// Same criterion, applied to a reported or stored block.
  void expectBlockPreserved(Map y, int? block, {required int xBlock}) {
    expect(block, isNotNull);
    expectPreserved(y, {'topBlock': block}, xBlock: xBlock);
  }

  /// A deliberate manual Reader scroll: a slow touch drag on the Reader region.
  Future<void> manualScroll(WidgetTester tester, double dy) async {
    await tester.timedDrag(
      find.byKey(const ValueKey('reader-region')),
      Offset(0, dy),
      const Duration(milliseconds: 800),
    );
    await settle(tester);
  }

  /// Scrolls until [done] holds for the top visible block.
  Future<void> scrollUntil(
    WidgetTester tester,
    bool Function(int) done,
    double dy,
  ) async {
    for (var i = 0; i < 80 && !done(topBlock(tester)); i++) {
      await manualScroll(tester, dy);
    }
  }

  Future<void> afterDebounce(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 600));

  Future<void> resize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    await settle(tester, frames: 20);
  }

  Future<void> ctrlF(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
  }

  Future<void> metaF(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await settle(tester);
  }

  /// `...` → `Search document`. The menu button auto-hides after a downward
  /// scroll, so it is activated from the keyboard when it has focus (it
  /// autofocuses), which does not scroll the Reader.
  Future<void> menuSearch(WidgetTester tester) async {
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
    await tester.tap(find.text('Search document'));
    await settle(tester);
  }

  final opens = <String, Future<void> Function(WidgetTester)>{
    'ctrlF': ctrlF,
    'metaF': metaF,
    'menu': menuSearch,
  };

  Future<void> query(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const ValueKey('search-field')), text);
    await tester.pump(const Duration(milliseconds: 151));
    await settle(tester);
  }

  Future<void> closePane(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('search-close')));
    await settle(tester);
  }

  int? lastReportedBlock() =>
      reported.isEmpty ? null : reported.last.blockIndex;

  // --- AC1 / AC2: wide open preserves Y (discriminating) ---------------------

  for (final entry in opens.entries) {
    for (final restore in const <int?>[null, k]) {
      testWidgets(
        'AC1 wide ${entry.key} open preserves Y '
        '(restore ${restore == null ? 'none' : 'Part $restore'})',
        (tester) async {
          useViewport(tester, wide);
          await pumpReader(
            tester,
            sessionPosition: restore == null ? null : positionAt(restore),
          );
          final xBlock = restore == null ? 0 : sectionStart[restore]!;
          await manualScroll(tester, -2400);
          await manualScroll(tester, -2400);
          await afterDebounce(tester);
          final atY = snapshot(tester);
          await entry.value(tester);
          final afterOpen = snapshot(tester);
          await afterDebounce(tester);
          final reportedAfterOpen = lastReportedBlock();
          record('AC1-wide-${entry.key}-${restore ?? 'none'}', {
            'xBlock': xBlock,
            'Y': atY,
            'afterOpen': afterOpen,
            'reportedAfterOpen': reportedAfterOpen,
          });
          expect(afterOpen['pane'], isTrue, reason: 'precondition: pane');
          expect(
            ((atY['topBlock'] as int) - xBlock).abs(),
            greaterThan(2),
            reason: 'precondition: Y is far from X',
          );
          expectPreserved(atY, afterOpen, xBlock: xBlock);
          // AC2: the page-lifetime report follows Y, not X.
          expectBlockPreserved(atY, reportedAfterOpen, xBlock: xBlock);
        },
      );
    }
  }

  testWidgets('AC1 wide open far below the list start (S1 shape)', (
    tester,
  ) async {
    useViewport(tester, wide);
    await pumpReader(tester);
    await scrollUntil(tester, (b) => b >= 150, -700);
    await afterDebounce(tester);
    final atY = snapshot(tester);
    await ctrlF(tester);
    final afterOpen = snapshot(tester);
    await afterDebounce(tester);
    record('AC1-S1-far', {
      'Y': atY,
      'afterOpen': afterOpen,
      'reportedAfterOpen': lastReportedBlock(),
    });
    expectPreserved(atY, afterOpen, xBlock: 0);
    expectBlockPreserved(atY, lastReportedBlock(), xBlock: 0);
  });

  testWidgets('AC1 wide open far above the restore (S2 shape)', (
    tester,
  ) async {
    useViewport(tester, wide);
    await pumpReader(tester, sessionPosition: positionAt(20));
    final xBlock = sectionStart[20]!;
    await scrollUntil(tester, (b) => b <= 20, 700);
    await afterDebounce(tester);
    final atY = snapshot(tester);
    await ctrlF(tester);
    final afterOpen = snapshot(tester);
    await afterDebounce(tester);
    record('AC1-S2-far-up', {
      'xBlock': xBlock,
      'Y': atY,
      'afterOpen': afterOpen,
      'reportedAfterOpen': lastReportedBlock(),
    });
    expectPreserved(atY, afterOpen, xBlock: xBlock);
    expectBlockPreserved(atY, lastReportedBlock(), xBlock: xBlock);
  });

  // --- AC3 / AC6: narrow sheet open and focus (controls) ---------------------

  for (final entry in {'ctrlF': ctrlF, 'menu': menuSearch}.entries) {
    testWidgets('AC3 narrow ${entry.key} open keeps Y and the list State', (
      tester,
    ) async {
      useViewport(tester, narrow);
      await pumpReader(tester, sessionPosition: positionAt(k));
      await manualScroll(tester, -2400);
      await manualScroll(tester, -2400);
      final atY = snapshot(tester);
      final before = listState(tester);
      await entry.value(tester);
      final afterOpen = snapshot(tester);
      final same = identical(before, listState(tester));
      record('AC3-narrow-${entry.key}', {
        'Y': atY,
        'afterOpen': afterOpen,
        'sameListState': same,
      });
      expect(afterOpen['sheet'], isTrue, reason: 'precondition: sheet');
      expect(same, isTrue);
      expectPreserved(atY, afterOpen, xBlock: sectionStart[k]!);
      // AC6: opening focuses the Search field.
      expect(afterOpen['focus'], 'Search field');
    });
  }

  for (final entry in opens.entries) {
    testWidgets('AC6 wide ${entry.key} open focuses the Search field', (
      tester,
    ) async {
      useViewport(tester, wide);
      await pumpReader(tester);
      await entry.value(tester);
      final afterOpen = snapshot(tester);
      record('AC6-wide-${entry.key}', {'afterOpen': afterOpen});
      expect(afterOpen['pane'], isTrue);
      expect(afterOpen['focus'], 'Search field');
    });
  }

  testWidgets('AC3 wide Ctrl+F with the pane already open changes focus only', (
    tester,
  ) async {
    useViewport(tester, wide);
    await pumpReader(tester, sessionPosition: positionAt(k));
    await ctrlF(tester);
    await manualScroll(tester, -2400);
    await manualScroll(tester, -2400);
    final atY = snapshot(tester);
    final before = listState(tester);
    await ctrlF(tester);
    final after = snapshot(tester);
    final same = identical(before, listState(tester));
    record('AC3-O8-refocus', {
      'Y': atY,
      'afterSecondCtrlF': after,
      'sameListState': same,
    });
    expect(same, isTrue);
    expect(after['topBlock'], atY['topBlock']);
    expect(after['focus'], 'Search field');
  });

  // --- AC5: intentional navigation still moves the Reader (controls) ---------

  testWidgets('AC5 result selection, Next and Previous move the Reader', (
    tester,
  ) async {
    useViewport(tester, wide);
    await pumpReader(tester);
    await ctrlF(tester);
    await query(tester, 'zebra');
    await tester.tap(find.byKey(const ValueKey('search-result-0')));
    await settle(tester);
    final atFirst = snapshot(tester);
    await tester.tap(find.byKey(const ValueKey('search-next')));
    await settle(tester);
    final atNext = snapshot(tester);
    await tester.tap(find.byKey(const ValueKey('search-previous')));
    await settle(tester);
    final atPrevious = snapshot(tester);
    await closePane(tester);
    final afterClose = snapshot(tester);
    record('AC5-navigation', {
      'first': atFirst,
      'next': atNext,
      'previous': atPrevious,
      'afterClose': afterClose,
    });
    bool shows(int section) =>
        visibleItems(tester).any((p) => p.index == sectionStart[section]);
    expect(atFirst['topSection'], anyOf(x - 1, x));
    expect(atNext['topSection'], anyOf(21, 22));
    expect(atPrevious['topSection'], anyOf(x - 1, x));
    // Close after result navigation keeps the result area (DF-063).
    expect(shows(x), isTrue);
    expect(
      ((afterClose['topBlock'] as int) - (atPrevious['topBlock'] as int)).abs(),
      lessThanOrEqualTo(2),
    );
  });

  // --- AC9: closed-Search crossings keep the list (control) ------------------

  testWidgets('AC9 closed-Search breakpoint crossings keep the list State', (
    tester,
  ) async {
    useViewport(tester, wide);
    await pumpReader(tester, sessionPosition: positionAt(k));
    await manualScroll(tester, -2400);
    await manualScroll(tester, -2400);
    final atY = snapshot(tester);
    final before = listState(tester);
    await resize(tester, narrow);
    final atNarrow = snapshot(tester);
    final sameNarrow = identical(before, listState(tester));
    await resize(tester, wide);
    final atWide = snapshot(tester);
    final sameWide = identical(before, listState(tester));
    record('AC9-closed-crossings', {
      'Y': atY,
      'afterNarrow': atNarrow,
      'sameAfterNarrow': sameNarrow,
      'afterWide': atWide,
      'sameAfterWide': sameWide,
    });
    expect(sameNarrow, isTrue);
    expect(sameWide, isTrue);
  });

  // --- AC7: crossings while Search is open (discriminating) ------------------

  testWidgets('AC7 wide → narrow with the pane open preserves Y', (
    tester,
  ) async {
    useViewport(tester, wide);
    await pumpReader(tester, sessionPosition: positionAt(k));
    final xBlock = sectionStart[k]!;
    await ctrlF(tester);
    // Y is set with the pane already open, so the open itself cannot have
    // put the Reader there.
    await manualScroll(tester, -2400);
    await manualScroll(tester, -2400);
    await afterDebounce(tester);
    final atY = snapshot(tester);
    await resize(tester, narrow);
    final afterNarrow = snapshot(tester);
    await afterDebounce(tester);
    record('AC7-W2N', {
      'xBlock': xBlock,
      'Y': atY,
      'afterNarrow': afterNarrow,
      'reportedAfterNarrow': lastReportedBlock(),
    });
    expect(atY['pane'], isTrue, reason: 'precondition: pane open at Y');
    expect(
      ((atY['topBlock'] as int) - xBlock).abs(),
      greaterThanOrEqualTo(3),
      reason: 'precondition: Y is at least 3 blocks from X',
    );
    expectPreserved(atY, afterNarrow, xBlock: xBlock);
    expectBlockPreserved(atY, lastReportedBlock(), xBlock: xBlock);
  });

  testWidgets('AC7 narrow → wide with the sheet open preserves Y', (
    tester,
  ) async {
    useViewport(tester, narrow);
    await pumpReader(tester, sessionPosition: positionAt(k));
    final xBlock = sectionStart[k]!;
    // The sheet covers the Reader, so Y is set just before it opens; the
    // narrow open keeps Y (AC3), which this route also checks.
    await manualScroll(tester, -2400);
    await manualScroll(tester, -2400);
    await afterDebounce(tester);
    final beforeSheet = snapshot(tester);
    await menuSearch(tester);
    final atY = snapshot(tester);
    await resize(tester, wide);
    final afterWide = snapshot(tester);
    await afterDebounce(tester);
    record('AC7-N2W', {
      'xBlock': xBlock,
      'beforeSheet': beforeSheet,
      'Y': atY,
      'afterWide': afterWide,
      'reportedAfterWide': lastReportedBlock(),
    });
    expect(atY['sheet'], isTrue, reason: 'precondition: sheet open at Y');
    expect(atY['topBlock'], beforeSheet['topBlock']);
    expect(
      ((atY['topBlock'] as int) - xBlock).abs(),
      greaterThanOrEqualTo(3),
      reason: 'precondition: Y is at least 3 blocks from X',
    );
    expect(afterWide['pane'], isTrue);
    expectPreserved(atY, afterWide, xBlock: xBlock);
    expectBlockPreserved(atY, lastReportedBlock(), xBlock: xBlock);
  });

  testWidgets('AC7 far crossings both ways with the pane open (S3 shape)', (
    tester,
  ) async {
    useViewport(tester, wide);
    await pumpReader(tester);
    await ctrlF(tester);
    await scrollUntil(tester, (b) => b >= 150, -700);
    final atY = snapshot(tester);
    await resize(tester, narrow);
    final afterNarrow = snapshot(tester);
    await resize(tester, wide);
    final afterWide = snapshot(tester);
    await afterDebounce(tester);
    record('AC7-S3-far', {
      'Y': atY,
      'afterNarrow': afterNarrow,
      'afterWide': afterWide,
      'reportedAfterWide': lastReportedBlock(),
    });
    expectPreserved(atY, afterNarrow, xBlock: 0);
    expectPreserved(atY, afterWide, xBlock: 0);
    expectBlockPreserved(atY, lastReportedBlock(), xBlock: 0);
  });

  // --- S5: locator and focus after crossings (characterization only) --------

  testWidgets('S5 result selected, then wide → narrow → wide', (tester) async {
    useViewport(tester, wide);
    await pumpReader(tester);
    await ctrlF(tester);
    await query(tester, tokens[x]!);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester, frames: 20);
    final atResult = {...snapshot(tester), 'locator': locatorAttached()};
    await resize(tester, const Size(1000, 800));
    final afterNarrow = {...snapshot(tester), 'locator': locatorAttached()};
    await resize(tester, wide);
    final afterWide = {...snapshot(tester), 'locator': locatorAttached()};
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('search-field')),
    );
    record('S5-result-crossings', {
      'resultBlock': sectionStart[x],
      'atResult': atResult,
      'afterNarrow': afterNarrow,
      'afterWide': afterWide,
      'queryAfterWide': field.controller?.text,
      'resultRows': find
          .byKey(const ValueKey('search-result-0'))
          .evaluate()
          .length,
    });
    // Recorded, not asserted: the locator/focus facet belongs to DF-056. The
    // only check is that the route really reached the result.
    expect(atResult['locator'], isTrue, reason: 'precondition: at result');
  });

  // --- AC1 / AC2 / AC7 through the full app: session and stored layers ------

  group('full app', () {
    late FakeBackend backend;
    var launches = 0;

    Future<void> launch(WidgetTester tester) async {
      await store.init(backend: backend);
      final startup = await retention.resolveStartup();
      await tester.pumpWidget(
        MarkdownViewerApp(
          key: ValueKey('df065-launch-${launches++}'),
          initialSettings: startup.settingsLoad.settings,
          initialDocument: startup.effectivePolicy == RetentionPolicy.on
              ? store.loadDocument()
              : null,
          startup: startup,
        ),
      );
      await settle(tester);
    }

    void seedOn({ReadingPosition? position}) {
      backend.data[Store.settingsKey] = jsonEncode(
        const Settings(keepForNextTime: true).toJson(),
      );
      backend.data[Store.documentKey] = jsonEncode(document.toJson());
      if (position != null) {
        backend.data[Store.positionKey] = jsonEncode(position.toJson());
      }
    }

    int? storedBlock() {
      final raw = backend.data[Store.positionKey];
      if (raw == null) return null;
      return ReadingPosition.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      ).blockIndex;
    }

    Future<void> settleStore(WidgetTester tester) async {
      await afterDebounce(tester);
      await store.settlePendingOperations();
    }

    setUp(() => backend = FakeBackend());

    Future<void> continueReading(WidgetTester tester) async {
      await tester.tap(find.text('Continue reading'));
      await settle(tester);
    }

    Future<void> returnHome(WidgetTester tester) async {
      // Reveal the auto-hidden menu without a Reader scroll: the menu
      // autofocuses, so activate it from the keyboard.
      final focus = tester.binding.focusManager.primaryFocus;
      if (focus?.debugLabel != 'Reader menu') {
        await tester.tap(
          find.byIcon(Icons.more_horiz_rounded),
          warnIfMissed: false,
        );
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      }
      await settle(tester);
      await tester.ensureVisible(find.text('Return to main'));
      await tester.tap(find.text('Return to main'));
      await settle(tester);
    }

    for (final entry in {'ctrlF': ctrlF, 'menu': menuSearch}.entries) {
      testWidgets(
        'AC1+AC2 ${entry.key} under ON: open keeps Y visible and stored, '
        'and a relaunch resumes at Y',
        (tester) async {
          useViewport(tester, wide);
          seedOn(position: positionAt(k));
          final xBlock = sectionStart[k]!;
          await launch(tester);
          await continueReading(tester);
          final resumed = snapshot(tester);
          await manualScroll(tester, -2400);
          await manualScroll(tester, -2400);
          await settleStore(tester);
          final atY = snapshot(tester);
          final storedAtY = storedBlock();
          await entry.value(tester);
          final afterOpen = snapshot(tester);
          await settleStore(tester);
          final storedAfterOpen = storedBlock();
          await closePane(tester);
          await settleStore(tester);
          final afterClose = snapshot(tester);
          final storedAfterClose = storedBlock();
          await launch(tester);
          await continueReading(tester);
          final relaunched = snapshot(tester);
          record('AC2-ON-${entry.key}', {
            'xBlock': xBlock,
            'resumed': resumed,
            'Y': atY,
            'storedAtY': storedAtY,
            'afterOpen': afterOpen,
            'storedAfterOpen': storedAfterOpen,
            'afterClose': afterClose,
            'storedAfterClose': storedAfterClose,
            'afterRelaunchContinue': relaunched,
          });
          expect(resumed['topBlock'], xBlock, reason: 'precondition: at X');
          expectBlockPreserved(atY, storedAtY, xBlock: xBlock);
          expectPreserved(atY, afterOpen, xBlock: xBlock);
          expectBlockPreserved(atY, storedAfterOpen, xBlock: xBlock);
          expectBlockPreserved(atY, storedAfterClose, xBlock: xBlock);
          expectPreserved(atY, relaunched, xBlock: xBlock);
        },
      );
    }

    for (final entry in {'ctrlF': ctrlF, 'menu': menuSearch}.entries) {
      testWidgets(
        'AC1+AC2 ${entry.key} under default OFF after Home → Continue: '
        'open keeps Y and the session position follows it',
        (tester) async {
          useViewport(tester, wide);
          await launch(tester);
          await tester.ensureVisible(find.text('Paste Markdown'));
          await tester.tap(find.text('Paste Markdown'));
          await settle(tester);
          await tester.enterText(find.byType(TextField), source);
          await settle(tester);
          await tester.tap(find.widgetWithText(TextButton, 'Open'));
          await settle(tester);
          await manualScroll(tester, -2400);
          await manualScroll(tester, -2400);
          await afterDebounce(tester);
          await returnHome(tester);
          await continueReading(tester);
          // This Reader mount starts here: X.
          final resumedAtX = snapshot(tester);
          final xBlock = resumedAtX['topBlock'] as int;
          await manualScroll(tester, -2400);
          await manualScroll(tester, -2400);
          await afterDebounce(tester);
          final atY = snapshot(tester);
          await entry.value(tester);
          final afterOpen = snapshot(tester);
          await afterDebounce(tester);
          await closePane(tester);
          await afterDebounce(tester);
          await returnHome(tester);
          await continueReading(tester);
          final resumed = snapshot(tester);
          record('AC2-OFF-${entry.key}', {
            'X': resumedAtX,
            'Y': atY,
            'afterOpen': afterOpen,
            'afterCloseThenHomeContinue': resumed,
            'storedBlock': storedBlock(),
          });
          expect(
            ((atY['topBlock'] as int) - xBlock).abs(),
            greaterThan(2),
            reason: 'precondition: Y is far from X',
          );
          expectPreserved(atY, afterOpen, xBlock: xBlock);
          expectPreserved(atY, resumed, xBlock: xBlock);
          expect(storedBlock(), isNull, reason: 'OFF stores nothing');
        },
      );
    }

    for (final toNarrow in const [true, false]) {
      final name = toNarrow ? 'wide → narrow' : 'narrow → wide';
      testWidgets('AC7 $name with Search open under ON keeps Y stored', (
        tester,
      ) async {
        useViewport(tester, toNarrow ? wide : narrow);
        seedOn(position: positionAt(k));
        final xBlock = sectionStart[k]!;
        await launch(tester);
        await continueReading(tester);
        if (toNarrow) {
          await ctrlF(tester);
          await manualScroll(tester, -2400);
          await manualScroll(tester, -2400);
        } else {
          await manualScroll(tester, -2400);
          await manualScroll(tester, -2400);
          await menuSearch(tester);
        }
        await settleStore(tester);
        final atY = snapshot(tester);
        final storedAtY = storedBlock();
        await resize(tester, toNarrow ? narrow : wide);
        final afterCrossing = snapshot(tester);
        await settleStore(tester);
        final storedAfterCrossing = storedBlock();
        record('AC7-ON-${toNarrow ? 'W2N' : 'N2W'}', {
          'xBlock': xBlock,
          'Y': atY,
          'storedAtY': storedAtY,
          'afterCrossing': afterCrossing,
          'storedAfterCrossing': storedAfterCrossing,
        });
        expect(
          ((atY['topBlock'] as int) - xBlock).abs(),
          greaterThanOrEqualTo(3),
          reason: 'precondition: Y is at least 3 blocks from X',
        );
        expectBlockPreserved(atY, storedAtY, xBlock: xBlock);
        expectPreserved(atY, afterCrossing, xBlock: xBlock);
        expectBlockPreserved(atY, storedAfterCrossing, xBlock: xBlock);
      });
    }
  });
}
