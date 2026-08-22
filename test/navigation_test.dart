import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/file_loader.dart';
import 'package:markdown_viewer/home_screen.dart';
import 'package:markdown_viewer/main.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/reader_screen.dart';

/// Covers the home/reader changes from Refinement Round 1.
///
/// These pump the two screens directly rather than the whole app. Driving the
/// full app requires a live Hive box, and a real file write started from inside
/// the widget-test fake-async zone never completes, which hangs teardown. The
/// store itself is covered by store_test.dart; the end-to-end round trip is a
/// manual check (see the plan's Step 6).
void main() {
  Widget host(Widget child) => MaterialApp(home: child);

  /// The reader keeps an animation alive via ScrollablePositionedList, so
  /// pumpAndSettle never returns once it is on screen.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('home screen', () {
    testWidgets('with no document, offers paste and load only', (tester) async {
      await tester.pumpWidget(
        host(
          HomeScreen(
            document: null,
            onContinue: () {},
            onPaste: () {},
            onLoadFile: () {},
            onOpenSettings: () {},
          ),
        ),
      );

      expect(find.text('Paste Markdown'), findsOneWidget);
      expect(find.text('Load from file'), findsOneWidget);
      expect(find.text('Continue reading'), findsNothing);
    });

    testWidgets('with a document, offers Continue reading with its identity', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          HomeScreen(
            document: MarkdownDocument.fromSource(
              '# Stored\n\nBody.',
              sourceName: 'sample_large_document.md',
            ),
            onContinue: () {},
            onPaste: () {},
            onLoadFile: () {},
            onOpenSettings: () {},
          ),
        ),
      );

      expect(find.text('Continue reading'), findsOneWidget);
      expect(find.text('sample_large_document.md'), findsOneWidget);
    });

    testWidgets('a pasted document shows the pasted label', (tester) async {
      await tester.pumpWidget(
        host(
          HomeScreen(
            document: MarkdownDocument.fromSource('# Stored\n\nBody.'),
            onContinue: () {},
            onPaste: () {},
            onLoadFile: () {},
            onOpenSettings: () {},
          ),
        ),
      );

      expect(find.text('Pasted document'), findsOneWidget);
    });

    testWidgets('actions are ordered continue, load, paste', (tester) async {
      // Round 2: Load from file is the practical way to open a long document,
      // especially on a phone, so it sits above Paste. Ordering is exactly the
      // kind of thing a later edit silently undoes.
      await tester.pumpWidget(
        host(
          HomeScreen(
            document: MarkdownDocument.fromSource('# Stored'),
            onContinue: () {},
            onPaste: () {},
            onLoadFile: () {},
            onOpenSettings: () {},
          ),
        ),
      );

      final continueY = tester.getTopLeft(find.text('Continue reading')).dy;
      final loadY = tester.getTopLeft(find.text('Load from file')).dy;
      final pasteY = tester.getTopLeft(find.text('Paste Markdown')).dy;

      expect(continueY, lessThan(loadY));
      expect(loadY, lessThan(pasteY));
    });

    testWidgets('without a document, load still sits above paste', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          HomeScreen(
            document: null,
            onContinue: () {},
            onPaste: () {},
            onLoadFile: () {},
            onOpenSettings: () {},
          ),
        ),
      );

      expect(
        tester.getTopLeft(find.text('Load from file')).dy,
        lessThan(tester.getTopLeft(find.text('Paste Markdown')).dy),
      );
    });

    testWidgets('each action fires its callback', (tester) async {
      var continued = 0;
      var pasted = 0;
      var loaded = 0;

      await tester.pumpWidget(
        host(
          HomeScreen(
            document: MarkdownDocument.fromSource('# Stored'),
            onContinue: () => continued++,
            onPaste: () => pasted++,
            onLoadFile: () => loaded++,
            onOpenSettings: () {},
          ),
        ),
      );

      await tester.tap(find.text('Continue reading'));
      await tester.tap(find.text('Paste Markdown'));
      await tester.tap(find.text('Load from file'));
      await tester.pump();

      expect(continued, 1);
      expect(pasted, 1);
      expect(loaded, 1);
    });
  });

  group('reader menu', () {
    Future<void> openMenu(
      WidgetTester tester,
      MarkdownDocument document, {
      VoidCallback? onReturnHome,
      VoidCallback? onLoadFile,
    }) async {
      await tester.pumpWidget(
        host(
          ReaderScreen(
            document: document,
            settings: const Settings(),
            onSettingsChanged: (_) {},
            onEdit: () {},
            onLoadFile: onLoadFile ?? () {},
            onReturnHome: onReturnHome ?? () {},
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await settle(tester);
    }

    testWidgets('shows a file-loaded document by filename', (tester) async {
      await openMenu(
        tester,
        MarkdownDocument.fromSource(
          '# Report\n\nBody.',
          sourceName: 'sample_large_document.md',
        ),
      );

      expect(find.text('sample_large_document.md'), findsOneWidget);
    });

    testWidgets('shows a pasted document as "Pasted document"', (tester) async {
      await openMenu(tester, MarkdownDocument.fromSource('# Report\n\nBody.'));

      expect(find.text('Pasted document'), findsOneWidget);
    });

    testWidgets('offers Edit local copy, not Edit Markdown', (tester) async {
      await openMenu(tester, MarkdownDocument.fromSource('# Report\n\nBody.'));

      expect(find.text('Edit local copy'), findsOneWidget);
      expect(find.text('Edit Markdown'), findsNothing);
    });

    testWidgets('offers Return to main and no longer Replace document', (
      tester,
    ) async {
      await openMenu(tester, MarkdownDocument.fromSource('# Report\n\nBody.'));

      expect(find.text('Return to main'), findsOneWidget);
      expect(find.text('Replace document'), findsNothing);
    });

    testWidgets('offers Load from file between edit and return home', (
      tester,
    ) async {
      // V1 polish: the reader gained a second entry point into the existing
      // load-from-file workflow, so a document can be swapped without going
      // back to Home first.
      await openMenu(tester, MarkdownDocument.fromSource('# Report\n\nBody.'));

      expect(find.text('Load from file'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Edit local copy')).dy,
        lessThan(tester.getTopLeft(find.text('Load from file')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Load from file')).dy,
        lessThan(tester.getTopLeft(find.text('Return to main')).dy),
      );
    });

    testWidgets('Load from file invokes the callback', (tester) async {
      var loads = 0;
      await openMenu(
        tester,
        MarkdownDocument.fromSource('# Report\n\nBody.'),
        onLoadFile: () => loads++,
      );

      await tester.tap(find.text('Load from file'));
      await settle(tester);

      expect(loads, 1);
    });

    testWidgets('Return to main invokes the callback', (tester) async {
      var returnedHome = 0;
      await openMenu(
        tester,
        MarkdownDocument.fromSource('# Report\n\nBody.'),
        onReturnHome: () => returnedHome++,
      );

      await tester.tap(find.text('Return to main'));
      await settle(tester);

      expect(returnedHome, 1);
    });
  });

  group('load-from-file replacement flow', () {
    // Round 2: the confirmation used to appear *before* the picker, asking the
    // user to discard a document before they had chosen a replacement.
    //
    // These drive the real app widget with the store left uninitialised: every
    // store call then short-circuits, so there is no file I/O to hang the
    // fake-async teardown, while the navigation and dialog logic is real.

    final existing = MarkdownDocument.fromSource(
      '# Existing\n\nBody.',
      sourceName: 'existing.md',
    );

    tearDown(() => pickMarkdownFile = openAndReadMarkdownFile);

    Future<void> openHomeWith(
      WidgetTester tester,
      MarkdownDocument? document,
    ) async {
      await tester.pumpWidget(
        MarkdownViewerApp(
          initialSettings: const Settings(),
          initialDocument: document,
        ),
      );
      await settle(tester);

      if (document != null) {
        // A stored document opens straight into the reader; go home first.
        await tester.tap(find.byIcon(Icons.more_horiz_rounded));
        await settle(tester);
        // With five entries the sheet can be taller than the default 800x600
        // test surface, so scroll it into view exactly as a user would on a
        // short viewport. The sheet is scrollable for precisely this reason.
        await tester.ensureVisible(find.text('Return to main'));
        await settle(tester);
        await tester.tap(find.text('Return to main'));
        await settle(tester);
      }
      expect(find.text('Load from file'), findsOneWidget);
    }

    Future<void> tapLoad(WidgetTester tester) async {
      await tester.tap(find.text('Load from file'));
      await settle(tester);
    }

    testWidgets('cancelling the picker changes nothing and asks nothing', (
      tester,
    ) async {
      pickMarkdownFile = () async => null;
      await openHomeWith(tester, existing);

      await tapLoad(tester);

      expect(find.text('Replace current document?'), findsNothing);
      expect(find.text('existing.md'), findsOneWidget);
    });

    testWidgets('an unsupported file is rejected without asking', (
      tester,
    ) async {
      pickMarkdownFile = () async =>
          throw const UnsupportedFileException('photo.png');
      await openHomeWith(tester, existing);

      await tapLoad(tester);

      expect(find.text('Replace current document?'), findsNothing);
      expect(find.textContaining('photo.png'), findsOneWidget);
      expect(find.text('existing.md'), findsOneWidget);
    });

    testWidgets('a whitespace-only file is rejected without asking', (
      tester,
    ) async {
      // The source rejects empty content before the confirmation, but no test
      // exercised that branch until the Round 2 review pointed it out.
      pickMarkdownFile = () async =>
          const LoadedFile(name: 'blank.md', contents: '   \n\n\t\n');
      await openHomeWith(tester, existing);

      await tapLoad(tester);

      expect(find.textContaining('is empty'), findsOneWidget);
      expect(find.text('Replace current document?'), findsNothing);
      expect(find.text('existing.md'), findsOneWidget);
    });

    testWidgets('a valid file asks only after it has been chosen', (
      tester,
    ) async {
      pickMarkdownFile = () async =>
          const LoadedFile(name: 'new.md', contents: '# New\n\nBody.');
      await openHomeWith(tester, existing);

      await tapLoad(tester);

      expect(find.text('Replace current document?'), findsOneWidget);
      // Scoped to the dialog: the home screen behind it also shows the name.
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('existing.md'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('cancelling the confirmation keeps the current document', (
      tester,
    ) async {
      pickMarkdownFile = () async =>
          const LoadedFile(name: 'new.md', contents: '# New\n\nBody.');
      await openHomeWith(tester, existing);
      await tapLoad(tester);

      await tester.tap(find.text('Cancel'));
      await settle(tester);

      expect(find.text('existing.md'), findsOneWidget);
      expect(find.text('new.md'), findsNothing);
    });

    testWidgets('confirming replaces the document and opens it', (
      tester,
    ) async {
      pickMarkdownFile = () async =>
          const LoadedFile(name: 'new.md', contents: '# New\n\nBody.');
      await openHomeWith(tester, existing);
      await tapLoad(tester);

      await tester.tap(find.text('Replace'));
      await settle(tester);

      expect(find.textContaining('New'), findsWidgets);
      expect(find.text('Load from file'), findsNothing); // in the reader now
    });

    testWidgets('with no document stored, nothing is asked at all', (
      tester,
    ) async {
      pickMarkdownFile = () async =>
          const LoadedFile(name: 'first.md', contents: '# First\n\nBody.');
      await openHomeWith(tester, null);

      await tapLoad(tester);

      expect(find.text('Replace current document?'), findsNothing);
      expect(find.textContaining('First'), findsWidgets);
    });
  });

  group('reader menu load-from-file', () {
    // The reader is a second entry point into the SAME workflow Home uses.
    // These prove it reaches the existing branches rather than a second copy of
    // the picker/validation/confirmation logic.

    final existing = MarkdownDocument.fromSource(
      '# Existing\n\nBody.',
      sourceName: 'existing.md',
    );

    tearDown(() => pickMarkdownFile = openAndReadMarkdownFile);

    Future<void> loadFromReader(WidgetTester tester) async {
      await tester.pumpWidget(
        MarkdownViewerApp(
          initialSettings: const Settings(),
          initialDocument: existing,
        ),
      );
      await settle(tester);

      // Starts in the reader, not Home.
      expect(find.textContaining('Existing'), findsWidgets);

      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await settle(tester);
      await tester.tap(find.text('Load from file'));
      await settle(tester);
    }

    testWidgets('cancelling the picker leaves the reader untouched', (
      tester,
    ) async {
      pickMarkdownFile = () async => null;

      await loadFromReader(tester);

      expect(find.text('Replace current document?'), findsNothing);
      expect(find.textContaining('Existing'), findsWidgets);
    });

    testWidgets('a valid file asks for replacement confirmation', (
      tester,
    ) async {
      pickMarkdownFile = () async =>
          const LoadedFile(name: 'new.md', contents: '# New\n\nBody.');

      await loadFromReader(tester);

      expect(find.text('Replace current document?'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('existing.md'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('cancelling the confirmation keeps the current document', (
      tester,
    ) async {
      pickMarkdownFile = () async =>
          const LoadedFile(name: 'new.md', contents: '# New\n\nBody.');

      await loadFromReader(tester);
      await tester.tap(find.text('Cancel'));
      await settle(tester);

      expect(find.textContaining('Existing'), findsWidgets);
      expect(find.textContaining('New'), findsNothing);
    });

    testWidgets('confirming replaces the document in place', (tester) async {
      pickMarkdownFile = () async =>
          const LoadedFile(name: 'new.md', contents: '# New\n\nBody.');

      await loadFromReader(tester);
      await tester.tap(find.text('Replace'));
      await settle(tester);

      // Stays in the reader with the new document; no trip through Home.
      expect(find.textContaining('New'), findsWidgets);
      expect(find.text('Continue reading'), findsNothing);
    });

    testWidgets('an unsupported file is rejected without asking', (
      tester,
    ) async {
      pickMarkdownFile = () async =>
          throw const UnsupportedFileException('photo.png');

      await loadFromReader(tester);

      expect(find.text('Replace current document?'), findsNothing);
      expect(find.textContaining('photo.png'), findsOneWidget);
      expect(find.textContaining('Existing'), findsWidgets);
    });
  });

  group('markdown file names', () {
    test('accepts the usual Markdown extensions', () {
      for (final name in [
        'a.md',
        'A.MD',
        'notes.markdown',
        'x.mdown',
        'y.mkd',
        'plain.txt',
        'sample_large_document.md',
      ]) {
        expect(isMarkdownFileName(name), isTrue, reason: name);
      }
    });

    test('rejects everything else', () {
      for (final name in [
        'image.png',
        'archive.zip',
        'noextension',
        'trailingdot.',
        'doc.pdf',
      ]) {
        expect(isMarkdownFileName(name), isFalse, reason: name);
      }
    });
  });
}
