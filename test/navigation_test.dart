import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/file_loader.dart';
import 'package:markdown_viewer/han_script.dart';
import 'package:markdown_viewer/home_screen.dart';
import 'package:markdown_viewer/main.dart';
import 'package:markdown_viewer/markdown_theme.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/print_fonts.dart';
// The print surface is behind a conditional import: in a VM test
// `print_surface.dart` resolves to exactly this library, so the mounts recorded
// here are the ones ReaderScreen made.
import 'package:markdown_viewer/print_surface_stub.dart';
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

  /// A viewport tall enough to show the whole reader menu at once.
  ///
  /// The real app theme sets `showDragHandle: true`, and a document with a
  /// table of contents fills the sheet with six tiles plus a handle. On the
  /// 800x600 default that is taller than a modal sheet is allowed to be, and
  /// `Language` - the second-to-last tile - sits below the fold. That is
  /// exactly the case `_ReaderMenu`'s `SingleChildScrollView` exists for, so it
  /// is correct app behaviour; widening the viewport keeps these tests about
  /// the menu and the re-render rather than about scrolling a sheet.
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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
            onScriptPreferenceChanged: (_) {},
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

  // ---------------------------------------------------------------------------
  // DF-031 CP-B — the `Language` tile, its sheet, and the menu order.
  // ---------------------------------------------------------------------------
  group('reader menu language tile', () {
    Future<void> openMenu(
      WidgetTester tester,
      MarkdownDocument document, {
      ValueChanged<DocumentScriptPreference>? onScriptPreferenceChanged,
    }) async {
      useTallViewport(tester);
      await tester.pumpWidget(
        host(
          ReaderScreen(
            document: document,
            settings: const Settings(),
            onSettingsChanged: (_) {},
            onScriptPreferenceChanged: onScriptPreferenceChanged ?? (_) {},
            onEdit: () {},
            onLoadFile: () {},
            onReturnHome: () {},
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await settle(tester);
    }

    testWidgets('is labelled Language, not Script rendering', (tester) async {
      await openMenu(tester, _traditionalDocument());

      expect(find.text('Language'), findsOneWidget);
      expect(find.text('Script rendering'), findsNothing);
      expect(find.text('Chinese rendering'), findsNothing);
    });

    testWidgets('is present for a document containing shipped Han', (
      tester,
    ) async {
      await openMenu(tester, _traditionalDocument());
      expect(find.text('Language'), findsOneWidget);
    });

    testWidgets('is absent for an English-only document', (tester) async {
      await openMenu(tester, MarkdownDocument.fromSource(_kEnglishSource));

      expect(find.text('Language'), findsNothing);
      // And the rest of the menu looks exactly as it did before DF-031.
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Edit local copy'), findsOneWidget);
      expect(find.text('Load from file'), findsOneWidget);
      expect(find.text('Return to main'), findsOneWidget);
    });

    testWidgets('is absent when the only Han lies outside both repertoires', (
      tester,
    ) async {
      // R15: the control is absent in the one case a confused user might go
      // looking for it. Correct in effect - the preference cannot fix tofu -
      // and recorded rather than hidden.
      await openMenu(
        tester,
        MarkdownDocument.fromSource(
          '# Doc\n\n${String.fromCharCodes(<int>[0x4E0F, 0x4E2E, 0x4E31])}',
        ),
      );
      expect(find.text('Language'), findsNothing);
    });

    testWidgets('subtitle reads Automatic — Traditional Chinese under auto', (
      tester,
    ) async {
      await openMenu(tester, _traditionalDocument());

      expect(find.text('Automatic — Traditional Chinese'), findsOneWidget);
      expect(
        find.text('Traditional Chinese'),
        findsNothing,
        reason: 'an inferred convention must not read as a chosen one',
      );
    });

    testWidgets('subtitle reads Automatic — Simplified Chinese under auto', (
      tester,
    ) async {
      await openMenu(tester, _simplifiedDocument());

      expect(find.text('Automatic — Simplified Chinese'), findsOneWidget);
      expect(find.text('Simplified Chinese'), findsNothing);
    });

    testWidgets('subtitle reads the bare label under an explicit selection', (
      tester,
    ) async {
      await openMenu(
        tester,
        _traditionalDocument(
          preference: DocumentScriptPreference.simplifiedChinese,
        ),
      );

      expect(find.text('Simplified Chinese'), findsOneWidget);
      expect(find.text('Automatic — Simplified Chinese'), findsNothing);
      expect(find.text('Automatic — Traditional Chinese'), findsNothing);
    });

    // -------------------------------------------------------------------------
    // Menu order, asserted explicitly. §1.7 UX-3 is a product constraint, and
    // nothing else in the suite would catch a later reordering.
    // -------------------------------------------------------------------------
    void expectMenuOrder(WidgetTester tester, {required bool hasToc}) {
      double y(String label) => tester.getTopLeft(find.text(label)).dy;

      if (hasToc) {
        expect(find.text('Contents'), findsOneWidget);
        expect(y('Contents'), lessThan(y('Appearance')));
      } else {
        expect(find.text('Contents'), findsNothing);
      }
      expect(y('Appearance'), lessThan(y('Edit local copy')));
      expect(y('Edit local copy'), lessThan(y('Load from file')));
      // The insertion point: after the high-frequency Load from file...
      expect(
        y('Load from file'),
        lessThan(y('Language')),
        reason: 'Language must not push Load from file down the menu (UX-3)',
      );
      // ...and before the terminal navigation action, which stays last.
      expect(
        y('Language'),
        lessThan(y('Return to main')),
        reason: 'Return to main is terminal navigation and remains last',
      );
    }

    testWidgets('order is Contents, Appearance, Edit, Load, Language, Return '
        'when the document has a table of contents', (tester) async {
      await openMenu(tester, _traditionalDocument(withHeadings: true));

      expectMenuOrder(tester, hasToc: true);
    });

    testWidgets('order is Appearance, Edit, Load, Language, Return when the '
        'document has no table of contents', (tester) async {
      await openMenu(tester, MarkdownDocument.fromSource(_kTraditionalSample));

      expectMenuOrder(tester, hasToc: false);
    });

    // -------------------------------------------------------------------------
    // The sheet.
    // -------------------------------------------------------------------------
    Future<void> openSheet(
      WidgetTester tester,
      MarkdownDocument document, {
      ValueChanged<DocumentScriptPreference>? onChanged,
    }) async {
      await openMenu(tester, document, onScriptPreferenceChanged: onChanged);
      await tester.tap(find.text('Language'));
      await settle(tester);
    }

    testWidgets('offers exactly Auto, Traditional Chinese and Simplified '
        'Chinese', (tester) async {
      await openSheet(tester, _traditionalDocument());

      expect(
        find.byType(RadioListTile<DocumentScriptPreference>),
        findsNWidgets(3),
      );
      expect(find.text('Auto'), findsOneWidget);
      expect(find.text('Traditional Chinese'), findsOneWidget);
      expect(find.text('Simplified Chinese'), findsOneWidget);
    });

    testWidgets('shows the current selection and the detected result under '
        'Auto', (tester) async {
      await openSheet(tester, _traditionalDocument());

      List<RadioListTile<DocumentScriptPreference>> rows() => tester
          .widgetList<RadioListTile<DocumentScriptPreference>>(
            find.byType(RadioListTile<DocumentScriptPreference>),
          )
          .toList();

      final group = tester.widget<RadioGroup<DocumentScriptPreference>>(
        find.byType(RadioGroup<DocumentScriptPreference>),
      );
      expect(group.groupValue, DocumentScriptPreference.auto);
      expect(rows().map((r) => r.value).toList(), <DocumentScriptPreference>[
        DocumentScriptPreference.auto,
        DocumentScriptPreference.traditionalChinese,
        DocumentScriptPreference.simplifiedChinese,
      ]);

      expect(find.text('Detected: Traditional Chinese'), findsOneWidget);
      // Subordinate text under Auto only - the explicit rows carry no subtitle.
      expect(rows()[1].subtitle, isNull);
      expect(rows()[2].subtitle, isNull);
    });

    testWidgets('the detected subtitle names what the detector returns for '
        'this document', (tester) async {
      await openSheet(tester, _simplifiedDocument());
      expect(find.text('Detected: Simplified Chinese'), findsOneWidget);
      expect(find.text('Detected: Traditional Chinese'), findsNothing);
    });

    testWidgets('an explicit preference is shown as the current selection', (
      tester,
    ) async {
      await openSheet(
        tester,
        _traditionalDocument(
          preference: DocumentScriptPreference.simplifiedChinese,
        ),
      );

      final group = tester.widget<RadioGroup<DocumentScriptPreference>>(
        find.byType(RadioGroup<DocumentScriptPreference>),
      );
      expect(group.groupValue, DocumentScriptPreference.simplifiedChinese);
      // Auto still names the detector's answer, not the override.
      expect(find.text('Detected: Traditional Chinese'), findsOneWidget);
    });

    testWidgets('selecting a value fires the callback, live, with no OK step', (
      tester,
    ) async {
      final fired = <DocumentScriptPreference>[];
      await openSheet(tester, _traditionalDocument(), onChanged: fired.add);

      expect(find.text('OK'), findsNothing);
      expect(find.text('Cancel'), findsNothing);
      expect(find.text('Save'), findsNothing);

      await tester.tap(find.text('Simplified Chinese'));
      await settle(tester);

      expect(fired, <DocumentScriptPreference>[
        DocumentScriptPreference.simplifiedChinese,
      ]);
    });

    testWidgets('selecting Auto restores detection', (tester) async {
      final fired = <DocumentScriptPreference>[];
      await openSheet(
        tester,
        _traditionalDocument(
          preference: DocumentScriptPreference.simplifiedChinese,
        ),
        onChanged: fired.add,
      );

      await tester.tap(find.text('Auto'));
      await settle(tester);

      expect(fired, <DocumentScriptPreference>[DocumentScriptPreference.auto]);
      // There is no separate reset affordance: Auto is a first-class,
      // visibly-selected state rather than an absence of choice.
      expect(find.text('Reset'), findsNothing);
    });
  });

  // ---------------------------------------------------------------------------
  // §5.6.6 — changing the language is a re-render, not a reload.
  // ---------------------------------------------------------------------------
  group('changing the language re-renders in place', () {
    testWidgets('the reader is not remounted, updatedAt is unchanged, and the '
        'rendered chain does change', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(const _PreferenceHost());
      await settle(tester);

      final hostState = tester.state<_PreferenceHostState>(
        find.byType(_PreferenceHost),
      );
      final documentBefore = hostState.document;
      final readerStateBefore = tester.state(find.byType(ReaderScreen));
      final keyBefore = tester
          .widget<ReaderScreen>(find.byType(ReaderScreen))
          .key;

      // The rendered chain, read off the fenced-code block the document carries.
      List<String>? renderedCodeChain() => tester
          .widget<Text>(find.text(_kCodeMarker))
          .style
          ?.fontFamilyFallback;

      expect(renderedCodeChain(), codeFontFallbackFor(HanScript.hant));

      // Drive the real control, exactly as a user would.
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await settle(tester);
      await tester.tap(find.text('Language'));
      await settle(tester);
      await tester.tap(find.text('Simplified Chinese'));
      await settle(tester);

      final documentAfter = hostState.document;

      // 1. The preference was applied and persisted through the write path.
      expect(
        documentAfter.scriptPreference,
        DocumentScriptPreference.simplifiedChinese,
      );

      // 2. `updatedAt` is unchanged - the trap §5.6.6 names explicitly.
      expect(documentAfter.updatedAt, documentBefore.updatedAt);
      expect(documentAfter.id, documentBefore.id);

      // 3. ReaderScreen is NOT remounted. The same State instance and an
      //    unchanged ValueKey are what actually preserve the reading position,
      //    and they are checkable here where a pixel offset is not.
      expect(
        tester.state(find.byType(ReaderScreen)),
        same(readerStateBefore),
        reason:
            'a new State instance means the reader was remounted and the '
            'reading position was thrown away',
      );
      expect(
        tester.widget<ReaderScreen>(find.byType(ReaderScreen)).key,
        keyBefore,
      );

      // 4. The rendered chain DID change, so `_blocksKey` was demonstrably
      //    rebuilt - §5.5 fact 2. Without the resolved script in that key this
      //    assertion fails while everything else still passes, which is exactly
      //    the silent wrongness the plan warns about.
      expect(renderedCodeChain(), codeFontFallbackFor(HanScript.hans));
      expect(renderedCodeChain(), isNot(codeFontFallbackFor(HanScript.hant)));

      // 5. Nothing was reloaded or re-pushed: one route, one save, no re-read.
      expect(hostState.saves, 1);
      expect(hostState.reloads, 0);
      expect(find.byType(ReaderScreen), findsOneWidget);
    });

    testWidgets('reopening the menu then shows the explicit state', (
      tester,
    ) async {
      useTallViewport(tester);
      await tester.pumpWidget(const _PreferenceHost());
      await settle(tester);

      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await settle(tester);
      expect(find.text('Automatic — Traditional Chinese'), findsOneWidget);
      await tester.tap(find.text('Language'));
      await settle(tester);
      await tester.tap(find.text('Traditional Chinese'));
      await settle(tester);
      // Close the sheet.
      await tester.tapAt(const Offset(400, 20));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await settle(tester);

      expect(find.text('Traditional Chinese'), findsOneWidget);
      expect(find.text('Automatic — Traditional Chinese'), findsNothing);
    });

    testWidgets('selecting Auto again clears the override and detection '
        'resumes', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(
        const _PreferenceHost(
          preference: DocumentScriptPreference.simplifiedChinese,
        ),
      );
      await settle(tester);

      final hostState = tester.state<_PreferenceHostState>(
        find.byType(_PreferenceHost),
      );

      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await settle(tester);
      await tester.tap(find.text('Language'));
      await settle(tester);
      await tester.tap(find.text('Auto'));
      await settle(tester);

      expect(
        hostState.document.scriptPreference,
        DocumentScriptPreference.auto,
      );
      // Detection resumed against the effective source, which is unambiguously
      // Traditional - so the assertion has a determinate expected value rather
      // than being vacuously satisfied by the §5.4.3 default.
      expect(resolveHanScriptForDocument(hostState.document), HanScript.hant);
      expect(
        tester.widget<Text>(find.text(_kCodeMarker)).style?.fontFamilyFallback,
        codeFontFallbackFor(HanScript.hant),
      );
    });

    // REPLACED AT CP-C, as the test it replaces said it would be.
    //
    // The CP-B test here was structural, and said so: `mountPrintSurface` took
    // only the source, so remounting on a preference change produced an
    // identical print surface and no widget test could tell the comparison
    // from its absence. It pinned the comparison until CP-C made it
    // load-bearing. CP-C threads the resolved script through that signature,
    // so the property is now asserted behaviourally instead - the remount is
    // observable, and it carries the new chain.
    testWidgets('changing the preference re-mounts the print surface with the '
        'newly resolved chain (§5.5 fact 3)', (tester) async {
      useTallViewport(tester);
      resetPrintSurfaceMounts();
      await tester.pumpWidget(const _PreferenceHost());
      await settle(tester);

      // The reader mounted the print surface once, with the detected script.
      expect(printSurfaceMountCount, 1);
      expect(lastPrintSurfaceMount!.script, HanScript.hant);

      // Drive the real control, exactly as a user would.
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await settle(tester);
      await tester.tap(find.text('Language'));
      await settle(tester);
      await tester.tap(find.text('Simplified Chinese'));
      await settle(tester);

      // 1. It re-mounted. Without the preference in `didUpdateWidget`'s
      //    comparison this stays at 1: a preference change deliberately does
      //    not move `id`, `updatedAt` or `source`.
      expect(
        printSurfaceMountCount,
        2,
        reason:
            'the print surface must be re-mounted when the preference changes',
      );

      // 2. It re-mounted with the NEW resolved script, not the old one. This
      //    is the parity break §6 exists to prevent: print keeping the previous
      //    chain while the Viewer shows the new one.
      expect(lastPrintSurfaceMount!.script, HanScript.hans);

      final hostState = tester.state<_PreferenceHostState>(
        find.byType(_PreferenceHost),
      );
      expect(lastPrintSurfaceMount!.markdownSource, hostState.document.source);

      // 3. The stacks built from what print was handed lead with the pack the
      //    user chose.
      expect(
        printProportionalStack(lastPrintSurfaceMount!.script),
        '"DF026Roboto", "DF026Emoji", "DF026Mono", "DF031Hans", '
        '"DF031Hant", sans-serif',
      );
      expect(
        printMonospaceStack(lastPrintSurfaceMount!.script),
        '"DF026Mono", "DF026Emoji", "DF031Hans", "DF031Hant", monospace',
      );
    });

    for (final entry in <DocumentScriptPreference, HanScript>{
      DocumentScriptPreference.auto: HanScript.hant,
      DocumentScriptPreference.simplifiedChinese: HanScript.hans,
      DocumentScriptPreference.traditionalChinese: HanScript.hant,
    }.entries) {
      testWidgets('print and the Viewer take one resolution under '
          '${entry.key.name}', (tester) async {
        // §12 CP-C item 1. The host document is unambiguously Traditional, so
        // under `simplifiedChinese` the detector and the resolution disagree -
        // which is exactly the case a print surface that re-derived the script
        // from the source alone would get wrong, because it cannot see the
        // preference.
        useTallViewport(tester);
        resetPrintSurfaceMounts();
        await tester.pumpWidget(_PreferenceHost(preference: entry.key));
        await settle(tester);

        final hostState = tester.state<_PreferenceHostState>(
          find.byType(_PreferenceHost),
        );
        final resolved = resolveHanScriptForDocument(hostState.document);
        expect(resolved, entry.value);

        // Print was handed the resolved script...
        expect(lastPrintSurfaceMount!.script, resolved);
        // ...and the Viewer rendered the chain for the same one.
        expect(
          tester
              .widget<Text>(find.text(_kCodeMarker))
              .style
              ?.fontFamilyFallback,
          codeFontFallbackFor(resolved),
        );
        // The Viewer chain and the print chain lead with the same pack.
        expect(
          hanFamiliesFor(resolved).first,
          hanScriptPackFor(resolved).family,
        );
        expect(
          printHanFamiliesFor(resolved).first,
          hanScriptPackFor(resolved).printFamily,
        );
      });
    }

    test('didUpdateWidget still compares all four fields', () {
      // The behavioural test above proves the preference comparison. The other
      // three are what remount print for a replaced or edited document, and no
      // test in this file distinguishes their presence from their absence, so
      // they stay pinned structurally.
      final reader = _readNormalised('lib/reader_screen.dart');
      final start = reader.indexOf('void didUpdateWidget');
      expect(start, greaterThan(-1));
      final body = reader.substring(start, reader.indexOf('\n  }\n', start));

      for (final field in <String>[
        'document.id',
        'document.updatedAt',
        'document.source',
        'document.scriptPreference',
      ]) {
        expect(
          body.contains(field),
          isTrue,
          reason:
              'didUpdateWidget must compare $field before remounting the '
              'print surface',
        );
      }
      expect(body, contains('mountPrintSurface'));
      expect(
        body,
        contains('script:'),
        reason:
            'the remount must carry the resolved script, not just the source',
      );
    });

    test('the write path reloads nothing, re-reads nothing and re-pushes '
        'nothing', () {
      // §5.6.6 lists five prohibited ways to satisfy the acceptance criteria.
      // The State-identity assertion above rules out a remount behaviourally;
      // this rules out the rest structurally, because a later edit could
      // introduce one and no widget test would necessarily notice.
      final main = _readNormalised('lib/main.dart');
      final start = main.indexOf('Future<void> _setScriptPreference');
      expect(start, greaterThan(-1), reason: 'the write path must exist');
      // Bounded to the method body: the first line that closes at method
      // indentation. A looser bound would swallow the rest of the class and
      // make every negative assertion below meaningless.
      final writePath = main.substring(
        start,
        main.indexOf('\n  }\n', start) + 4,
      );

      expect(writePath, contains('copyWith(scriptPreference:'));
      expect(writePath, contains('store.saveDocument'));
      expect(writePath, contains('setState'));
      expect(
        writePath,
        isNot(contains('updatedAt')),
        reason: 'bumping updatedAt would remount the reader (§5.5 fact 4)',
      );
      expect(writePath, isNot(contains('loadDocument')));
      expect(writePath, isNot(contains('Navigator')));
      expect(writePath, isNot(contains('reload')));

      for (final path in <String>[
        'lib/main.dart',
        'lib/reader_screen.dart',
        'lib/script_rendering_sheet.dart',
      ]) {
        final source = _readNormalised(path);
        expect(
          source.contains('location.reload'),
          isFalse,
          reason: '$path must never reload the page',
        );
      }
    });
  });
}

