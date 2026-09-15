import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/document_search.dart';
import 'package:markdown_viewer/markdown_theme.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/reader_screen.dart';
import 'package:markdown_viewer/search_surface.dart';
import 'package:markdown_viewer/store.dart';

import 'support/fake_storage.dart';

void main() {
  setUp(() async {
    await store.init(backend: MemoryBackend());
  });

  void useViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  void expectPrimaryFocusInside(WidgetTester tester, Finder ancestor) {
    final focusContext = tester.binding.focusManager.primaryFocus?.context;
    expect(focusContext, isNotNull);
    final focused = find.byElementPredicate(
      (element) => identical(element, focusContext),
    );
    expect(find.ancestor(of: focused, matching: ancestor), findsOneWidget);
  }

  void expectPrimaryFocusOutside(WidgetTester tester, Finder ancestor) {
    final focusContext = tester.binding.focusManager.primaryFocus?.context;
    expect(focusContext, isNotNull);
    final focused = find.byElementPredicate(
      (element) => identical(element, focusContext),
    );
    expect(find.ancestor(of: focused, matching: ancestor), findsNothing);
  }

  Future<void> reverseTab(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
  }

  Widget reader(
    MarkdownDocument document, {
    Settings settings = const Settings(),
    VoidCallback? onSearchIndexBuilt,
    Key? key,
  }) => MaterialApp(
    home: ReaderScreen(
      key: key,
      document: document,
      settings: settings,
      onSettingsChanged: (_) {},
      onScriptPreferenceChanged: (_) {},
      onEdit: () {},
      onLoadFile: () {},
      onReturnHome: () {},
      onPositionChanged: (_) {},
      onSearchIndexBuilt: onSearchIndexBuilt,
    ),
  );

  Future<void> openFromMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await settle(tester);
    await tester.tap(find.text('Search document'));
    await settle(tester);
  }

  test('responsive boundary is derived from pane and Reader requirements', () {
    expect(
      kSearchPaneWidth,
      kMinimumSearchPaneContentWidth + 2 * kSearchPaneHorizontalInset,
    );
    expect(kSearchPaneWidth, 360);
    expect(
      kMinimumReaderRegionBesideSearch,
      kMinimumReaderContentWidthBesideSearch + 2 * kWideReaderSidePadding,
    );
    expect(kMinimumReaderRegionBesideSearch, 720);
    expect(
      readerContentWidth(kMinimumReaderRegionBesideSearch),
      kMinimumReaderContentWidthBesideSearch,
    );
    expect(kSearchPaneDividerWidth, 1);
    expect(
      kSearchPaneBreakpoint,
      kSearchPaneWidth +
          kSearchPaneDividerWidth +
          kMinimumReaderRegionBesideSearch,
    );
    expect(usesPersistentSearchPane(1080), isFalse);
    expect(usesPersistentSearchPane(1081), isTrue);
    expect(usesPersistentSearchPane(1600), isTrue);
  });

  test('active locator accents meet non-text contrast in both palettes', () {
    double contrast(Color left, Color right) {
      final first = left.computeLuminance();
      final second = right.computeLuminance();
      final high = first > second ? first : second;
      final low = first > second ? second : first;
      return (high + 0.05) / (low + 0.05);
    }

    expect(
      contrast(ReaderPalette.light.link, ReaderPalette.light.background),
      greaterThanOrEqualTo(3),
    );
    expect(
      contrast(ReaderPalette.dark.link, ReaderPalette.dark.background),
      greaterThanOrEqualTo(3),
    );
  });

  testWidgets(
    'wide menu search is lazy, exact, keyboard navigable, and closable',
    (tester) async {
      useViewport(tester, const Size(1200, 900));
      var indexBuilds = 0;
      final document = MarkdownDocument.fromSource('''
# First

Alpha Needle omega.

## Second

Another needle result.
''');
      await tester.pumpWidget(
        reader(document, onSearchIndexBuilt: () => indexBuilds++),
      );
      await settle(tester);
      expect(indexBuilds, 0);

      await openFromMenu(tester);
      expect(find.byKey(const ValueKey('search-pane')), findsOneWidget);
      expect(indexBuilds, 1);
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        'Search field',
      );

      await tester.enterText(
        find.byKey(const ValueKey('search-field')),
        'needle',
      );
      await tester.pump(const Duration(milliseconds: 151));
      await tester.pump();
      expect(find.text('2 results'), findsOneWidget);
      expect(find.byKey(const ValueKey('search-result-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('search-result-1')), findsOneWidget);

      final firstRow = find.byKey(const ValueKey('search-result-0'));
      final snippet = tester
          .widgetList<RichText>(
            find.descendant(of: firstRow, matching: find.byType(RichText)),
          )
          .map((widget) => widget.text)
          .whereType<TextSpan>()
          .firstWhere(
            (span) =>
                span.children?.any(
                  (child) => child is TextSpan && child.text == 'Needle',
                ) ??
                false,
          );
      expect(
        snippet.children?.whereType<TextSpan>().any(
          (span) =>
              span.text == 'Needle' &&
              span.style?.fontWeight == FontWeight.w700,
        ),
        isTrue,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.text('Search result 1 of 2, First'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('active-search-locator')),
        findsOneWidget,
      );
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        'Active search result',
      );

      await tester.tap(find.byKey(const ValueKey('search-field')));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.text('Search result 2 of 2, Second'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('search-field')));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await settle(tester);
      expect(find.text('Search result 1 of 2, First'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('search-next')));
      await settle(tester);
      expect(find.text('Search result 2 of 2, Second'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('search-previous')));
      await settle(tester);
      expect(find.text('Search result 1 of 2, First'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.byKey(const ValueKey('search-pane')), findsNothing);
      expect(find.byKey(const ValueKey('active-search-locator')), findsNothing);
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        'Reader menu',
      );
    },
  );

  testWidgets('a distant non-materialized result scrolls to its owning block', (
    tester,
  ) async {
    useViewport(tester, const Size(1200, 700));
    final source = StringBuffer('# Start\n\n');
    for (var index = 0; index < 100; index++) {
      source.writeln('## Section $index\n\nBody $index.\n');
    }
    source.writeln('## Destination\n\nTARGET-SEARCH-MARKER\n');
    await tester.pumpWidget(reader(MarkdownDocument.fromSource('$source')));
    await settle(tester);
    expect(find.text('TARGET-SEARCH-MARKER'), findsNothing);

    await openFromMenu(tester);
    await tester.enterText(
      find.byKey(const ValueKey('search-field')),
      'TARGET-SEARCH-MARKER',
    );
    await tester.pump(const Duration(milliseconds: 151));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('search-result-0')));
    await settle(tester);

    expect(find.byKey(const ValueKey('active-search-locator')), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            (widget.data ?? widget.textSpan?.toPlainText()) ==
                'TARGET-SEARCH-MARKER',
      ),
      findsOneWidget,
    );
    expect(find.text('Search result 1 of 1, Destination'), findsOneWidget);
  });

  testWidgets(
    'sheet selection closes the route and leaves a compact navigator',
    (tester) async {
      useViewport(tester, const Size(800, 700));
      await tester.pumpWidget(
        reader(MarkdownDocument.fromSource('# Heading\n\nNeedle body.')),
      );
      await settle(tester);
      await openFromMenu(tester);
      expect(find.byKey(const ValueKey('search-sheet')), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('search-field')),
        'needle',
      );
      await tester.pump(const Duration(milliseconds: 151));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('search-result-0')));
      await settle(tester);

      expect(find.byKey(const ValueKey('search-sheet')), findsNothing);
      expect(
        find.byKey(const ValueKey('compact-search-navigator')),
        findsOneWidget,
      );
      expect(find.text('Search result 1 of 1, Heading'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('search-reopen-results')));
      await settle(tester);
      expect(find.byKey(const ValueKey('search-sheet')), findsOneWidget);
      expect(find.text('needle'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('search-close')));
      await settle(tester);
      expect(find.byKey(const ValueKey('search-sheet')), findsNothing);
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        'Show search results',
      );

      await tester.tap(find.byKey(const ValueKey('compact-search-close')));
      await settle(tester);
      expect(
        find.byKey(const ValueKey('compact-search-navigator')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('active-search-locator')), findsNothing);
    },
  );

  testWidgets('crossing the breakpoint preserves query, result, and index', (
    tester,
  ) async {
    useViewport(tester, const Size(1200, 800));
    var indexBuilds = 0;
    await tester.pumpWidget(
      reader(
        MarkdownDocument.fromSource('# Heading\n\nNeedle body.'),
        onSearchIndexBuilt: () => indexBuilds++,
      ),
    );
    await settle(tester);
    await openFromMenu(tester);
    await tester.enterText(
      find.byKey(const ValueKey('search-field')),
      'needle',
    );
    await tester.pump(const Duration(milliseconds: 151));
    await tester.pump();
    expect(indexBuilds, 1);
    await tester.tap(find.byKey(const ValueKey('search-result-0')));
    await settle(tester);
    expect(find.text('Search result 1 of 1, Heading'), findsOneWidget);
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      'Active search result',
    );

    tester.view.physicalSize = const Size(1080, 800);
    await settle(tester);
    expect(find.byKey(const ValueKey('search-sheet')), findsOneWidget);
    expect(find.text('needle'), findsOneWidget);
    expect(find.text('1 result'), findsOneWidget);
    expect(find.text('Search result 1 of 1, Heading'), findsOneWidget);
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      'Search result',
    );
    expectPrimaryFocusInside(
      tester,
      find.byKey(const ValueKey('search-sheet')),
    );
    expectPrimaryFocusOutside(
      tester,
      find.byKey(const ValueKey('reader-region')),
    );
    expect(indexBuilds, 1);

    tester.view.physicalSize = const Size(1081, 800);
    await settle(tester);
    expect(find.byKey(const ValueKey('search-pane')), findsOneWidget);
    expect(find.text('needle'), findsOneWidget);
    expect(find.text('1 result'), findsOneWidget);
    expect(find.text('Search result 1 of 1, Heading'), findsOneWidget);
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      'Active search result',
    );
    expect(indexBuilds, 1);
  });

  testWidgets('breakpoint renders measured pane and Reader regions', (
    tester,
  ) async {
    useViewport(tester, const Size(1080, 800));
    await tester.pumpWidget(
      reader(MarkdownDocument.fromSource('# Heading\n\nNeedle body.')),
    );
    await settle(tester);
    await openFromMenu(tester);
    expect(find.byKey(const ValueKey('search-sheet')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('reader-region'))).width,
      1080,
    );

    tester.view.physicalSize = const Size(1081, 800);
    await settle(tester);
    expect(find.byKey(const ValueKey('search-pane')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('search-pane'))).width,
      kSearchPaneWidth,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('search-field'))).width,
      kMinimumSearchPaneContentWidth,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('reader-region'))).width,
      kMinimumReaderRegionBesideSearch,
    );

    tester.view.physicalSize = const Size(1082, 800);
    await settle(tester);
    expect(
      tester.getSize(find.byKey(const ValueKey('reader-region'))).width,
      721,
    );
    expect(tester.takeException(), isNull);
  });

  for (final scale in [Settings.minFontScale, Settings.maxFontScale]) {
    testWidgets('pane remains usable at supported text scale $scale', (
      tester,
    ) async {
      useViewport(tester, const Size(1081, 800));
      await tester.pumpWidget(
        reader(
          MarkdownDocument.fromSource('# Heading\n\nNeedle body.'),
          settings: Settings(fontScale: scale),
        ),
      );
      await settle(tester);
      await openFromMenu(tester);
      await tester.enterText(
        find.byKey(const ValueKey('search-field')),
        'needle',
      );
      await tester.pump(const Duration(milliseconds: 151));
      await tester.pump();

      final fieldContext = tester.element(
        find.byKey(const ValueKey('search-field')),
      );
      final readerContext = tester.element(
        find.byKey(const ValueKey('reader-region')),
      );
      expect(
        MediaQuery.textScalerOf(fieldContext).scale(10),
        closeTo(10 * scale, 0.01),
      );
      expect(
        MediaQuery.textScalerOf(readerContext).scale(10),
        closeTo(10 * scale, 0.01),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('search-field'))).width,
        kMinimumSearchPaneContentWidth,
      );
      expect(find.byKey(const ValueKey('search-result-0')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('medium and very-wide layouts retain Reader measure and margin', (
    tester,
  ) async {
    useViewport(tester, const Size(1280, 900));
    await tester.pumpWidget(
      reader(MarkdownDocument.fromSource('# Heading\n\nNeedle body.')),
    );
    await settle(tester);
    await openFromMenu(tester);

    double readerRegionWidth() =>
        tester.getSize(find.byKey(const ValueKey('reader-region'))).width;
    expect(readerRegionWidth(), 919);
    expect(readerContentWidth(readerRegionWidth()), 855);

    tester.view.physicalSize = const Size(2560, 900);
    await settle(tester);
    expect(readerRegionWidth(), 2199);
    expect(readerContentWidth(readerRegionWidth()), kMaxProseWidth);
    expect(readerRegionWidth() - readerContentWidth(readerRegionWidth()), 1079);
    expect(
      tester.getSize(find.byKey(const ValueKey('search-pane'))).width,
      kSearchPaneWidth,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('pane traversal reaches Reader and reverses into pane', (
    tester,
  ) async {
    useViewport(tester, const Size(1200, 800));
    await tester.pumpWidget(
      reader(
        MarkdownDocument.fromSource(
          '# First\n\nNeedle body.\n\n# Second\n\nAnother needle.',
        ),
      ),
    );
    await settle(tester);
    await openFromMenu(tester);
    await tester.enterText(
      find.byKey(const ValueKey('search-field')),
      'needle',
    );
    await tester.pump(const Duration(milliseconds: 151));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expectPrimaryFocusInside(
      tester,
      find.byKey(const ValueKey('search-result-0')),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expectPrimaryFocusInside(
      tester,
      find.byKey(const ValueKey('search-result-1')),
    );
    for (final label in ['Previous result', 'Next result', 'Close search']) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(tester.binding.focusManager.primaryFocus?.debugLabel, label);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expectPrimaryFocusInside(
      tester,
      find.byKey(const ValueKey('reader-region')),
    );

    for (final label in ['Close search', 'Next result', 'Previous result']) {
      await reverseTab(tester);
      expect(tester.binding.focusManager.primaryFocus?.debugLabel, label);
    }
    await reverseTab(tester);
    expectPrimaryFocusInside(
      tester,
      find.byKey(const ValueKey('search-result-1')),
    );
    await reverseTab(tester);
    expectPrimaryFocusInside(
      tester,
      find.byKey(const ValueKey('search-result-0')),
    );
    await reverseTab(tester);
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      'Search field',
    );
  });

  testWidgets('pane Previous and Next map through modal exactly', (
    tester,
  ) async {
    useViewport(tester, const Size(1200, 800));
    await tester.pumpWidget(
      reader(
        MarkdownDocument.fromSource(
          '# First\n\nNeedle body.\n\n# Second\n\nAnother needle.',
        ),
      ),
    );
    await settle(tester);
    await openFromMenu(tester);
    await tester.enterText(
      find.byKey(const ValueKey('search-field')),
      'needle',
    );
    await tester.pump(const Duration(milliseconds: 151));
    await tester.pump();

    Future<void> focusPaneControl(String key, String label) async {
      tester
          .widget<IconButton>(find.byKey(ValueKey(key)))
          .focusNode!
          .requestFocus();
      await tester.pump();
      expect(tester.binding.focusManager.primaryFocus?.debugLabel, label);
      expectPrimaryFocusInside(
        tester,
        find.byKey(const ValueKey('search-pane')),
      );
    }

    Future<void> expectModalFocus(String label) async {
      await settle(tester);
      expect(tester.binding.focusManager.primaryFocus?.debugLabel, label);
      expectPrimaryFocusInside(
        tester,
        find.byKey(const ValueKey('search-sheet')),
      );
      expectPrimaryFocusOutside(
        tester,
        find.byKey(const ValueKey('reader-region')),
      );
      expect(
        find.byKey(const ValueKey('compact-search-navigator')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('search-previous')), findsNothing);
      expect(find.byKey(const ValueKey('search-next')), findsNothing);
    }

    Future<void> returnToPane(String label) async {
      tester.view.physicalSize = const Size(1200, 800);
      await tester.pump();
      expect(find.byKey(const ValueKey('search-sheet')), findsOneWidget);
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        isNot(label),
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('search-sheet')), findsNothing);
      expect(tester.binding.focusManager.primaryFocus?.debugLabel, label);
      expectPrimaryFocusInside(
        tester,
        find.byKey(const ValueKey('search-pane')),
      );
    }

    Future<void> dismissToCompact(String label, String compactKey) async {
      await tester.tap(find.byKey(const ValueKey('search-close')));
      await tester.pump();
      expect(find.byKey(const ValueKey('search-sheet')), findsOneWidget);
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        isNot(label),
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('search-sheet')), findsNothing);
      expect(tester.binding.focusManager.primaryFocus?.debugLabel, label);
      expectPrimaryFocusInside(
        tester,
        find.byKey(const ValueKey('compact-search-navigator')),
      );
      expectPrimaryFocusInside(tester, find.byKey(ValueKey(compactKey)));
    }

    const controls = [
      ('search-previous', 'Previous result', 'compact-search-previous'),
      ('search-next', 'Next result', 'compact-search-next'),
    ];

    for (final control in controls) {
      await focusPaneControl(control.$1, control.$2);
      tester.view.physicalSize = const Size(1080, 800);
      await expectModalFocus('Search field');
      await returnToPane(control.$2);

      tester.view.physicalSize = const Size(1080, 800);
      await expectModalFocus('Search field');
      await dismissToCompact(control.$2, control.$3);
      tester.view.physicalSize = const Size(1200, 800);
      await settle(tester);
    }

    await tester.tap(find.byKey(const ValueKey('search-result-0')));
    await settle(tester);
    for (final control in controls) {
      await focusPaneControl(control.$1, control.$2);
      tester.view.physicalSize = const Size(1080, 800);
      await expectModalFocus('Search result');
      await returnToPane(control.$2);

      tester.view.physicalSize = const Size(1080, 800);
      await expectModalFocus('Search result');
      await dismissToCompact(control.$2, control.$3);
      tester.view.physicalSize = const Size(1200, 800);
      await settle(tester);
    }
  });

  testWidgets('pane controls use the virtualized modal-list fallback', (
    tester,
  ) async {
    useViewport(tester, const Size(1200, 500));
    final body = List.filled(30, 'needle').join(' ');
    await tester.pumpWidget(reader(MarkdownDocument.fromSource(body)));
    await settle(tester);
    await openFromMenu(tester);
    await tester.enterText(
      find.byKey(const ValueKey('search-field')),
      'needle',
    );
    await tester.pump(const Duration(milliseconds: 151));
    await tester.pump();

    final list = find.byKey(const ValueKey('search-result-list'));
    for (var drag = 0; drag < 8; drag++) {
      if (find
          .byKey(const ValueKey('search-result-20'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
      await tester.drag(list, const Offset(0, -350));
      await tester.pump();
    }
    await tester.tap(find.byKey(const ValueKey('search-result-20')));
    await settle(tester);

    for (final control in const [
      ('search-previous', 'Previous result', 'compact-search-previous'),
      ('search-next', 'Next result', 'compact-search-next'),
    ]) {
      tester
          .widget<IconButton>(find.byKey(ValueKey(control.$1)))
          .focusNode!
          .requestFocus();
      await tester.pump();
      tester.view.physicalSize = const Size(1080, 500);
      await settle(tester);
      expect(find.byKey(const ValueKey('search-result-20')), findsNothing);
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        'Search results',
      );
      expectPrimaryFocusInside(
        tester,
        find.byKey(const ValueKey('search-sheet')),
      );
      expectPrimaryFocusOutside(
        tester,
        find.byKey(const ValueKey('reader-region')),
      );

      await tester.tap(find.byKey(const ValueKey('search-close')));
      await tester.pump();
      expect(find.byKey(const ValueKey('search-sheet')), findsOneWidget);
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        isNot(control.$2),
      );
      await settle(tester);
      expect(tester.binding.focusManager.primaryFocus?.debugLabel, control.$2);
      expectPrimaryFocusInside(tester, find.byKey(ValueKey(control.$3)));
      tester.view.physicalSize = const Size(1200, 500);
      await settle(tester);
    }
  });

  testWidgets('all sheet dismissal paths restore each exact opener', (
    tester,
  ) async {
    useViewport(tester, const Size(800, 700));
    await tester.pumpWidget(
      reader(MarkdownDocument.fromSource('# Heading\n\nNeedle body.')),
    );
    await settle(tester);

    const dismissals = ['close', 'escape', 'platform back', 'scrim'];

    Future<void> dismiss(String method) async {
      switch (method) {
        case 'close':
          await tester.tap(find.byKey(const ValueKey('search-close')));
          return;
        case 'escape':
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          return;
        case 'platform back':
          await tester.binding.handlePopRoute();
          return;
        case 'scrim':
          await tester.tapAt(const Offset(8, 8));
          return;
      }
    }

    Future<void> expectPostDisposalRestoration(
      String method,
      String expectedFocus,
    ) async {
      await dismiss(method);
      await tester.pump();
      expect(find.byKey(const ValueKey('search-sheet')), findsOneWidget);
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        isNot(expectedFocus),
      );
      expectPrimaryFocusOutside(
        tester,
        find.byKey(const ValueKey('reader-region')),
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('search-sheet')), findsNothing);
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        expectedFocus,
      );
    }

    for (final method in dismissals) {
      await openFromMenu(tester);
      await expectPostDisposalRestoration(method, 'Reader menu');
    }

    await openFromMenu(tester);
    await tester.enterText(
      find.byKey(const ValueKey('search-field')),
      'needle',
    );
    await tester.pump(const Duration(milliseconds: 151));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('search-result-0')));
    await settle(tester);
    expect(
      find.byKey(const ValueKey('compact-search-navigator')),
      findsOneWidget,
    );

    for (final method in dismissals) {
      await tester.tap(find.byKey(const ValueKey('search-reopen-results')));
      await settle(tester);
      await expectPostDisposalRestoration(method, 'Show search results');
    }

    tester.view.physicalSize = const Size(1200, 700);
    await settle(tester);
    for (final method in dismissals) {
      await tester.tap(find.byKey(const ValueKey('search-result-0')));
      await settle(tester);
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        'Active search result',
      );
      tester.view.physicalSize = const Size(1080, 700);
      await settle(tester);
      expectPrimaryFocusInside(
        tester,
        find.byKey(const ValueKey('search-sheet')),
      );
      expectPrimaryFocusOutside(
        tester,
        find.byKey(const ValueKey('reader-region')),
      );
      await expectPostDisposalRestoration(method, 'Active search result');
      tester.view.physicalSize = const Size(1200, 700);
      await settle(tester);
    }
  });

  testWidgets('transition modal uses list fallback then restores locator', (
    tester,
  ) async {
    useViewport(tester, const Size(1200, 500));
    final body = List.filled(30, 'needle').join(' ');
    await tester.pumpWidget(reader(MarkdownDocument.fromSource(body)));
    await settle(tester);
    await openFromMenu(tester);
    await tester.enterText(
      find.byKey(const ValueKey('search-field')),
      'needle',
    );
    await tester.pump(const Duration(milliseconds: 151));
    await tester.pump();

    final list = find.byKey(const ValueKey('search-result-list'));
    for (var drag = 0; drag < 8; drag++) {
      if (find
          .byKey(const ValueKey('search-result-20'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
      await tester.drag(list, const Offset(0, -350));
      await tester.pump();
    }
    expect(find.byKey(const ValueKey('search-result-20')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('search-result-20')));
    await settle(tester);
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      'Active search result',
    );

    tester.view.physicalSize = const Size(1080, 500);
    await settle(tester);
    expect(find.byKey(const ValueKey('search-sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-result-20')), findsNothing);
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      'Search results',
    );
    expectPrimaryFocusInside(
      tester,
      find.byKey(const ValueKey('search-sheet')),
    );
    expectPrimaryFocusOutside(
      tester,
      find.byKey(const ValueKey('reader-region')),
    );
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('search-result-list')))
          .label,
      contains('Result 21 of 30 selected'),
    );

    await tester.tapAt(const Offset(8, 8));
    await settle(tester);
    expect(find.byKey(const ValueKey('search-sheet')), findsNothing);
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      'Active search result',
    );
  });

  testWidgets('pane Previous and Next keep the active result row visible', (
    tester,
  ) async {
    const total = 60;
    useViewport(tester, const Size(1200, 500));
    final body = List.generate(
      total,
      (index) => 'Paragraph $index carries needle text.',
    ).join('\n\n');
    await tester.pumpWidget(reader(MarkdownDocument.fromSource(body)));
    await settle(tester);
    await openFromMenu(tester);
    await tester.enterText(
      find.byKey(const ValueKey('search-field')),
      'needle',
    );
    await tester.pump(const Duration(milliseconds: 151));
    await tester.pump();

    final list = find.byKey(const ValueKey('search-result-list'));
    Finder row(int index) => find.byKey(ValueKey('search-result-$index'));
    bool isBuilt(int index) => row(index).evaluate().isNotEmpty;
    bool isVisible(int index) {
      if (!isBuilt(index)) return false;
      final viewport = tester.getRect(list);
      final rect = tester.getRect(row(index));
      return rect.top >= viewport.top - 0.5 &&
          rect.bottom <= viewport.bottom + 0.5;
    }

    int lastVisibleRow() {
      var last = -1;
      for (var index = 0; index < total; index++) {
        if (isVisible(index)) last = index;
      }
      return last;
    }

    void expectActive(int index) {
      expect(
        tester.getSemantics(list).label,
        contains('Result ${index + 1} of $total selected'),
      );
      expect(tester.widget<ListTile>(row(index)).selected, isTrue);
      expect(isVisible(index), isTrue, reason: 'active row ${index + 1}');
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('active-search-locator')))
            .label
            .split('\n')
            .first,
        'Search result ${index + 1} of $total',
      );
    }

    Future<void> step(String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await settle(tester);
    }

    Future<void> scrollListTo(double offset) async {
      tester
          .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)),
          )
          .position
          .jumpTo(offset);
      await tester.pump();
    }

    await tester.tap(row(0));
    await settle(tester);
    expectActive(0);

    // Next across the bottom edge of the list viewport.
    final bottom = lastVisibleRow();
    expect(bottom, greaterThan(0));
    for (var index = 0; index < bottom; index++) {
      await step('search-next');
    }
    expectActive(bottom);
    expect(isVisible(bottom + 1), isFalse);
    await step('search-next');
    expectActive(bottom + 1);
    expect(isVisible(bottom), isTrue, reason: 'scrolls only as necessary');

    // Previous across the top edge of the list viewport.
    final scrollable = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    await scrollListTo(
      position.pixels +
          tester.getRect(row(bottom + 1)).top -
          tester.getRect(list).top,
    );
    expect(isVisible(bottom + 1), isTrue);
    expect(isVisible(bottom), isFalse);
    await step('search-previous');
    expectActive(bottom);
    expect(isVisible(bottom + 1), isTrue, reason: 'scrolls only as necessary');

    // Next and Previous to rows that begin unmaterialized far from the list
    // viewport.
    final activeBeforeDistantNext = bottom;
    await scrollListTo(
      tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
    );
    expect(isBuilt(activeBeforeDistantNext + 1), isFalse);
    await step('search-next');
    expectActive(activeBeforeDistantNext + 1);

    final activeBeforeDistantPrevious = activeBeforeDistantNext + 1;
    await scrollListTo(
      tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
    );
    expect(isBuilt(activeBeforeDistantPrevious - 1), isFalse);
    await step('search-previous');
    expectActive(activeBeforeDistantPrevious - 1);

    // Wraparound destinations also begin unmaterialized at the far end.
    for (var index = activeBeforeDistantPrevious - 1; index > 0; index--) {
      await step('search-previous');
    }
    expectActive(0);
    await scrollListTo(0);
    expect(isBuilt(total - 1), isFalse);
    await step('search-previous');
    expectActive(total - 1);
    expect(isBuilt(0), isFalse);
    await step('search-next');
    expectActive(0);
  });

  Future<_ResultListProbe> openResultList(
    WidgetTester tester,
    List<String> paragraphs,
  ) async {
    useViewport(tester, const Size(1200, 500));
    await tester.pumpWidget(
      reader(MarkdownDocument.fromSource(paragraphs.join('\n\n'))),
    );
    await settle(tester);
    await openFromMenu(tester);
    await tester.enterText(
      find.byKey(const ValueKey('search-field')),
      'needle',
    );
    await tester.pump(const Duration(milliseconds: 151));
    await tester.pump();
    return _ResultListProbe(tester, paragraphs.length, settle);
  }

  Future<(_ResultListProbe, double)> openUniformResultList(
    WidgetTester tester,
  ) async {
    final probe = await openResultList(
      tester,
      List.generate(60, (index) => 'Paragraph $index carries needle text.'),
    );
    return (probe, tester.getRect(probe.row(0)).height);
  }

  testWidgets('results list Next reveals a row above the viewport', (
    tester,
  ) async {
    final (probe, rowHeight) = await openUniformResultList(tester);

    // An already-visible destination leaves the list offset unchanged.
    await probe.scrollTo(10 * rowHeight);
    await tester.tap(probe.row(10));
    await settle(tester);
    probe.expectActive(10);
    final stableOffset = probe.offset;
    await probe.step('search-next');
    probe.expectActive(11);
    expect(probe.offset, stableOffset, reason: 'visible row needs no scroll');

    // Next to a built row clipped by the top edge after the list was scrolled
    // past the active row.
    await probe.scrollTo(12 * rowHeight + rowHeight / 2);
    expect(probe.isBuilt(12), isTrue);
    expect(probe.isVisible(12), isFalse);
    expect(probe.rect(12).top, lessThan(probe.viewport.top));
    await probe.step('search-next');
    probe.expectActive(12);
    expect(probe.rect(12).top, moreOrLessEquals(probe.viewport.top));

    // Next to a row wholly above the viewport but laid out in the cache band.
    await probe.scrollTo(14 * rowHeight + 4);
    expect(probe.isOnstage(13), isFalse);
    expect(probe.isBuilt(13), isTrue);
    await probe.step('search-next');
    probe.expectActive(13);
    expect(probe.rect(13).top, moreOrLessEquals(probe.viewport.top));
  });

  testWidgets('results list Previous reveals a row below the viewport', (
    tester,
  ) async {
    final (probe, rowHeight) = await openUniformResultList(tester);

    // An already-visible destination leaves the list offset unchanged.
    await probe.scrollTo(30 * rowHeight);
    await tester.tap(probe.row(31));
    await settle(tester);
    probe.expectActive(31);
    final stableOffset = probe.offset;
    await probe.step('search-previous');
    probe.expectActive(30);
    expect(probe.offset, stableOffset, reason: 'visible row needs no scroll');

    // Previous to a built row clipped by the bottom edge after the list was
    // scrolled back before the active row.
    await probe.scrollTo(30 * rowHeight);
    await tester.tap(probe.row(30));
    await settle(tester);
    probe.expectActive(30);
    final listHeight = probe.viewport.height;
    await probe.scrollTo(29 * rowHeight + rowHeight / 2 - listHeight);
    expect(probe.isBuilt(29), isTrue);
    expect(probe.isVisible(29), isFalse);
    expect(probe.rect(29).bottom, greaterThan(probe.viewport.bottom));
    await probe.step('search-previous');
    probe.expectActive(29);
    expect(probe.rect(29).bottom, moreOrLessEquals(probe.viewport.bottom));

    // Previous to a row wholly below the viewport but laid out in the cache
    // band.
    await probe.scrollTo(28 * rowHeight - listHeight - 4);
    expect(probe.isOnstage(28), isFalse);
    expect(probe.isBuilt(28), isTrue);
    await probe.step('search-previous');
    probe.expectActive(28);
    expect(probe.rect(28).bottom, moreOrLessEquals(probe.viewport.bottom));
  });

  // Block-skewed row heights: 100 one-line results followed by 100 three-line
  // results, so the list's global average extent misplaces unbuilt rows.
  Future<void> expectUnbuiltRowRevealed(
    WidgetTester tester, {
    required int active,
    required String key,
    required bool listAtEnd,
  }) async {
    final filler = List.filled(24, 'filler words widen this row').join(' ');
    final probe = await openResultList(tester, [
      for (var index = 0; index < 200; index++)
        index < 100
            ? 'Paragraph $index carries needle text.'
            : 'Paragraph $index $filler needle $filler.',
    ]);
    await tester.scrollUntilVisible(
      probe.row(active),
      200,
      scrollable: find.descendant(
        of: probe.list,
        matching: find.byType(Scrollable),
      ),
    );
    await tester.ensureVisible(probe.row(active));
    await tester.pump();
    await tester.tap(probe.row(active));
    await settle(tester);
    probe.expectActive(active);

    final target = key == 'search-next' ? active + 1 : active - 1;
    await probe.scrollTo(listAtEnd ? probe.maxOffset : 0);
    expect(probe.isBuilt(target), isFalse, reason: 'row starts unbuilt');
    await probe.step(key);
    probe.expectActive(target);
    if (listAtEnd) {
      expect(probe.rect(target).top, moreOrLessEquals(probe.viewport.top));
    } else {
      expect(
        probe.rect(target).bottom,
        moreOrLessEquals(probe.viewport.bottom),
      );
    }
  }

  testWidgets('results list Next reveals an unbuilt row above skewed rows', (
    tester,
  ) async {
    await expectUnbuiltRowRevealed(
      tester,
      active: 99,
      key: 'search-next',
      listAtEnd: true,
    );
  });

  testWidgets(
    'results list Previous reveals an unbuilt row above skewed rows',
    (tester) async {
      await expectUnbuiltRowRevealed(
        tester,
        active: 117,
        key: 'search-previous',
        listAtEnd: true,
      );
    },
  );

  testWidgets('results list Next reveals an unbuilt row below skewed rows', (
    tester,
  ) async {
    await expectUnbuiltRowRevealed(
      tester,
      active: 117,
      key: 'search-next',
      listAtEnd: false,
    );
  });

  testWidgets(
    'results list Previous reveals an unbuilt row below skewed rows',
    (tester) async {
      await expectUnbuiltRowRevealed(
        tester,
        active: 140,
        key: 'search-previous',
        listAtEnd: false,
      );
    },
  );

  testWidgets('results list reveals varied-height rows from any list offset', (
    tester,
  ) async {
    const total = 45;
    final filler = List.filled(24, 'filler words widen this row').join(' ');
    final probe = await openResultList(
      tester,
      List.generate(
        total,
        (index) => index % 3 == 0
            ? 'Paragraph $index $filler needle $filler.'
            : 'Paragraph $index carries needle text.',
      ),
    );
    final heights = {
      for (var index = 0; index < total; index++)
        if (probe.isBuilt(index)) probe.rect(index).height,
    };
    expect(heights.length, greaterThan(1), reason: 'row heights must vary');

    await tester.tap(probe.row(0));
    await settle(tester);
    probe.expectActive(0);

    // Before each step, move the list to the far end, the start, or just past
    // the opposite edge of the active row, then step through both wraps.
    Future<void> sweep(String key, int delta) async {
      var active = probe.activeIndex;
      for (var step = 0; step < total + 3; step++) {
        final max = probe.maxOffset;
        switch (step % 4) {
          case 0:
            await probe.scrollTo(max);
          case 1:
            await probe.scrollTo(0);
          case 2:
            final rect = probe.rect(active);
            await probe.scrollTo(
              probe.offset + rect.bottom - probe.viewport.top + 4,
            );
          case 3:
            final rect = probe.rect(active);
            await probe.scrollTo(
              probe.offset - (probe.viewport.bottom - rect.top) - 4,
            );
        }
        await probe.step(key);
        active = (active + delta + total) % total;
        probe.expectActive(active);
      }
    }

    await sweep('search-next', 1);
    await sweep('search-previous', -1);
  });

  SemanticsData semanticsOf(WidgetTester tester, String key) =>
      tester.getSemantics(find.byKey(ValueKey(key))).getSemanticsData();

  Future<void> performSemanticsTap(WidgetTester tester, String key) async {
    final node = tester.getSemantics(find.byKey(ValueKey(key)));
    expect(
      node.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
      reason: '$key exposes a semantics tap action',
    );
    node.owner!.performAction(node.id, SemanticsAction.tap);
    await settle(tester);
  }

  String locatorLine(WidgetTester tester) => tester
      .getSemantics(find.byKey(const ValueKey('active-search-locator')))
      .label
      .split('\n')
      .first;

  testWidgets('compact navigator controls operate through semantics actions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    useViewport(tester, const Size(800, 700));
    await tester.pumpWidget(
      reader(
        MarkdownDocument.fromSource(
          'Needle one.\n\nNeedle two.\n\nNeedle three.',
        ),
      ),
    );
    await settle(tester);
    await openFromMenu(tester);
    await tester.enterText(
      find.byKey(const ValueKey('search-field')),
      'needle',
    );
    await tester.pump(const Duration(milliseconds: 151));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('search-result-0')));
    await settle(tester);
    expect(
      find.byKey(const ValueKey('compact-search-navigator')),
      findsOneWidget,
    );
    expect(locatorLine(tester), 'Search result 1 of 3');

    for (final key in const [
      'compact-search-previous',
      'compact-search-next',
    ]) {
      expect(
        semanticsOf(tester, key).flagsCollection.isEnabled,
        Tristate.isTrue,
        reason: '$key is enabled',
      );
    }

    await performSemanticsTap(tester, 'compact-search-next');
    expect(locatorLine(tester), 'Search result 2 of 3');
    await performSemanticsTap(tester, 'compact-search-previous');
    expect(locatorLine(tester), 'Search result 1 of 3');
    await performSemanticsTap(tester, 'compact-search-previous');
    expect(locatorLine(tester), 'Search result 3 of 3');

    await performSemanticsTap(tester, 'search-reopen-results');
    expect(find.byKey(const ValueKey('search-sheet')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('search-close')));
    await settle(tester);
    expect(find.byKey(const ValueKey('search-sheet')), findsNothing);

    await performSemanticsTap(tester, 'compact-search-close');
    expect(
      find.byKey(const ValueKey('compact-search-navigator')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('active-search-locator')), findsNothing);
    semantics.dispose();
  });

  testWidgets('disabled compact navigation is honest in semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final nodes = List.generate(3, (_) => FocusNode());
    addTearDown(() {
      for (final node in nodes) {
        node.dispose();
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CompactSearchNavigator(
              palette: ReaderPalette.light,
              result: null,
              activeMatchIndex: null,
              reopenFocusNode: nodes[0],
              previousFocusNode: nodes[1],
              nextFocusNode: nodes[2],
              onShowResults: () {},
              onPrevious: () {},
              onNext: () {},
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    for (final key in const [
      'compact-search-previous',
      'compact-search-next',
    ]) {
      final data = semanticsOf(tester, key);
      expect(data.flagsCollection.isEnabled, Tristate.isFalse, reason: key);
      expect(data.hasAction(SemanticsAction.tap), isFalse, reason: key);
    }
    for (final key in const ['search-reopen-results', 'compact-search-close']) {
      expect(
        semanticsOf(tester, key).hasAction(SemanticsAction.tap),
        isTrue,
        reason: key,
      );
    }
    semantics.dispose();
  });

  testWidgets('pane controls and result rows expose semantics tap actions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    useViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(
      reader(MarkdownDocument.fromSource('Needle one.\n\nNeedle two.')),
    );
    await settle(tester);
    await openFromMenu(tester);
    await tester.enterText(
      find.byKey(const ValueKey('search-field')),
      'needle',
    );
    await tester.pump(const Duration(milliseconds: 151));
    await tester.pump();
    for (final key in const [
      'search-previous',
      'search-next',
      'search-close',
      'search-result-0',
      'search-result-1',
    ]) {
      expect(
        semanticsOf(tester, key).hasAction(SemanticsAction.tap),
        isTrue,
        reason: key,
      );
    }
    semantics.dispose();
  });

  testWidgets('zero and overflow states disable navigation truthfully', (
    tester,
  ) async {
    useViewport(tester, const Size(1200, 800));
    final many = List.filled(20001, 'x').join(' ');
    await tester.pumpWidget(reader(MarkdownDocument.fromSource(many)));
    await settle(tester);
    await openFromMenu(tester);

    await tester.enterText(
      find.byKey(const ValueKey('search-field')),
      'absent',
    );
    await tester.pump(const Duration(milliseconds: 151));
    await tester.pump();
    expect(find.text('No results'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('search-previous')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('search-next')))
          .onPressed,
      isNull,
    );

    await tester.enterText(find.byKey(const ValueKey('search-field')), 'x');
    await tester.pump(const Duration(milliseconds: 151));
    await tester.pump();
    expect(
      find.text('20001 matches. Refine your search to navigate.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('search-next')))
          .onPressed,
      isNull,
    );
  });

  testWidgets(
    'render settings reuse the index and document replacement drops it',
    (tester) async {
      useViewport(tester, const Size(1200, 800));
      var indexBuilds = 0;
      const readerKey = ValueKey('stable-reader');
      final first = MarkdownDocument.fromSource('# First\n\nNeedle body.');
      await tester.pumpWidget(
        reader(first, key: readerKey, onSearchIndexBuilt: () => indexBuilds++),
      );
      await settle(tester);
      await openFromMenu(tester);
      await tester.enterText(
        find.byKey(const ValueKey('search-field')),
        'needle',
      );
      await tester.pump(const Duration(milliseconds: 151));
      await tester.pump();
      expect(indexBuilds, 1);

      await tester.pumpWidget(
        reader(
          first,
          key: readerKey,
          settings: const Settings(wrapCode: false),
          onSearchIndexBuilt: () => indexBuilds++,
        ),
      );
      await settle(tester);
      expect(find.text('needle'), findsOneWidget);
      expect(indexBuilds, 1);

      final second = MarkdownDocument.fromSource('# Second\n\nOther body.');
      await tester.pumpWidget(
        reader(second, key: readerKey, onSearchIndexBuilt: () => indexBuilds++),
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('search-pane')), findsNothing);
      await openFromMenu(tester);
      expect(indexBuilds, 2);
      expect(find.text('No query'), findsOneWidget);
    },
  );

  testWidgets('one non-colour locator covers representative rendered blocks', (
    tester,
  ) async {
    useViewport(tester, const Size(1200, 800));
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      reader(
        MarkdownDocument.fromSource('''
# Heading marker

Prose marker and `inline marker`.

```text
fenced marker
```

- list marker

| table marker | value |
| --- | --- |

![image marker](https://example.test/image-marker.png)
'''),
      ),
    );
    await settle(tester);
    await openFromMenu(tester);

    for (final query in [
      'Heading marker',
      'Prose marker',
      'inline marker',
      'fenced marker',
      'list marker',
      'table marker',
      'https://example.test/image-marker.png',
    ]) {
      await tester.enterText(find.byKey(const ValueKey('search-field')), query);
      await tester.pump(const Duration(milliseconds: 151));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('search-result-0')));
      await settle(tester);
      expect(
        find.byKey(const ValueKey('active-search-locator')),
        findsOneWidget,
        reason: query,
      );
      final node = tester.getSemantics(
        find.byKey(const ValueKey('active-search-locator')),
      );
      expect(node.label, contains('Search result 1 of 1'), reason: query);
      expect(node.flagsCollection.isSelected, Tristate.isTrue, reason: query);
    }
    semantics.dispose();
  });

  testWidgets('repeated matches in one block keep distinct ordinals', (
    tester,
  ) async {
    useViewport(tester, const Size(1200, 800));
    await tester.pumpWidget(
      reader(MarkdownDocument.fromSource('# Heading\n\nrepeat repeat repeat')),
    );
    await settle(tester);
    await openFromMenu(tester);
    await tester.enterText(
      find.byKey(const ValueKey('search-field')),
      'repeat',
    );
    await tester.pump(const Duration(milliseconds: 151));
    await tester.pump();

    expect(find.text('3 results'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('search-result-0')));
    await settle(tester);
    expect(find.text('Search result 1 of 3, Heading'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('search-next')));
    await settle(tester);
    expect(find.text('Search result 2 of 3, Heading'), findsOneWidget);
    expect(find.byKey(const ValueKey('active-search-locator')), findsOneWidget);
  });

  testWidgets(
    'Ctrl+F opens in-app search and touch targets remain at least 48',
    (tester) async {
      useViewport(tester, const Size(1200, 800));
      await tester.pumpWidget(
        reader(MarkdownDocument.fromSource('# Heading\n\nNeedle body.')),
      );
      await settle(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(find.byKey(const ValueKey('search-pane')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('search-close'))).width,
        48,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('search-next'))).height,
        48,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await settle(tester);
      expect(find.byKey(const ValueKey('search-pane')), findsOneWidget);

      useViewport(tester, const Size(390, 800));
      await settle(tester);
      expect(find.byKey(const ValueKey('search-sheet')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('search-close'))),
        const Size(48, 48),
      );
      await tester.tap(find.byKey(const ValueKey('search-close')));
      await settle(tester);
      for (final key in <String>[
        'search-reopen-results',
        'compact-search-previous',
        'compact-search-next',
        'compact-search-close',
      ]) {
        final size = tester.getSize(find.byKey(ValueKey(key)));
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
      }
      expect(
        find.bySemanticsLabel(RegExp(r'^Show search results\.')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Previous result'), findsOneWidget);
      expect(find.bySemanticsLabel('Next result'), findsOneWidget);
      expect(find.bySemanticsLabel('Close search'), findsOneWidget);
    },
  );

  testWidgets('menu places Search after Contents and before Appearance', (
    tester,
  ) async {
    useViewport(tester, const Size(1200, 900));
    await tester.pumpWidget(
      reader(MarkdownDocument.fromSource('# Heading\n\n## Section\n\nBody.')),
    );
    await settle(tester);
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await settle(tester);

    double y(String label) => tester.getTopLeft(find.text(label)).dy;
    expect(y('Contents'), lessThan(y('Search document')));
    expect(y('Search document'), lessThan(y('Appearance')));
  });

  testWidgets('menu keeps Search available without Contents or Han rows', (
    tester,
  ) async {
    useViewport(tester, const Size(500, 700));
    await tester.pumpWidget(
      reader(
        MarkdownDocument.fromSource('Plain English body without heading.'),
      ),
    );
    await settle(tester);
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await settle(tester);

    expect(find.text('Contents'), findsNothing);
    expect(find.text('Language'), findsNothing);
    expect(find.text('Search document'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Search document')).dy,
      lessThan(tester.getTopLeft(find.text('Appearance')).dy),
    );
  });

  testWidgets('short landscape menu scrolls with Contents and Han rows', (
    tester,
  ) async {
    useViewport(tester, const Size(700, 320));
    await tester.pumpWidget(
      reader(MarkdownDocument.fromSource('# 中文標題\n\nneedle body.')),
    );
    await settle(tester);
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await settle(tester);

    expect(find.text('Contents'), findsOneWidget);
    expect(find.text('Search document'), findsOneWidget);
    expect(find.text('Language'), findsOneWidget);
    final returnHome = find.text('Return to main', skipOffstage: false);
    expect(returnHome, findsOneWidget);
    await tester.ensureVisible(returnHome);
    await tester.pump();
    expect(find.text('Return to main'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile search sheet occupies the available width', (
    tester,
  ) async {
    useViewport(tester, const Size(390, 844));
    await tester.pumpWidget(
      reader(MarkdownDocument.fromSource('# Heading\n\nNeedle body.')),
    );
    await settle(tester);
    await openFromMenu(tester);

    expect(find.byKey(const ValueKey('search-sheet')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('search-sheet'))).width,
      390,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('modal sheet traverses results and controls in both directions', (
    tester,
  ) async {
    useViewport(tester, const Size(500, 700));
    await tester.pumpWidget(
      reader(
        MarkdownDocument.fromSource(
          '# First\n\nNeedle body.\n\n# Second\n\nAnother needle.',
        ),
      ),
    );
    await settle(tester);
    await openFromMenu(tester);
    await tester.enterText(
      find.byKey(const ValueKey('search-field')),
      'needle',
    );
    await tester.pump(const Duration(milliseconds: 151));
    await tester.pump();
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      'Search field',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expectPrimaryFocusInside(
      tester,
      find.byKey(const ValueKey('search-result-0')),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expectPrimaryFocusInside(
      tester,
      find.byKey(const ValueKey('search-result-1')),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      'Close search',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      'Search field',
    );

    await reverseTab(tester);
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      'Close search',
    );
    await reverseTab(tester);
    expectPrimaryFocusInside(
      tester,
      find.byKey(const ValueKey('search-result-1')),
    );
    await reverseTab(tester);
    expectPrimaryFocusInside(
      tester,
      find.byKey(const ValueKey('search-result-0')),
    );
    await reverseTab(tester);
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      'Search field',
    );
    expectPrimaryFocusInside(
      tester,
      find.byKey(const ValueKey('search-sheet')),
    );
    await tester.tap(find.byKey(const ValueKey('search-close')));
    await settle(tester);
    expect(find.byKey(const ValueKey('search-sheet')), findsNothing);
  });

  testWidgets('unavailable search exposes exact copy and no navigation', (
    tester,
  ) async {
    useViewport(tester, const Size(500, 700));
    final controller = TextEditingController(text: 'needle');
    final nodes = List.generate(5, (_) => FocusNode());
    final resultListNode = FocusNode();
    addTearDown(() {
      controller.dispose();
      for (final node in nodes) {
        node.dispose();
      }
      resultListNode.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: SearchSurface(
          mode: SearchSurfaceMode.sheet,
          palette: ReaderPalette.light,
          controller: controller,
          fieldFocusNode: nodes[0],
          resultFocusNode: nodes[1],
          resultListFocusNode: resultListNode,
          previousFocusNode: nodes[2],
          nextFocusNode: nodes[3],
          closeFocusNode: nodes[4],
          isPreparing: false,
          result: const DocumentSearchResult.unavailable('needle'),
          activeMatchIndex: null,
          onQueryChanged: (_) {},
          onSubmitted: (_) {},
          onSelect: (_) {},
          onPrevious: () {},
          onNext: () {},
          onClose: () {},
        ),
      ),
    );
    await tester.pump();

    expect(
      find.text('Search is unavailable for this document'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('search-result-list')), findsNothing);
    expect(find.byKey(const ValueKey('search-previous')), findsNothing);
    expect(find.byKey(const ValueKey('search-next')), findsNothing);
  });
}

/// Observes and drives the pane results list for active-row reveal tests.
class _ResultListProbe {
  _ResultListProbe(this.tester, this.total, this.settle);

  final WidgetTester tester;
  final int total;
  final Future<void> Function(WidgetTester) settle;

  Finder get list => find.byKey(const ValueKey('search-result-list'));

  Finder row(int index) => find.byKey(ValueKey('search-result-$index'));

  /// Includes rows laid out in the sliver's offstage cache band.
  Finder builtRow(int index) =>
      find.byKey(ValueKey('search-result-$index'), skipOffstage: false);

  ScrollPosition get _position => tester
      .state<ScrollableState>(
        find.descendant(of: list, matching: find.byType(Scrollable)),
      )
      .position;

  double get offset => _position.pixels;

  double get maxOffset => _position.maxScrollExtent;

  Rect get viewport => tester.getRect(list);

  Rect rect(int index) => tester.getRect(builtRow(index));

  /// Whether the row paints inside the list's paint region.
  bool isOnstage(int index) => row(index).evaluate().isNotEmpty;

  /// Whether the row is laid out, including the offstage cache band.
  bool isBuilt(int index) => builtRow(index).evaluate().isNotEmpty;

  bool isVisible(int index) {
    if (!isOnstage(index)) return false;
    final bounds = rect(index);
    return bounds.top >= viewport.top - 0.5 &&
        bounds.bottom <= viewport.bottom + 0.5;
  }

  int get activeIndex {
    final match = RegExp(
      r'Result (\d+) of \d+ selected',
    ).firstMatch(tester.getSemantics(list).label);
    return int.parse(match!.group(1)!) - 1;
  }

  void expectActive(int index) {
    expect(activeIndex, index);
    expect(isVisible(index), isTrue, reason: 'active row ${index + 1}');
    expect(tester.widget<ListTile>(row(index)).selected, isTrue);
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('active-search-locator')))
          .label
          .split('\n')
          .first,
      'Search result ${index + 1} of $total',
    );
  }

  Future<void> scrollTo(double value) async {
    _position.jumpTo(value.clamp(0, maxOffset));
    await tester.pump();
  }

  Future<void> step(String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await settle(tester);
  }
}
