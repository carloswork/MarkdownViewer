import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/document_search.dart';
import 'package:markdown_viewer/markdown_theme.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/search_surface.dart';

// Public SearchSurface proof isolates list geometry from Reader navigation and
// focus restoration. The existing reveal bound is 64; four frames cover initial
// layout and final alignment, without real-time waits or a timing SLA.
const _frameBound = 68;

void main() {
  for (final mode in SearchSurfaceMode.values) {
    for (final scale in [Settings.minFontScale, 1.0, Settings.maxFontScale]) {
      testWidgets('fresh and same-index $mode reveal mixed rows at $scale', (
        tester,
      ) async {
        final harness = _Harness(tester, mode: mode, scale: scale);
        addTearDown(harness.dispose);
        for (final active in [1, 11, 99, 147]) {
          await harness.mount(active: null, total: 160, fresh: true);
          expect(harness.built(99), isFalse, reason: 'distant target unbuilt');
          final initialHeights = tester
              .widgetList<ListTile>(find.byType(ListTile))
              .map((tile) => tester.getRect(find.byKey(tile.key!)).height)
              .toSet();
          expect(initialHeights.length, greaterThan(1));
          await harness.mount(active: active, total: 160, fresh: true);
          final frames = await harness.complete(active);
          expect(frames, lessThanOrEqualTo(_frameBound));
          harness.expectSelected(active);
          expect(
            harness.resultFocus.hasFocus,
            isFalse,
            reason: 'reveal requests no row focus',
          );
          final offset = harness.position.pixels;
          await harness.mount(active: active, total: 160);
          await harness.quiescent(offset);
          await harness.remove();
          await harness.mount(active: active, total: 160, fresh: true);
          await harness.complete(active);
          harness.expectSelected(active);
        }
      });
    }
  }

  testWidgets('materialized clipped fresh row uses exactly the needed edge', (
    tester,
  ) async {
    final harness = _Harness(tester);
    addTearDown(harness.dispose);
    await harness.mount(active: null);
    final viewport = harness.viewport;
    final clipped = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .firstWhere((tile) {
          final r = tester.getRect(find.byKey(tile.key!));
          return r.top < viewport.bottom && r.bottom > viewport.bottom;
        });
    final index = int.parse(
      (clipped.key! as ValueKey<String>).value.split('-').last,
    );
    final requiredOffset =
        tester.getRect(find.byKey(clipped.key!)).bottom - viewport.bottom;
    expect(requiredOffset, greaterThan(0));
    await harness.mount(active: index, fresh: true);
    await harness.complete(index);
    expect(harness.position.pixels, closeTo(requiredOffset, 1));
    expect(harness.rect(index).bottom, closeTo(harness.viewport.bottom, 1));
  });

  testWidgets(
    'visible fresh row is a no-op; scrolling and rebuilds stay free',
    (tester) async {
      final harness = _Harness(tester);
      addTearDown(harness.dispose);
      await harness.mount(active: 1);
      await harness.complete(1);
      expect(harness.position.pixels, 0);
      harness.position.jumpTo(1200);
      await tester.pump();
      final offset = harness.position.pixels;
      await harness.mount(active: 1);
      await harness.quiescent(offset);
      expect(
        harness.visible(1),
        isFalse,
        reason: 'no continuous reveal policing',
      );
    },
  );

  for (final mode in SearchSurfaceMode.values) {
    testWidgets('short $mode viewport aligns oversized row leading edge', (
      tester,
    ) async {
      final harness = _Harness(tester, mode: mode, scale: 1.6, height: 280);
      addTearDown(harness.dispose);
      await harness.mount(active: 99);
      await harness.complete(99);
      expect(harness.rect(99).height, greaterThan(harness.viewport.height));
      expect(harness.rect(99).top, closeTo(harness.viewport.top, 1));
      expect(harness.rect(99).bottom, greaterThan(harness.viewport.bottom));
    });
  }

  testWidgets(
    'preparing and empty presentation mount a populated active list',
    (tester) async {
      final harness = _Harness(tester);
      addTearDown(harness.dispose);
      await harness.mount(active: 99, preparing: true);
      expect(harness.list, findsNothing);
      await harness.mount(active: 99);
      await harness.complete(99);
      await harness.mount(active: null, total: 0);
      expect(harness.list, findsNothing);
      await harness.mount(active: 11);
      await harness.complete(11);
    },
  );

  testWidgets(
    'pending reveal cancels on disposal, reset, shrink and supersession',
    (tester) async {
      final harness = _Harness(tester);
      addTearDown(harness.dispose);
      for (final cancel in [
        'dispose',
        'clear',
        'shrink',
        'null',
        'supersede',
      ]) {
        await harness.mount(active: 998, total: 1000, fresh: true);
        // First frame estimates a distant unbuilt target; a deferred continuation
        // is pending when the next public-surface update invalidates it.
        expect(harness.built(998), isFalse);
        switch (cancel) {
          case 'dispose':
            await harness.remove();
          case 'clear':
            await harness.mount(active: null, total: 0);
          case 'shrink':
            await harness.mount(active: 1, total: 4);
          case 'null':
            await harness.mount(active: null, total: 1000);
          case 'supersede':
            await harness.mount(active: 1, total: 1000);
            await harness.complete(1);
        }
        for (var frame = 0; frame < _frameBound; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.takeException(), isNull, reason: cancel);
        }
        if (cancel == 'shrink') {
          harness.expectSelected(1);
        }
        if (cancel == 'supersede') harness.expectSelected(1);
        expect(tester.binding.hasScheduledFrame, isFalse, reason: cancel);
      }
    },
  );

  testWidgets('near-cap distant fresh reveal is finite and remains virtualized', (
    tester,
  ) async {
    final harness = _Harness(tester);
    addTearDown(harness.dispose);
    // The near-cap fixture uses lightweight rows; mixed/skewed rows are proved
    // separately at modest size rather than multiplying long snippets 20,000x.
    await harness.mount(active: 19876, total: 20000);
    var peakLiveRows = 0;
    var completed = false;
    for (var frame = 0; frame < _frameBound; frame++) {
      peakLiveRows = peakLiveRows < find.byType(ListTile).evaluate().length
          ? find.byType(ListTile).evaluate().length
          : peakLiveRows;
      await tester.pump();
      if (harness.visible(19876)) {
        completed = true;
        break;
      }
    }
    expect(completed, isTrue);
    expect(peakLiveRows, lessThan(100), reason: 'not eager construction');
    await harness.complete(19876);
    harness.expectSelected(19876);
    await harness.quiescent(harness.position.pixels);
  });

  testWidgets(
    'labelled-list fallback stays focused after distant materialization',
    (tester) async {
      final harness = _Harness(tester, mode: SearchSurfaceMode.sheet);
      addTearDown(harness.dispose);
      await harness.mount(active: 987, total: 1000);
      expect(harness.resultFocus.context, isNull);
      // Exercise the existing unattached-row fallback, without adding production
      // scheduling or a test seam. Reveal must not migrate this list focus.
      harness.listFocus.requestFocus();
      await harness.complete(987);
      expect(harness.listFocus.hasFocus, isTrue);
      expect(harness.resultFocus.hasFocus, isFalse);
      expect(tester.binding.focusManager.primaryFocus, harness.listFocus);
      expect(
        tester.getSemantics(harness.list).label,
        contains('Result 988 of 1000 selected'),
      );
      await harness.quiescent(harness.position.pixels);
      // Attached-row branch is a separately observable mapping outcome.
      expect(harness.resultFocus.context, isNotNull);
      harness.resultFocus.requestFocus();
      await tester.pump();
      expect(tester.binding.focusManager.primaryFocus, harness.resultFocus);
      harness.expectSelected(987);
    },
  );
}

