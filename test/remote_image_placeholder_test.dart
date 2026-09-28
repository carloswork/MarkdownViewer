import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/blocks.dart';
import 'package:markdown_viewer/document_search.dart';
import 'package:markdown_viewer/markdown_theme.dart';
import 'package:markdown_viewer/reader_text_unit.dart';
import 'package:markdown_widget/markdown_widget.dart';

/// DF-052 CP1 Round 1 finding 2 (decision.md D-004): the searchable URL must be
/// fully presented, not ellipsized. `RemoteImagePlaceholder` now wraps the URL
/// across as many lines as needed, so no searchable literal is concealed. This
/// is a constrained-width long-URL regression proving suffix visibility and that
/// the captured (searchable) URL equals the visible URL.

const String longUrl =
    'https://example.test/very/long/path/segment-one/segment-two/'
    'segment-three/segment-four/segment-five/image-architecture-v2-final.png';

Widget _frame(Widget child, {required double width}) => MaterialApp(
  home: Scaffold(
    body: Center(child: SizedBox(width: width, child: child)),
  ),
);

void main() {
  testWidgets('a long remote URL is fully presented, not ellipsized', (
    tester,
  ) async {
    await tester.pumpWidget(
      _frame(
        RemoteImagePlaceholder(
          url: longUrl,
          alt: 'diagram',
          palette: ReaderPalette.light,
          onOpen: (_) {},
        ),
        // Deliberately narrow, so the URL must span several lines.
        width: 220,
      ),
    );
    await tester.pumpAndSettle();

    // The URL Text presents the whole string with no ellipsis truncation.
    final urlText = tester.widget<Text>(find.text(longUrl));
    expect(urlText.maxLines, isNull);
    expect(urlText.overflow, isNot(TextOverflow.ellipsis));

    final paragraph = tester.renderObject<RenderParagraph>(find.text(longUrl));
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: 'no content is clipped by a max-line limit',
    );

    // At this width the URL genuinely wraps to more than one visible line, so
    // the suffix that used to be ellipsized is now on screen.
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: longUrl.length),
    );
    final lineTops = boxes.map((b) => b.top.round()).toSet();
    expect(
      lineTops.length,
      greaterThan(1),
      reason: 'the long URL wraps rather than truncating',
    );
  });

  test('the captured (searchable) URL equals the fully presented URL', () {
    final capture = ReaderTextUnitCapture();
    MarkdownGenerator(
      generators: capture.generators,
      onNodeAccepted: capture.onNodeAccepted,
    ).buildWidgets(
      '![diagram]($longUrl)\n',
      config: buildMarkdownConfig(
        palette: ReaderPalette.light,
        wrapCode: false,
        onLinkTap: (_) {},
      ),
    );
    final units = capture.finish().units;
    final urlUnit = units.singleWhere(
      (u) => u.kind == UnitKind.image && u.text == longUrl,
    );
    // Search truth is exactly the URL the Reader now presents in full.
    expect(urlUnit.text, longUrl);
  });

  // DF-052 CP1 Round 2 finding 2 (D-004): the capture-to-mounted-owner proof.
  // The image placeholder draws its runs in three (remote) or two (non-remote)
  // distinct `RenderParagraph`s. This mounts the image through the same
  // MarkdownGenerator + capture pass the Reader runs, and asserts each captured
  // image unit equals its mounted `RenderParagraph.toPlainText` in document
  // order, with the search owner id and range identifying the same run.
  group('captured image units equal the mounted paragraphs (D-004)', () {
    final revision = DocumentRevision.fromDocument(
      id: 'img',
      updatedAt: DateTime.utc(2026, 1, 1),
      source: 'x',
    );

    (List<Widget>, ReaderTextUnitCaptureResult) buildImage(String source) {
      final capture = ReaderTextUnitCapture();
      final widgets =
          MarkdownGenerator(
            linesMargin: const EdgeInsets.symmetric(vertical: 5),
            generators: capture.generators,
            onNodeAccepted: capture.onNodeAccepted,
          ).buildWidgets(
            source,
            config: buildMarkdownConfig(
              palette: ReaderPalette.light,
              wrapCode: false,
              onLinkTap: (_) {},
            ),
          );
      return (widgets, capture.finish());
    }

    Widget frame(List<Widget> blocks) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 600,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: blocks,
            ),
          ),
        ),
      ),
    );

    // The image's text owners are its `Text` widgets (the broken-image `Icon`,
    // itself a `RichText`, is not a `Text`), read as their mounted
    // `RenderParagraph` in tree order.
    List<String> mountedParagraphs(WidgetTester tester) => [
      for (final element in find
          .descendant(
            of: find.byType(RemoteImagePlaceholder),
            matching: find.byType(Text),
          )
          .evaluate())
        (element.renderObject! as RenderParagraph).text.toPlainText(
          includeSemanticsLabels: false,
        ),
    ];

    Future<void> expectCaptureMatchesMount(
      WidgetTester tester,
      String source,
      List<String> expected,
    ) async {
      final (widgets, result) = buildImage(source);
      await tester.pumpWidget(frame(widgets));
      await tester.pumpAndSettle();

      final mounted = mountedParagraphs(tester);
      final imageUnits = result.units
          .where((u) => u.kind == UnitKind.image)
          .toList();

      // The mounted paragraphs are exactly the expected runs, in order.
      expect(mounted, expected, reason: 'mounted paragraphs, in order');
      // Each captured unit equals its mounted paragraph, in order — the
      // capture-to-mounted-owner equality the CP1 index feed depends on.
      expect(
        imageUnits.map((u) => u.text).toList(),
        mounted,
        reason: 'captured image units equal the mounted paragraphs',
      );

      // Owner and range identity: searching each run returns exactly one match,
      // owned by that unit, whose range reproduces the whole run.
      final index = DocumentSearchIndex.fromUnits(
        result.units,
        revision: revision,
        complete: result.isComplete,
      );
      for (final unit in imageUnits) {
        final found = index.searchRendered(
          unit.text,
          currentRevision: revision,
        );
        expect(found.total, 1, reason: 'one owner draws "${unit.text}"');
        final match = found.matches.single;
        expect(match.ownerId, unit.id, reason: 'match owner is the unit owner');
        expect(
          unit.text.substring(match.start, match.end),
          unit.text,
          reason: 'range covers the whole run',
        );
      }
    }

    testWidgets('a remote image: three captured units == three paragraphs', (
      tester,
    ) async {
      const url = 'https://example.test/pics/architecture-v2.png';
      await expectCaptureMatchesMount(tester, '![diagram alt]($url)\n', [
        'diagram alt',
        RemoteImagePlaceholder.remoteStatus,
        url,
      ]);
    });

    testWidgets('a non-remote image: two captured units == two paragraphs', (
      tester,
    ) async {
      await expectCaptureMatchesMount(
        tester,
        '![local alt](assets/pic.png)\n',
        ['local alt', RemoteImagePlaceholder.localStatus],
      );
    });
  });
}
