import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/reader_screen.dart';
import 'package:markdown_viewer/store.dart';

import 'support/fake_storage.dart';

/// DF-052 CP2 — corrected active-occurrence-locator mechanism (plan.md §§C, D-1,
/// D-6). These target what the retained DF-041/CP1 suite does not: the
/// single-promoted-locator invariant across `ScrollablePositionedList`'s
/// transitioning two-list render (the B-1 duplicate-`GlobalKey` failure), the
/// duplicate-cell own-owner identity, remote-image run indication, the
/// responsive pane/sheet remount gates that remain mandatory under D-007, and the
/// one behavior deferred to DF-070.
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
    // The active-occurrence reveal chains a coarse block `scrollTo` (320ms), a
    // range-level `animateTo` (240ms, up to two passes) and — for sheet paths — a
    // modal-route dismissal, with interleaved `endOfFrame` waits before the single
    // locator is promoted and its range settled. Pump enough fixed frames to cover
    // the whole chain with margin (`pumpAndSettle` never quiesces — the search
    // field cursor blinks forever).
    await tester.pump();
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Widget reader(MarkdownDocument document) => MaterialApp(
    home: ReaderScreen(
      document: document,
      settings: const Settings(),
      onSettingsChanged: (_) {},
      onScriptPreferenceChanged: (_) {},
      onEdit: () {},
      onLoadFile: () {},
      onReturnHome: () {},
      onPositionChanged: (_) {},
    ),
  );

  Future<void> openFromMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await settle(tester);
    await tester.tap(find.text('Search document'));
    await settle(tester);
  }

  Future<void> query(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const ValueKey('search-field')), text);
    await tester.pump(const Duration(milliseconds: 151));
    await tester.pump();
  }

  const locatorKey = ValueKey('active-search-locator');

  String locatorLine(WidgetTester tester) =>
      tester.getSemantics(find.byKey(locatorKey)).label.split('\n').first;

  testWidgets(
    'Previous/Next across a far jump keeps exactly one locator (B-1 fix)',
    (tester) async {
      useViewport(tester, const Size(1200, 700));
      final source = StringBuffer('# Top\n\nfirst needle here.\n\n');
      for (var i = 0; i < 60; i++) {
        source.writeln('## Filler $i\n\nBody paragraph number $i.\n');
      }
      source.writeln('## Bottom\n\nlast needle there.\n');
      await tester.pumpWidget(reader(MarkdownDocument.fromSource('$source')));
      await settle(tester);
      await openFromMenu(tester);
      await query(tester, 'needle');

      // Activate the first, then jump to the far one and back. The far jump is
      // exactly the SPL two-list transition that crashed the single GlobalKey.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.byKey(locatorKey), findsOneWidget);
      expect(locatorLine(tester), 'Search result 1 of 2, Top');

      await tester.tap(find.byKey(const ValueKey('search-next')));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(locatorKey), findsOneWidget);
      expect(locatorLine(tester), 'Search result 2 of 2, Bottom');

      await tester.tap(find.byKey(const ValueKey('search-previous')));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(locatorKey), findsOneWidget);
      expect(locatorLine(tester), 'Search result 1 of 2, Top');
    },
  );

  testWidgets(
    'duplicate identical table cells get distinct active identity, one locator',
    (tester) async {
      useViewport(tester, const Size(1200, 700));
      await tester.pumpWidget(
        reader(
          MarkdownDocument.fromSource(
            '# Table\n\n| L | R |\n|---|---|\n| needle | needle |\n',
          ),
        ),
      );
      await settle(tester);
      await openFromMenu(tester);
      await query(tester, 'needle');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.byKey(locatorKey), findsOneWidget);
      expect(locatorLine(tester), 'Search result 1 of 2, Table');

      await tester.tap(find.byKey(const ValueKey('search-next')));
      await settle(tester);
      // The twin cell has identical text but a distinct structural owner id, so
      // the active moves to it and still exposes exactly one locator.
      expect(find.byKey(locatorKey), findsOneWidget);
      expect(locatorLine(tester), 'Search result 2 of 2, Table');
    },
  );

  testWidgets('remote-image URL run is a searchable own-owner occurrence', (
    tester,
  ) async {
    useViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(
      reader(
        MarkdownDocument.fromSource(
          '# Images\n\n![alt](https://example.com/needle-path.png)\n',
        ),
      ),
    );
    await settle(tester);
    await openFromMenu(tester);
    await query(tester, 'needle');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    // The full URL run owns its own occurrence and exposes the single locator
    // (decision.md D-004); its displayed URL text is present, not ellipsized.
    expect(find.byKey(locatorKey), findsOneWidget);
    expect(locatorLine(tester), startsWith('Search result 1 of 1'));
  });

  testWidgets('Escape clears the locator and indication together', (
    tester,
  ) async {
    useViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(
      reader(MarkdownDocument.fromSource('# Heading\n\nNeedle body here.')),
    );
    await settle(tester);
    await openFromMenu(tester);
    await query(tester, 'needle');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(find.byKey(locatorKey), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byKey(locatorKey), findsNothing);
    expect(find.byKey(const ValueKey('search-pane')), findsNothing);
  });

  testWidgets(
    'pane→sheet remount keeps one locator and does not steal Reader focus',
    (tester) async {
      useViewport(tester, const Size(1200, 800));
      await tester.pumpWidget(
        reader(MarkdownDocument.fromSource('# Heading\n\nA needle to find.')),
      );
      await settle(tester);
      await openFromMenu(tester); // pane mode (wide)
      expect(find.byKey(const ValueKey('search-pane')), findsOneWidget);
      await query(tester, 'needle');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.byKey(locatorKey), findsOneWidget);

      // Shrink below the pane breakpoint: the Reader remounts and the search
      // moves to a modal sheet. §D-6 re-reveals the range and re-promotes exactly
      // one locator behind the sheet; RC-3 keeps this a mandatory gate.
      useViewport(tester, const Size(800, 800));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('search-sheet')), findsOneWidget);
      expect(find.byKey(locatorKey), findsOneWidget);
      // Modal precedence: the Reader locator must never steal focus from the open
      // sheet (RC-3). Focus stays in the search UI, not on the Reader locator.
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        isNot('Active search result'),
      );
    },
  );

  testWidgets(
    'DF-070: physical focus returns to the Reader locator after responsive remount',
    (tester) async {
      // D-007 parks exactly this one behavior in DF-070: automatic physical
      // keyboard/AT focus RETURN to the active Reader locator after a responsive
      // pane/sheet remount. It is retained here as a known deferred expectation
      // (RC-5) — represented, not deleted and not asserted as working. The range
      // re-reveal, single-locator promotion, modal precedence and non-locator
      // role mappings all remain live gates (covered above and in the retained
      // DF-041/CP1 suite).
      useViewport(tester, const Size(800, 800));
      await tester.pumpWidget(
        reader(MarkdownDocument.fromSource('# Heading\n\nA needle to find.')),
      );
      await settle(tester);
      await openFromMenu(tester); // sheet mode (narrow)
      await query(tester, 'needle');
      await tester.tap(find.byKey(const ValueKey('search-result-0')));
      await settle(tester);

      // Grow above the pane breakpoint: the sheet moves back to the pane and the
      // Reader remounts. The parked behavior would land physical focus back on
      // the promoted Reader locator; it is not reliably restored.
      useViewport(tester, const Size(1200, 800));
      await settle(tester);
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        'Active search result',
      );
    },
    // DF-070: automatic physical locator-focus return after responsive
    // pane/sheet remount is deferred (decision.md D-007). Retained as known
    // deferred evidence; wider accessibility impact not yet established.
    // testWidgets only accepts a bool skip, so the reason lives in this comment.
    skip: true,
  );

  // --- §9 two-step reveal: the active occurrence's OWN rectangle, not merely its
  // owner/block, must reach the Reader viewport after activation and each
  // navigation, including a match deep inside a long owner (plan.md §9, RC-4).
  // These read public `RenderParagraph` geometry, so a genuine §18.8 geometry
  // failure surfaces here (the reveal controller's `_routeRevealStop` asserts)
  // rather than being hidden.

  testWidgets(
    'a deep active range is revealed within the viewport across nav actions',
    (tester) async {
      useViewport(tester, const Size(1200, 500)); // pane mode, short viewport
      String tall(String marker) =>
          '${List.generate(300, (i) => 'filler$i').join(' ')} $marker end.';
      final source = '# Doc\n\n${tall('ALPHANEEDLE')}\n\n${tall('BETANEEDLE')}\n';
      await tester.pumpWidget(reader(MarkdownDocument.fromSource(source)));
      await settle(tester);
      await openFromMenu(tester);
      await query(tester, 'needle');

      void expectRangeVisible(String ownerWord) {
        expect(find.byKey(locatorKey), findsOneWidget);
        final readerRect =
            tester.getRect(find.byKey(const ValueKey('reader-region')));
        final rect = _occurrenceRect(tester, ownerWord, 'NEEDLE');
        expect(
          rect.top,
          greaterThanOrEqualTo(readerRect.top - 0.5),
          reason: '$ownerWord range top within the viewport',
        );
        expect(
          rect.bottom,
          lessThanOrEqualTo(readerRect.bottom + 0.5),
          reason: '$ownerWord range bottom within the viewport',
        );
      }

      // Activation: the deep first occurrence's own rectangle is brought in.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(locatorLine(tester), 'Search result 1 of 2, Doc');
      expectRangeVisible('ALPHANEEDLE');

      // Next: the far, initially off-screen second occurrence is revealed.
      await tester.tap(find.byKey(const ValueKey('search-next')));
      await settle(tester);
      expect(locatorLine(tester), 'Search result 2 of 2, Doc');
      expectRangeVisible('BETANEEDLE');

      // Previous: back to the first occurrence's own rectangle.
      await tester.tap(find.byKey(const ValueKey('search-previous')));
      await settle(tester);
      expect(locatorLine(tester), 'Search result 1 of 2, Doc');
      expectRangeVisible('ALPHANEEDLE');

      // Shift+Enter from the field navigates backward (wraps to the last result).
      await tester.tap(find.byKey(const ValueKey('search-field')));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await settle(tester);
      expect(locatorLine(tester), 'Search result 2 of 2, Doc');
      expectRangeVisible('BETANEEDLE');
    },
  );

  testWidgets(
    'a deep active range is re-revealed within the viewport after remount',
    (tester) async {
      useViewport(tester, const Size(1200, 500)); // pane mode, short viewport
      final filler = List.generate(300, (i) => 'filler$i').join(' ');
      final source = '# Doc\n\n$filler ONLYNEEDLE end.\n';
      await tester.pumpWidget(reader(MarkdownDocument.fromSource(source)));
      await settle(tester);
      await openFromMenu(tester);
      await query(tester, 'needle');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.byKey(locatorKey), findsOneWidget);
      var readerRect =
          tester.getRect(find.byKey(const ValueKey('reader-region')));
      var rect = _occurrenceRect(tester, 'ONLYNEEDLE', 'NEEDLE');
      expect(rect.top, greaterThanOrEqualTo(readerRect.top - 0.5));
      expect(rect.bottom, lessThanOrEqualTo(readerRect.bottom + 0.5));

      // Shrink below the pane breakpoint: the Reader remounts and the search moves
      // to a sheet. §D-6 must re-reveal the active range against the re-wrapped
      // layout (a live gate under D-007; only physical focus return is deferred).
      useViewport(tester, const Size(800, 500));
      await settle(tester);
      expect(find.byKey(const ValueKey('search-sheet')), findsOneWidget);
      expect(find.byKey(locatorKey), findsOneWidget);
      readerRect = tester.getRect(find.byKey(const ValueKey('reader-region')));
      rect = _occurrenceRect(tester, 'ONLYNEEDLE', 'NEEDLE');
      expect(rect.top, greaterThanOrEqualTo(readerRect.top - 0.5));
      expect(rect.bottom, lessThanOrEqualTo(readerRect.bottom + 0.5));
    },
  );

  testWidgets('all matches are painted and the active one is distinct', (
    tester,
  ) async {
    useViewport(tester, const Size(1200, 800));
    await tester.pumpWidget(
      reader(
        MarkdownDocument.fromSource(
          '# H\n\nneedle one needle two needle three end.\n',
        ),
      ),
    );
    await settle(tester);
    await openFromMenu(tester);
    await query(tester, 'needle');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);

    final paragraph = _paragraphContaining(tester, 'needle one');
    final matchLeaves = <TextSpan>[];
    void walk(InlineSpan span) {
      if (span is TextSpan) {
        if (span.text == 'needle') matchLeaves.add(span);
        for (final child in span.children ?? const <InlineSpan>[]) {
          walk(child);
        }
      }
    }

    walk(paragraph.text);
    expect(matchLeaves.length, 3, reason: 'every occurrence is a painted piece');
    // All matches carry a background tint.
    for (final leaf in matchLeaves) {
      expect(leaf.style?.backgroundColor, isNotNull);
    }
    // Exactly one — the active (result 1) — is non-colour-only (weight+underline).
    final distinct = matchLeaves.where(
      (leaf) =>
          leaf.style?.fontWeight == FontWeight.w700 &&
          leaf.style?.decoration == TextDecoration.underline,
    );
    expect(distinct.length, 1);
  });

  testWidgets('Chinese and mixed runs are searchable and render exactly', (
    tester,
  ) async {
    useViewport(tester, const Size(1200, 800));
    await tester.pumpWidget(
      reader(MarkdownDocument.fromSource('# 标题\n\n这是中文needle混合文本。\n')),
    );
    await settle(tester);
    await openFromMenu(tester);
    await query(tester, '中文');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);

    expect(find.byKey(locatorKey), findsOneWidget);
    expect(locatorLine(tester), startsWith('Search result 1 of 1'));
    // The exact displayed sequence is preserved verbatim under the highlight
    // overlays; the mixed Latin/Chinese run is not altered by splitting (D-002).
    final paragraph = _paragraphContaining(tester, '这是中文');
    expect(
      paragraph.text.toPlainText(includeSemanticsLabels: false),
      '这是中文needle混合文本。',
    );
  });
}