class _Harness {
  _Harness(
    this.tester, {
    this.mode = SearchSurfaceMode.pane,
    this.scale = 1,
    this.height = 500,
  });
  final WidgetTester tester;
  final SearchSurfaceMode mode;
  final double scale;
  final double height;
  final controller = TextEditingController(text: 'needle');
  final field = FocusNode(debugLabel: 'field', canRequestFocus: false);
  final resultFocus = FocusNode(debugLabel: 'selected result');
  final listFocus = FocusNode(debugLabel: 'labelled results list');
  final previous = FocusNode();
  final next = FocusNode();
  final close = FocusNode();
  int generation = 0;
  Finder get list => find.byKey(const ValueKey('search-result-list'));
  Finder row(int i) =>
      find.byKey(ValueKey('search-result-$i'), skipOffstage: false);
  bool built(int i) => row(i).evaluate().isNotEmpty;
  Rect rect(int i) => tester.getRect(row(i));
  Rect get viewport => tester.getRect(list);
  ScrollPosition get position => tester
      .state<ScrollableState>(
        find.descendant(of: list, matching: find.byType(Scrollable)),
      )
      .position;

  bool visible(int i) {
    if (!built(i)) return false;
    final r = rect(i);
    final v = viewport;
    return r.left >= v.left - 1 &&
        r.right <= v.right + 1 &&
        r.top >= v.top - 1 &&
        (r.height > v.height
            ? (r.top - v.top).abs() <= 1
            : r.bottom <= v.bottom + 1);
  }

