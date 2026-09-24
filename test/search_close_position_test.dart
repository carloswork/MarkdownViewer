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

/// Where the Reader stands after Search closes.
///
/// The contract: closing Search must preserve the latest deliberate Reader
/// position, not restore the mount-time one. The fix is a one-shot anchor
/// captured on close only; opening Search is not changed. Every route also
/// prints one `DF063 {json}` observation line with the raw positions.
///
/// Positions are read from the Reader list's own item positions, so "visible"
/// means a block of that section is at least partly inside the Reader
/// viewport. "Preserved" uses a fixed tolerance: the top visible block
/// after close is within ±2 blocks of where it was immediately before close,
/// and for the result routes the target heading block itself must be visible
/// (the primary criterion).
void main() {
  const wide = Size(1400, 900);
  const narrow = Size(800, 800);
  const k = 10; // mount-time restore section
  const x = 18; // result section

  setUp(() async {
    await store.init(backend: MemoryBackend());
  });

  // --- Fixture ---------------------------------------------------------------

  const tokens = {18: 'zebraeighteen', 22: 'zebratwentytwo'};

  String fixtureSource() {
    final buffer = StringBuffer('# DF-063 fixture\n\n');
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
  final document = MarkdownDocument.fromSource(source, id: 'df063');

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
    savedAt: DateTime(2026, 9, 24),
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

  Set<int> visibleSections(WidgetTester tester) =>
      visibleItems(tester).map((p) => sectionOf(p.index)).toSet();

  Map<String, Object?> snapshot(WidgetTester tester) => {
    'topBlock': topBlock(tester),
    'topSection': sectionOf(topBlock(tester)),
    'visibleSections': (visibleSections(tester).toList()..sort()),
  };

  void record(String route, Map<String, Object?> data) {
    debugPrint(
      'DF063 ${jsonEncode({'route': route, 'rev': 'cp2', ...data})}',
    );
  }

  /// Whether the given section's heading block is itself among the rendered,
  /// on-screen items - the primary criterion for "preserved".
  bool headingVisible(WidgetTester tester, int section) =>
      visibleItems(tester).any((p) => p.index == sectionStart[section]);

  /// The secondary criterion: the top visible block after close is
  /// within ±2 blocks of where it was immediately before close, and it has
  /// not fallen back to the document start.
  void expectPreserved(Map pre, Map post) {
    final preBlock = pre['topBlock'] as int;
    final postBlock = post['topBlock'] as int;
    expect((postBlock - preBlock).abs(), lessThanOrEqualTo(2));
    expect(postBlock, isNot(0));
  }

  /// Same tolerance, applied to the page-lifetime report instead of the
  /// visible position.
  void expectReportPreserved(Map pre, int? reportedBlock) {
    expect(reportedBlock, isNotNull);
    final preBlock = pre['topBlock'] as int;
    expect((reportedBlock! - preBlock).abs(), lessThanOrEqualTo(2));
  }

  Future<void> openSearchByShortcut(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
  }

  Future<void> query(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const ValueKey('search-field')), text);
    await tester.pump(const Duration(milliseconds: 151));
    await settle(tester);
  }

  Future<void> selectFirstResult(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('search-result-0')));
    await settle(tester);
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

  Future<void> closePane(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('search-close')));
    await settle(tester);
  }

  Future<void> closeByEscape(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
  }

  int? lastReportedSection(WidgetTester tester) =>
      reported.isEmpty ? null : sectionOf(reported.last.blockIndex);

  int? lastReportedBlock(WidgetTester tester) =>
      reported.isEmpty ? null : reported.last.blockIndex;

  Future<void> afterDebounce(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 600));

  // --- F1 / F2 / F4 (P) : the close-verdict routes, wide ---------------------

  testWidgets(
    'F1+F2 wide result close preserves the X-area position, not K',
    (tester) async {
      useViewport(tester, wide);
      await pumpReader(tester, sessionPosition: positionAt(k));
      final mounted = snapshot(tester);
      final beforeOpen = listState(tester);

      await manualScroll(tester, -2400); // M
      final atM = snapshot(tester);

      await openSearchByShortcut(tester);
      expect(find.byKey(const ValueKey('search-pane')), findsOneWidget);
      final afterOpenState = listState(tester);
      final afterOpen = snapshot(tester);

      await query(tester, tokens[x]!);
      await selectFirstResult(tester);
      final atX = snapshot(tester);
      final beforeClose = listState(tester);

      await closePane(tester);
      final afterClose = snapshot(tester);
      final afterCloseState = listState(tester);
      await afterDebounce(tester);

      record('F1+F2', {
        'mounted': mounted,
        'M': atM,
        'afterOpen': afterOpen,
        'X': atX,
        'afterClose': afterClose,
        'openReplacedListState': !identical(beforeOpen, afterOpenState),
        'closeReplacedListState': !identical(beforeClose, afterCloseState),
        'reportedSectionAfterClose': lastReportedSection(tester),
      });

      // M ≠ K precondition: without it F2-style discrimination proves nothing.
      expect(atM['topSection'], isNot(k), reason: 'M ≠ K precondition');

      // Mechanism guard: the fix does not remove the remount that closing
      // wide Search causes; it only changes what the new list starts from.
      expect(
        identical(beforeClose, afterCloseState),
        isFalse,
        reason: 'wide close still replaces the list State',
      );

      // Contract: close preserves the X-area position, not the mount-time K.
      expect(atX['visibleSections'], contains(x));
      expectPreserved(atX, afterClose);
      expect(
        afterClose['topSection'],
        isNot(k),
        reason: 'must not fall back to the mount-time restore K',
      );
    },
  );

  testWidgets('F3/W6 wide open from a scrolled position, then close', (
    tester,
  ) async {
    useViewport(tester, wide);
    await pumpReader(tester, sessionPosition: positionAt(k));
    await manualScroll(tester, -2400);
    final atM = snapshot(tester);
    final before = listState(tester);
    await openSearchByShortcut(tester);
    final afterOpen = snapshot(tester);
    final openReplaced = !identical(before, listState(tester));
    await closePane(tester);
    final afterClose = snapshot(tester);
    await afterDebounce(tester);
    record('F3/W6', {
      'M': atM,
      'afterOpen': afterOpen,
      'afterClose': afterClose,
      'openReplacedListState': openReplaced,
      'reportedSectionAfterClose': lastReportedSection(tester),
    });
    // F3 (opening moves the Reader to the mount-time K) is not changed by
    // the close-only fix and is not asserted here; it is a separate, known
    // behavior. What close does with M is likewise not asserted (nothing is
    // captured on open).
    //
    // The contract is what close does with whatever position open left:
    // the post-open position is preserved on close.
    expectPreserved(afterOpen, afterClose);
  });

  // --- W1–W5, W7 : wide contract routes -------------------------------------

  Future<Map<String, Object?>> wideResultThen(
    WidgetTester tester,
    Future<void> Function() beforeClose,
    Future<void> Function() close,
  ) async {
    useViewport(tester, wide);
    await pumpReader(tester);
    await openSearchByShortcut(tester);
    await query(tester, tokens[x]!);
    await selectFirstResult(tester);
    await beforeClose();
    final pre = snapshot(tester);
    await close();
    final post = snapshot(tester);
    await afterDebounce(tester);
    return {
      'beforeClose': pre,
      'afterClose': post,
      'reportedSectionAfterClose': lastReportedSection(tester),
      'reportedBlockAfterClose': lastReportedBlock(tester),
    };
  }

  testWidgets('W1 wide result then pane X', (tester) async {
    final r = await wideResultThen(
      tester,
      () async {},
      () => closePane(tester),
    );
    record('W1', r);
    final pre = r['beforeClose']! as Map;
    final post = r['afterClose']! as Map;
    expect(pre['visibleSections'], contains(x));
    expectPreserved(pre, post);
    expectReportPreserved(pre, r['reportedBlockAfterClose'] as int?);
    expect(
      headingVisible(tester, x),
      isTrue,
      reason: 'target heading in the Reader viewport (primary criterion)',
    );
  });

  testWidgets('W2 wide result then Escape', (tester) async {
    final r = await wideResultThen(
      tester,
      () async {},
      () => closeByEscape(tester),
    );
    record('W2', r);
    final pre = r['beforeClose']! as Map;
    final post = r['afterClose']! as Map;
    expect(pre['visibleSections'], contains(x));
    expectPreserved(pre, post);
    expectReportPreserved(pre, r['reportedBlockAfterClose'] as int?);
    expect(headingVisible(tester, x), isTrue);
  });

  testWidgets('W3 wide result, query cleared, then pane X', (tester) async {
    final r = await wideResultThen(
      tester,
      () => query(tester, ''),
      () => closePane(tester),
    );
    record('W3', r);
    final pre = r['beforeClose']! as Map;
    final post = r['afterClose']! as Map;
    expect(pre['visibleSections'], contains(x));
    expectPreserved(pre, post);
    expectReportPreserved(pre, r['reportedBlockAfterClose'] as int?);
    expect(headingVisible(tester, x), isTrue);
  });

  testWidgets('W4 wide result, later manual scroll, then pane X', (
    tester,
  ) async {
    final r = await wideResultThen(
      tester,
      () => manualScroll(tester, -1600),
      () => closePane(tester),
    );
    record('W4', r);
    final pre = r['beforeClose']! as Map;
    final post = r['afterClose']! as Map;
    expect(pre['topSection'] as int, greaterThanOrEqualTo(x));
    expectPreserved(pre, post);
    expectReportPreserved(pre, r['reportedBlockAfterClose'] as int?);
  });

  testWidgets('W5 wide no result, manual scroll with pane open, pane X', (
    tester,
  ) async {
    useViewport(tester, wide);
    await pumpReader(tester);
    await openSearchByShortcut(tester);
    await manualScroll(tester, -2400);
    await manualScroll(tester, -2400);
    final pre = snapshot(tester);
    await closePane(tester);
    final post = snapshot(tester);
    await afterDebounce(tester);
    final reportedBlock = lastReportedBlock(tester);
    record('W5', {
      'beforeClose': pre,
      'afterClose': post,
      'reportedSectionAfterClose': lastReportedSection(tester),
      'reportedBlockAfterClose': reportedBlock,
    });
    expect(pre['topBlock'] as int, greaterThan(5));
    expectPreserved(pre, post);
    expectReportPreserved(pre, reportedBlock);
  });

  testWidgets('W7 wide far manual scroll, pane X (reflow guard)', (
    tester,
  ) async {
    useViewport(tester, wide);
    await pumpReader(tester);
    await openSearchByShortcut(tester);
    for (var i = 0; i < 6; i++) {
      await manualScroll(tester, -2400);
    }
    final pre = snapshot(tester);
    await closePane(tester);
    final post = snapshot(tester);
    await afterDebounce(tester);
    final reportedBlock = lastReportedBlock(tester);
    record('W7', {
      'beforeClose': pre,
      'afterClose': post,
      'reportedBlockAfterClose': reportedBlock,
    });
    expect(pre['topSection'] as int, greaterThan(5));
    expectPreserved(pre, post);
    expectReportPreserved(pre, reportedBlock);
  });

  testWidgets(
    'Mid-animation close during the 320 ms result scroll (characterization)',
    (tester) async {
      // A known edge: the other routes all close after the result
      // scroll settles. This route closes partway through it instead, and
      // only records where that lands - it is not an acceptance criterion.
      useViewport(tester, wide);
      await pumpReader(tester);
      await openSearchByShortcut(tester);
      await query(tester, tokens[x]!);
      await tester.tap(find.byKey(const ValueKey('search-result-0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100)); // ~100 ms of 320
      await closePane(tester);
      await afterDebounce(tester);
      final after = snapshot(tester);
      record('MID-ANIM', {
        'afterClose': after,
        'reportedSectionAfterClose': lastReportedSection(tester),
      });
      expect(visibleItems(tester), isNotEmpty);
    },
  );

  // --- F5 controls and N1–N3 : must preserve ---------------------------------

  testWidgets('F5 resize within pane mode keeps the Reader', (tester) async {
    useViewport(tester, wide);
    await pumpReader(tester);
    await openSearchByShortcut(tester);
    await query(tester, tokens[x]!);
    await selectFirstResult(tester);
    final before = snapshot(tester);
    final state = listState(tester);
    tester.view.physicalSize = const Size(1300, 900);
    await settle(tester);
    final after = snapshot(tester);
    record('F5-resize', {
      'before': before,
      'after': after,
      'replacedListState': !identical(state, listState(tester)),
    });
    expect(identical(state, listState(tester)), isTrue);
    expect(after['visibleSections'], contains(x));
  });

  Future<void> openSheet(WidgetTester tester) async {
    await openSearchByShortcut(tester);
    expect(find.byKey(const ValueKey('search-sheet')), findsOneWidget);
  }

  Future<void> compactClose(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('compact-search-close')));
    await settle(tester);
  }

  testWidgets('N1 narrow sheet result then compact close', (tester) async {
    useViewport(tester, narrow);
    await pumpReader(tester);
    final state = listState(tester);
    await openSheet(tester);
    await query(tester, tokens[x]!);
    await selectFirstResult(tester);
    final pre = snapshot(tester);
    await compactClose(tester);
    final post = snapshot(tester);
    await afterDebounce(tester);
    final same = identical(state, listState(tester));
    record('N1', {
      'beforeClose': pre,
      'afterClose': post,
      'sameListState': same,
      'reportedSectionAfterClose': lastReportedSection(tester),
    });
    expect(same, isTrue, reason: 'F1 narrow part');
    expect(pre['visibleSections'], contains(x));
    expect(post['visibleSections'], contains(x));
  });

  testWidgets('N2 narrow sheet dismissed, manual scroll, compact close', (
    tester,
  ) async {
    useViewport(tester, narrow);
    await pumpReader(tester);
    final state = listState(tester);
    await openSheet(tester);
    await tester.tap(find.byKey(const ValueKey('search-close')));
    await settle(tester);
    expect(
      find.byKey(const ValueKey('compact-search-navigator')),
      findsOneWidget,
    );
    await manualScroll(tester, -2400);
    await manualScroll(tester, -2400);
    final pre = snapshot(tester);
    await compactClose(tester);
    final post = snapshot(tester);
    await afterDebounce(tester);
    final same = identical(state, listState(tester));
    record('N2', {
      'beforeClose': pre,
      'afterClose': post,
      'sameListState': same,
      'reportedSectionAfterClose': lastReportedSection(tester),
    });
    expect(same, isTrue);
    expect(pre['topBlock'] as int, greaterThan(5));
    expect(
      (post['topBlock']! as int) - (pre['topBlock']! as int),
      inInclusiveRange(-2, 2),
    );
  });

  testWidgets('N3 narrow sheet result, manual scroll, compact close', (
    tester,
  ) async {
    useViewport(tester, narrow);
    await pumpReader(tester);
    final state = listState(tester);
    await openSheet(tester);
    await query(tester, tokens[x]!);
    await selectFirstResult(tester);
    await manualScroll(tester, -1600);
    final pre = snapshot(tester);
    await compactClose(tester);
    final post = snapshot(tester);
    await afterDebounce(tester);
    final same = identical(state, listState(tester));
    record('N3', {
      'beforeClose': pre,
      'afterClose': post,
      'sameListState': same,
      'reportedSectionAfterClose': lastReportedSection(tester),
    });
    expect(same, isTrue);
    expect(
      (post['topBlock']! as int) - (pre['topBlock']! as int),
      inInclusiveRange(-2, 2),
    );
  });

  // --- F4 retained position and page-lifetime Home continuation (full app) ---

  group('full app', () {
    late FakeBackend backend;
    var launches = 0;

    Future<void> launch(WidgetTester tester) async {
      await store.init(backend: backend);
      final startup = await retention.resolveStartup();
      await tester.pumpWidget(
        MarkdownViewerApp(
          key: ValueKey('df063-launch-${launches++}'),
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

    int? storedSection() {
      final raw = backend.data[Store.positionKey];
      if (raw == null) return null;
      final position = ReadingPosition.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      return sectionOf(position.blockIndex);
    }

    /// Block-level, unlike [storedSection]: the ±2-block tolerance does not
    /// survive being rounded down to a section number.
    int? storedBlock() {
      final raw = backend.data[Store.positionKey];
      if (raw == null) return null;
      return ReadingPosition.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      ).blockIndex;
    }

    setUp(() => backend = FakeBackend());

    Future<void> continueReading(WidgetTester tester) async {
      await tester.tap(find.text('Continue reading'));
      await settle(tester);
    }

    Future<void> returnHome(WidgetTester tester) async {
      // Reveal the auto-hidden menu without a Reader scroll: the menu
      // autofocuses, so activate it from the keyboard.
      final menu = find.byIcon(Icons.more_horiz_rounded);
      final focus = tester.binding.focusManager.primaryFocus;
      if (focus?.debugLabel != 'Reader menu') {
        await tester.tap(menu, warnIfMissed: false);
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      }
      await settle(tester);
      await tester.ensureVisible(find.text('Return to main'));
      await tester.tap(find.text('Return to main'));
      await settle(tester);
    }

    testWidgets(
      'F4 retained position under ON: open still jumps to K, close '
      'preserves the X-area position',
      (tester) async {
        useViewport(tester, wide);
        seedOn(position: positionAt(k));
        await launch(tester);
        await continueReading(tester);
        final mounted = snapshot(tester);
        await manualScroll(tester, -2400);
        await afterDebounce(tester);
        await store.settlePendingOperations();
        final storedAtM = storedSection();
        await openSearchByShortcut(tester);
        final afterOpen = snapshot(tester);
        await query(tester, tokens[x]!);
        await selectFirstResult(tester);
        await afterDebounce(tester);
        await store.settlePendingOperations();
        final storedBlockAtX = storedBlock();
        await closePane(tester);
        await afterDebounce(tester);
        await store.settlePendingOperations();
        final after = snapshot(tester);
        final storedBlockAfterClose = storedBlock();
        record('F4-R', {
          'mounted': mounted,
          'storedAtM': storedAtM,
          'afterOpen': afterOpen,
          'storedBlockAtX': storedBlockAtX,
          'afterClose': after,
          'storedBlockAfterClose': storedBlockAfterClose,
        });
        // Known, not fixed (the fix is close-only): opening still remounts
        // the list from the mount-time restore K.
        expect(afterOpen['topSection'], k);
        // Contract: the stored position after close is within ±2 blocks of
        // the stored position before close - the X area - and not K.
        expect(
          (storedBlockAfterClose! - storedBlockAtX!).abs(),
          lessThanOrEqualTo(2),
        );
        expect(
          (storedBlockAfterClose - positionAt(k).blockIndex).abs(),
          greaterThan(2),
          reason: 'not K',
        );
      },
    );

    for (final route in const ['W1', 'W4', 'W5']) {
      testWidgets('$route retained position under ON (fresh, no restore)', (
        tester,
      ) async {
        useViewport(tester, wide);
        seedOn();
        await launch(tester);
        await continueReading(tester);
        await openSearchByShortcut(tester);
        if (route != 'W5') {
          await query(tester, tokens[x]!);
          await selectFirstResult(tester);
        }
        if (route == 'W4') await manualScroll(tester, -1600);
        if (route == 'W5') {
          await manualScroll(tester, -2400);
          await manualScroll(tester, -2400);
        }
        await afterDebounce(tester);
        await store.settlePendingOperations();
        final storedBlockBefore = storedBlock();
        final pre = snapshot(tester);
        await closePane(tester);
        await afterDebounce(tester);
        await store.settlePendingOperations();
        final storedBlockAfter = storedBlock();
        record('$route-R', {
          'beforeClose': pre,
          'storedBlockBeforeClose': storedBlockBefore,
          'afterClose': snapshot(tester),
          'storedBlockAfterClose': storedBlockAfter,
        });
        expect(storedBlockBefore, isNot(0));
        expect(
          (storedBlockAfter! - storedBlockBefore!).abs(),
          lessThanOrEqualTo(2),
        );
        expect(storedBlockAfter, isNot(0));
      });
    }

    for (final route in const ['W1', 'W5']) {
      testWidgets('$route default-OFF Home → Continue reading', (tester) async {
        useViewport(tester, wide);
        await launch(tester);
        await tester.ensureVisible(find.text('Paste Markdown'));
        await tester.tap(find.text('Paste Markdown'));
        await settle(tester);
        await tester.enterText(find.byType(TextField), source);
        await settle(tester);
        await tester.tap(find.widgetWithText(TextButton, 'Open'));
        await settle(tester);
        await openSearchByShortcut(tester);
        if (route == 'W1') {
          await query(tester, tokens[x]!);
          await selectFirstResult(tester);
        } else {
          await manualScroll(tester, -2400);
        }
        final pre = snapshot(tester);
        await closePane(tester);
        final post = snapshot(tester);
        await afterDebounce(tester);
        await returnHome(tester);
        await continueReading(tester);
        final resumed = snapshot(tester);
        record('$route-HOME', {
          'beforeClose': pre,
          'afterClose': post,
          'afterContinue': resumed,
        });
        expect(pre['topSection'] as int, greaterThan(1));
        expectPreserved(pre, resumed);
      });
    }
  });
}