/// The first materialized Reader `RenderParagraph` whose rendered text contains
/// [needle]. Scoped to the `reader-region` so the search pane/sheet result
/// snippets (which echo the same match context) are never mistaken for the
/// Reader's own occurrence owner.
RenderParagraph _paragraphContaining(WidgetTester tester, String needle) {
  final candidates = find.descendant(
    of: find.byKey(const ValueKey('reader-region')),
    matching: find.byType(RichText),
  );
  for (final element in candidates.evaluate()) {
    final object = element.renderObject;
    if (object is RenderParagraph &&
        object.text
            .toPlainText(includeSemanticsLabels: false)
            .contains(needle)) {
      return object;
    }
  }
  fail('no materialized Reader RenderParagraph contains "$needle"');
}

/// The global rectangle of the [needle] sub-range inside the owner paragraph
/// identified by [ownerWord], via public `RenderParagraph.getBoxesForSelection`.
Rect _occurrenceRect(WidgetTester tester, String ownerWord, String needle) {
  final paragraph = _paragraphContaining(tester, ownerWord);
  final text = paragraph.text.toPlainText(includeSemanticsLabels: false);
  final index = text.indexOf(needle);
  expect(index, greaterThanOrEqualTo(0));
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: index, extentOffset: index + needle.length),
  );
  expect(boxes, isNotEmpty);
  var local = boxes.first.toRect();
  for (final box in boxes.skip(1)) {
    local = local.expandToInclude(box.toRect());
  }
  return Rect.fromPoints(
    paragraph.localToGlobal(local.topLeft),
    paragraph.localToGlobal(local.bottomRight),
  );
}