/// Reads a source file with line endings normalised.
///
/// The structural assertions below match on multi-line shapes, and the repo has
/// a mix of LF and CRLF files - a CRLF file would silently fail to match and the
/// assertion would look like a code defect rather than a test one.
String _readNormalised(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

// --- DF-031 CP-B fixtures -----------------------------------------------------

/// Traditional-exclusive throughout; `test/han_script_test.dart` proves the
/// membership these fixtures depend on.
const String _kTraditionalSample = '說編輯設與錯誤處請閱讀單';
const String _kSimplifiedSample = '说编辑设与错误处请阅读单';
const String _kEnglishSource = '# Release notes\n\nAll checks passed.';
const String _kCodeMarker = 'code_chain_probe';

MarkdownDocument _traditionalDocument({
  DocumentScriptPreference preference = DocumentScriptPreference.auto,
  bool withHeadings = false,
}) {
  final source = withHeadings
      ? '# 報告\n\n$_kTraditionalSample\n\n## 附錄\n\nmore'
      : '# 報告\n\n$_kTraditionalSample';
  return MarkdownDocument.fromSource(
    source,
  ).copyWith(scriptPreference: preference);
}

MarkdownDocument _simplifiedDocument({
  DocumentScriptPreference preference = DocumentScriptPreference.auto,
}) {
  return MarkdownDocument.fromSource(
    '# 报告\n\n$_kSimplifiedSample',
  ).copyWith(scriptPreference: preference);
}

/// A stateful host that mirrors `main.dart`'s reader wiring exactly: the same
/// `ValueKey`, the same `copyWith` that does not touch `updatedAt`, and a
/// `setState` in place of a route change. Anything the real app does that would
/// remount the reader would remount it here too.
class _PreferenceHost extends StatefulWidget {
  const _PreferenceHost({this.preference = DocumentScriptPreference.auto});

  final DocumentScriptPreference preference;

  @override
  State<_PreferenceHost> createState() => _PreferenceHostState();
}

class _PreferenceHostState extends State<_PreferenceHost> {
  late MarkdownDocument document = MarkdownDocument.fromSource(
    '# 報告\n\n$_kTraditionalSample\n\n```\n$_kCodeMarker\n```\n',
  ).copyWith(scriptPreference: widget.preference);

  /// How many times the write path ran.
  int saves = 0;

  /// How many times anything re-read the document. Nothing should.
  int reloads = 0;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: buildAppTheme(
        ReaderPalette.light,
        script: resolveHanScriptForDocument(document),
      ),
      home: ReaderScreen(
        key: ValueKey(
          '${document.id}:${document.updatedAt.microsecondsSinceEpoch}',
        ),
        document: document,
        settings: const Settings(),
        onSettingsChanged: (_) {},
        onScriptPreferenceChanged: (next) {
          saves++;
          // The real write path, minus the store call: copyWith without
          // updatedAt, then setState.
          setState(() => document = document.copyWith(scriptPreference: next));
        },
        onEdit: () {},
        onLoadFile: () {},
        onReturnHome: () {},
      ),
    );
  }
}
