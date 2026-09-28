import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/reader_screen.dart';
import 'package:markdown_viewer/store.dart';

import 'support/fake_storage.dart';

/// DF-052 CP1 Round 2 finding 1 — the Reader render/units/index cache must be
/// source-sensitive.
///
/// `_rebuildBlocksIfNeeded` keyed its early return on `id`/`updatedAt` (via the
/// document revision, compared by value) plus the layout-affecting render inputs
/// only. This proves a same-ID/same-timestamp `source` replacement — the case a
/// hash-free, id/time-only key silently kept stale — now rebuilds the visible
/// text, the captured units, and the Search index/results, while a pure render
/// input change (code wrap) preserves the revision and its already-built index
/// (plan.md §4.2, §5.5).
void main() {
  const wide = Size(1400, 900);

  // Same id and same updatedAt on both revisions: only `source` differs, which
  // is exactly the collision the id/time-only key could not see.
  final when = DateTime.utc(2026, 1, 1);
  MarkdownDocument docOf(String source) => MarkdownDocument(
    id: 'same-id',
    title: 'Doc',
    source: source,
    createdAt: when,
    updatedAt: when,
  );

  const sourceA = '# Doc\n\nkeepone alpha\n\ndropme beta\n';
  const sourceB = '# Doc\n\nkeepone alpha\n\nfreshtwo gamma\n';

  setUp(() async {
    await store.init(backend: MemoryBackend());
  });

  void useWide(WidgetTester tester) {
    tester.view.physicalSize = wide;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> settle(WidgetTester tester, {int frames = 8}) async {
    await tester.pump();
    for (var frame = 0; frame < frames; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  var indexBuilds = 0;

  Future<void> pump(
    WidgetTester tester,
    MarkdownDocument document, {
    Settings settings = const Settings(),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderScreen(
          document: document,
          settings: settings,
          onSettingsChanged: (_) {},
          onScriptPreferenceChanged: (_) {},
          onEdit: () {},
          onLoadFile: () {},
          onReturnHome: () {},
          onPositionChanged: (_) {},
          onSearchIndexBuilt: () => indexBuilds++,
        ),
      ),
    );
    await settle(tester);
  }

  List<String> paragraphTexts(WidgetTester tester) => tester.allRenderObjects
      .whereType<RenderParagraph>()
      .map((p) => p.text.toPlainText(includeSemanticsLabels: false))
      .toList();

  // Open via the menu rather than Ctrl+F: it does not depend on which node
  // currently holds keyboard focus, which is unspecified after a document
  // replacement discards the session.
  Future<void> openSearch(WidgetTester tester) async {
    await tester.tap(
      find.byIcon(Icons.more_horiz_rounded),
      warnIfMissed: false,
    );
    await settle(tester);
    await tester.tap(find.text('Search document'));
    await settle(tester);
  }

  Future<String> countFor(WidgetTester tester, String query) async {
    await tester.enterText(find.byKey(const ValueKey('search-field')), query);
    await tester.pump(const Duration(milliseconds: 151));
    await settle(tester);
    return tester
        .widget<Text>(find.byKey(const ValueKey('search-result-count')))
        .data!;
  }

  testWidgets(
    'a same-id/same-timestamp source change replaces text, units, index and '
    'Search truth; a render-input change preserves the built index',
    (tester) async {
      useWide(tester);
      indexBuilds = 0;

      // Revision A: the old source is rendered and searchable.
      await pump(tester, docOf(sourceA));
      expect(paragraphTexts(tester), contains('dropme beta'));
      expect(paragraphTexts(tester), isNot(contains('freshtwo gamma')));

      await openSearch(tester);
      expect(indexBuilds, 1, reason: 'the index is built once on open');
      expect(await countFor(tester, 'dropme'), '1 result');
      expect(await countFor(tester, 'freshtwo'), '0 results');

      // A pure render-input change (code wrap) shares revision A: the blocks
      // re-render but the already-built index/results survive it (§4.2).
      await pump(
        tester,
        docOf(sourceA),
        settings: const Settings(wrapCode: true),
      );
      expect(
        indexBuilds,
        1,
        reason: 'a render-input change must not discard the built index',
      );
      expect(await countFor(tester, 'dropme'), '1 result');

      // Revision B: same id, same updatedAt, changed source. The old key would
      // have returned early and kept revision A; now the render, units and index
      // all follow the new source.
      await pump(tester, docOf(sourceB));
      expect(
        paragraphTexts(tester),
        isNot(contains('dropme beta')),
        reason: 'removed source text must leave the visible render',
      );
      expect(
        paragraphTexts(tester),
        contains('freshtwo gamma'),
        reason: 'new source text must enter the visible render',
      );

      // The document change discarded the session; reopening rebuilds against
      // the new units, so Search truth now matches revision B.
      await openSearch(tester);
      expect(
        indexBuilds,
        2,
        reason: 'a source change must force a fresh index build',
      );
      expect(await countFor(tester, 'dropme'), '0 results');
      expect(await countFor(tester, 'freshtwo'), '1 result');
    },
  );
}