  Future<void> mount({
    required int? active,
    int total = 160,
    bool fresh = false,
    bool preparing = false,
  }) async {
    if (fresh) generation++;
    final matches = List.generate(
      total,
      (i) => SearchMatch(
        ordinal: i + 1,
        blockIndex: i,
        runIndex: 0,
        start: 0,
        end: 6,
        heading: total > 1000 || i % 3 == 0 ? null : 'Heading $i',
        snippet: SearchSnippet(
          leading: total > 1000 || i % 3 == 0
              ? ''
              : 'Mixed height long context ' * 5,
          match: 'needle',
          trailing: total > 1000 || i % 3 == 0
              ? ''
              : ' more mixed height context' * 5,
          leadingTruncated: false,
          trailingTruncated: false,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 360,
              height: height,
              child: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: SearchSurface(
                  key: ValueKey(generation),
                  mode: mode,
                  palette: ReaderPalette.light,
                  controller: controller,
                  fieldFocusNode: field,
                  resultFocusNode: resultFocus,
                  resultListFocusNode: listFocus,
                  previousFocusNode: previous,
                  nextFocusNode: next,
                  closeFocusNode: close,
                  isPreparing: preparing,
                  result: DocumentSearchResult.available(
                    query: 'needle',
                    total: total,
                    matches: matches,
                  ),
                  activeMatchIndex: active,
                  onQueryChanged: (_) {},
                  onSubmitted: (_) {},
                  onSelect: (_) {},
                  onPrevious: () {},
                  onNext: () {},
                  onClose: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<int> complete(int i) async {
    for (var frame = 0; frame < _frameBound; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull);
      if (visible(i) && !tester.binding.hasScheduledFrame) return frame + 1;
    }
    fail('Result $i did not complete within $_frameBound layout frames');
  }

  void expectSelected(int i) {
    expect(
      visible(i),
      isTrue,
      reason: 'measured containment/oversized alignment',
    );
    expect(tester.widget<ListTile>(row(i)).selected, isTrue);
    expect(
      tester.getSemantics(row(i)).flagsCollection.isSelected,
      Tristate.isTrue,
    );
  }

  Future<void> quiescent(double expectedOffset) async {
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(position.pixels, closeTo(expectedOffset, 0.01));
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    }
  }

  Future<void> remove() =>
      tester.pumpWidget(const MaterialApp(home: SizedBox()));

  void dispose() {
    controller.dispose();
    for (final node in [field, resultFocus, listFocus, previous, next, close]) {
      node.dispose();
    }
  }
}
