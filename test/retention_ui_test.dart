import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/main.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/retention.dart';
import 'package:markdown_viewer/store.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'support/fake_storage.dart';

/// DF-039 Checkpoint 2: startup routing, Home interaction, transitions and
/// recovery, driven through the real `MarkdownViewerApp`.
///
/// These launch the app the way `main()` does - open storage, resolve the
/// retention boundary, then build - so the startup matrix in `plan.md` §18.1 is
/// exercised as a user meets it rather than as a unit-level assertion about a
/// resolver. Where a case needs a failure, the backend is made to fail; where it
/// needs a relaunch, the app is pumped again over the same stored bytes, which
/// is what a refresh actually is.
void main() {
  late FakeBackend backend;

  setUp(() {
    backend = FakeBackend();
  });

  /// Everything `main()` does before the first frame, then the app.
  ///
  /// Returns what startup resolved, so a test can assert on the boundary as
  /// well as on the screen.
  var launchCount = 0;

  Future<StartupResolution> launch(
    WidgetTester tester, {
    StorageBackend? using,
  }) async {
    await store.init(backend: using ?? backend);
    final startup = await retention.resolveStartup();
    await tester.pumpWidget(
      MarkdownViewerApp(
        // A distinct key per launch, so a relaunch builds a new State rather
        // than reusing the previous one. Without it `pumpWidget` would keep the
        // old in-memory document across what is supposed to be a refresh, and
        // every "does not survive a relaunch" assertion would be vacuous.
        key: ValueKey('launch-${launchCount++}'),
        initialSettings: startup.settingsLoad.settings,
        initialDocument: startup.effectivePolicy == RetentionPolicy.on
            ? store.loadDocument()
            : null,
        startup: startup,
      ),
    );
    await settle(tester);
    return startup;
  }

  /// A relaunch over the same stored bytes: the refresh, close and reopen case.
  Future<StartupResolution> relaunch(WidgetTester tester) => launch(tester);

  MarkdownDocument sampleDocument({String name = 'notes.md'}) =>
      MarkdownDocument.fromSource(
        '# Kept notes\n\nBody text.',
        id: 'doc-1',
        sourceName: name,
      );

  /// Seeds storage as a profile that had chosen to keep its document.
  void seedRetained({bool keepForNextTime = true}) {
    backend.data[Store.settingsKey] = jsonEncode(
      Settings(keepForNextTime: keepForNextTime).toJson(),
    );
    backend.data[Store.documentKey] = jsonEncode(sampleDocument().toJson());
    backend.data[Store.positionKey] = jsonEncode(
      ReadingPosition(
        documentId: 'doc-1',
        blockIndex: 3,
        fraction: 0,
        savedAt: DateTime.now(),
      ).toJson(),
    );
  }

  /// Seeds storage exactly as v1.1.0 left it: appearance fields, no retention
  /// field, and a retained document nobody was asked about.
  void seedLegacy() {
    backend.data[Store.settingsKey] = jsonEncode({
      'appearance': 'dark',
      'fontScale': 1.15,
      'wrapCode': true,
    });
    backend.data[Store.documentKey] = jsonEncode(sampleDocument().toJson());
    backend.data[Store.positionKey] = jsonEncode(
      ReadingPosition(
        documentId: 'doc-1',
        blockIndex: 7,
        fraction: 0,
        savedAt: DateTime.now(),
      ).toJson(),
    );
  }

  Future<void> toggleKeep(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Keep for next time'));
    await tester.tap(find.byType(Switch));
    await settle(tester);
  }

  Future<void> confirmRemoval(WidgetTester tester, String action) async {
    await tester.ensureVisible(find.text(action));
    await tester.tap(find.text(action));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await settle(tester);
  }

  bool switchIsOn() =>
      (find.byType(Switch).evaluate().single.widget as Switch).value;

  group('startup matrix', () {
    testWidgets('a fresh profile lands on an empty Home with the choice off', (
      tester,
    ) async {
      final startup = await launch(tester);

      expect(startup.effectivePolicy, RetentionPolicy.off);
      expect(find.text('Load from file'), findsOneWidget);
      expect(find.text('Continue reading'), findsNothing);
      expect(find.text('Keep for next time'), findsOneWidget);
      expect(switchIsOn(), isFalse, reason: 'default OFF must be visible');
    });

    testWidgets('a retained document lands on Home, not in the reader', (
      tester,
    ) async {
      seedRetained();
      final startup = await launch(tester);

      expect(startup.effectivePolicy, RetentionPolicy.on);
      // The accepted boundary: retained is not resumed, and resumed is not
      // entered. The document is there, behind a deliberate action.
      expect(find.text('Load from file'), findsOneWidget);
      expect(find.text('Continue reading'), findsOneWidget);
      expect(find.text('Saved in this browser'), findsOneWidget);
      expect(find.text('notes.md'), findsWidgets);
      expect(switchIsOn(), isTrue);
    });

    testWidgets('continuing from a retained document opens it in the reader', (
      tester,
    ) async {
      seedRetained();
      await launch(tester);

      await tester.tap(find.text('Continue reading'));
      await settle(tester);

      expect(
        find.text('Load from file'),
        findsNothing,
        reason: 'in the reader',
      );
      expect(find.textContaining('Kept notes'), findsWidgets);
    });

    testWidgets('an explicit OFF preference exposes no retained document', (
      tester,
    ) async {
      seedRetained(keepForNextTime: false);
      final startup = await launch(tester);

      expect(startup.effectivePolicy, RetentionPolicy.off);
      expect(find.text('Continue reading'), findsNothing);
      expect(
        find.text('notes.md'),
        findsNothing,
        reason: 'no identity may be disclosed for off-policy content',
      );
      expect(
        store.rawContentPresence(),
        RawKeyPresence.absent,
        reason: 'off-policy content is removed, not merely hidden',
      );
    });

    testWidgets('an unreadable preference fails safe and says so', (
      tester,
    ) async {
      backend.data[Store.settingsKey] = 'not json at all';
      backend.data[Store.documentKey] = jsonEncode(sampleDocument().toJson());

      final startup = await launch(tester);

      expect(startup.effectivePolicy, RetentionPolicy.off);
      expect(switchIsOn(), isFalse);
      expect(find.text('Continue reading'), findsNothing);
      expect(
        find.textContaining('saved choice could not be read'),
        findsOneWidget,
      );
    });

    testWidgets('ON with a record that will not decode shows recovery only', (
      tester,
    ) async {
      backend.data[Store.settingsKey] = jsonEncode(
        const Settings(keepForNextTime: true).toJson(),
      );
      backend.data[Store.documentKey] = 'not a document';

      await launch(tester);

      expect(find.text('Remove unreadable saved data'), findsOneWidget);
      expect(find.text('Continue reading'), findsNothing);
      expect(
        find.text('notes.md'),
        findsNothing,
        reason: 'recovery names nothing, because nothing can be opened',
      );
    });

    testWidgets('ON with nothing stored is an ordinary empty Home', (
      tester,
    ) async {
      backend.data[Store.settingsKey] = jsonEncode(
        const Settings(keepForNextTime: true).toJson(),
      );

      await launch(tester);

      expect(switchIsOn(), isTrue);
      expect(find.text('Continue reading'), findsNothing);
      expect(find.text('Remove unreadable saved data'), findsNothing);
    });

    testWidgets('an orphaned position alone is cleaned up, not shown', (
      tester,
    ) async {
      backend.data[Store.positionKey] = jsonEncode(
        ReadingPosition(
          documentId: 'doc-1',
          blockIndex: 2,
          fraction: 0,
          savedAt: DateTime.now(),
        ).toJson(),
      );

      await launch(tester);

      expect(store.rawContentPresence(), RawKeyPresence.absent);
      expect(find.text('Continue reading'), findsNothing);
    });
  });

  group('existing v1.1.0 profiles', () {
    testWidgets('legacy content is removed and the removal is reported', (
      tester,
    ) async {
      seedLegacy();
      final startup = await launch(tester);

      expect(startup.legacyRecord, isTrue);
      expect(startup.legacyContentRemoved, isTrue);
      expect(startup.effectivePolicy, RetentionPolicy.off);
      expect(store.rawContentPresence(), RawKeyPresence.absent);

      expect(
        find.textContaining('Previously saved reading data was removed'),
        findsOneWidget,
      );
      expect(find.text('Continue reading'), findsNothing);
      expect(find.text('notes.md'), findsNothing);
      expect(
        store.loadSettings().appearance,
        AppearanceMode.dark,
        reason: 'appearance settings are not content and must survive',
      );
    });

    testWidgets('legacy content that will not delete is never reachable', (
      tester,
    ) async {
      seedLegacy();
      backend.failDeletes.add(Store.documentKey);

      final startup = await launch(tester);

      expect(startup.offPolicyDataUnresolved, isTrue);
      expect(find.text('Continue reading'), findsNothing);
      expect(find.text('notes.md'), findsNothing);
      expect(find.text('Remove unreadable saved data'), findsOneWidget);
      expect(
        find.textContaining('may still remain in this browser'),
        findsOneWidget,
      );
    });

    testWidgets('unresolved legacy data blocks turning the choice on', (
      tester,
    ) async {
      seedLegacy();
      backend.failDeletes.add(Store.documentKey);
      await launch(tester);

      // The control is not merely ignored - it is visibly unavailable, and the
      // subtitle says why, so the block is explained rather than mysterious.
      expect(switchIsOn(), isFalse);
      expect(
        find.textContaining('Unavailable until saved reading data is removed'),
        findsOneWidget,
      );

      // And the preference is not persisted behind the scenes either.
      expect(store.loadSettingsResult().settings.keepForNextTime, isFalse);
    });

    testWidgets('an interrupted cleanup stays off across a relaunch', (
      tester,
    ) async {
      seedLegacy();
      backend.failDeletes.add(Store.documentKey);
      await launch(tester);

      final again = await relaunch(tester);

      expect(again.effectivePolicy, RetentionPolicy.off);
      expect(again.offPolicyDataUnresolved, isTrue);
      expect(find.text('Continue reading'), findsNothing);
      expect(
        store.loadSettingsResult().settings.keepForNextTime,
        isFalse,
        reason: 'interruption returns to OFF, never to silent consent',
      );
    });

    testWidgets('once cleanup succeeds the choice becomes available', (
      tester,
    ) async {
      seedLegacy();
      backend.failDeletes.add(Store.documentKey);
      await launch(tester);

      backend.failDeletes.clear();
      await confirmRemoval(tester, 'Remove unreadable saved data');

      expect(store.rawContentPresence(), RawKeyPresence.absent);
      expect(find.text('Remove unreadable saved data'), findsNothing);

      await toggleKeep(tester);
      expect(switchIsOn(), isTrue);
      expect(store.loadSettingsResult().settings.keepForNextTime, isTrue);
    });
  });

  group('current-session behaviour while off', () {
    testWidgets('a loaded document is offered as current session only', (
      tester,
    ) async {
      await launch(tester);
      await pasteDocument(tester);

      await returnHome(tester);

      expect(find.text('Continue reading'), findsOneWidget);
      expect(find.text('Current session only'), findsOneWidget);
      expect(find.text('Saved in this browser'), findsNothing);
    });

    testWidgets('nothing durable is written for it', (tester) async {
      await launch(tester);
      await pasteDocument(tester);
      await returnHome(tester);
      await store.settlePendingOperations();

      expect(store.rawContentPresence(), RawKeyPresence.absent);
      expect(
        backend.writes.where((k) => k != Store.settingsKey),
        isEmpty,
        reason: 'no content write may be attempted while the choice is off',
      );
    });

    testWidgets('a relaunch loses it and offers no continue', (tester) async {
      await launch(tester);
      await pasteDocument(tester);
      await returnHome(tester);

      await relaunch(tester);

      expect(find.text('Continue reading'), findsNothing);
      expect(
        find.text('Remove unreadable saved data'),
        findsNothing,
        reason: 'nothing was stored, so there is nothing to recover from',
      );
    });
  });

  group('turning the choice on', () {
    testWidgets('keeps the current document and says so once confirmed', (
      tester,
    ) async {
      await launch(tester);
      await pasteDocument(tester);
      await returnHome(tester);

      await toggleKeep(tester);

      expect(switchIsOn(), isTrue);
      expect(find.text('Kept for next time.'), findsOneWidget);
      expect(find.text('Saved in this browser'), findsOneWidget);
      expect(store.rawKeyPresence(Store.documentKey), RawKeyPresence.present);
    });

    testWidgets('survives a relaunch and resumes deliberately', (tester) async {
      await launch(tester);
      await pasteDocument(tester);
      await returnHome(tester);
      await toggleKeep(tester);

      await relaunch(tester);

      expect(switchIsOn(), isTrue);
      expect(find.text('Continue reading'), findsOneWidget);
      expect(find.text('Saved in this browser'), findsOneWidget);
    });

    testWidgets('a failed preference write keeps nothing and says nothing was '
        'kept', (tester) async {
      await launch(tester);
      await pasteDocument(tester);
      await returnHome(tester);

      backend.failWrites.add(Store.settingsKey);
      await toggleKeep(tester);

      expect(switchIsOn(), isFalse, reason: 'the choice did not take effect');
      expect(
        find.text('Your choice could not be saved in this browser.'),
        findsOneWidget,
      );
      expect(
        store.rawContentPresence(),
        RawKeyPresence.absent,
        reason: 'content no confirmed preference governs is not written',
      );
    });

    testWidgets('a failed document write does not claim the document is kept', (
      tester,
    ) async {
      await launch(tester);
      await pasteDocument(tester);
      await returnHome(tester);

      backend.failWrites.add(Store.documentKey);
      await toggleKeep(tester);

      expect(switchIsOn(), isTrue, reason: 'the preference itself did land');
      expect(find.text('Kept for next time.'), findsNothing);
      expect(
        find.text('This document could not be saved in this browser.'),
        findsOneWidget,
      );
      expect(
        find.text('Current session only'),
        findsOneWidget,
        reason: 'an unsaved document is a current-session document',
      );
    });
  });

  group('turning the choice off', () {
    testWidgets('removes the document and confirms it', (tester) async {
      seedRetained();
      await launch(tester);

      await toggleKeep(tester);

      expect(switchIsOn(), isFalse);
      expect(find.text('Removed from this browser.'), findsOneWidget);
      expect(store.rawContentPresence(), RawKeyPresence.absent);
      expect(store.loadSettingsResult().settings.keepForNextTime, isFalse);
    });

    testWidgets('a relaunch after it offers no continue', (tester) async {
      seedRetained();
      await launch(tester);
      await toggleKeep(tester);

      await relaunch(tester);

      expect(find.text('Continue reading'), findsNothing);
      expect(switchIsOn(), isFalse);
    });

    testWidgets('a removal that cannot be verified makes no privacy claim', (
      tester,
    ) async {
      seedRetained();
      await launch(tester);

      backend.failDeletes.add(Store.documentKey);
      await toggleKeep(tester);

      expect(find.text('Removed from this browser.'), findsNothing);
      expect(
        find.text('Saved reading data could not be removed.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('may still remain in this browser'),
        findsOneWidget,
      );
      // The document stays readable for the rest of this page lifetime - §19.3
      // step 6 keeps it in memory deliberately. What must not survive is any
      // claim that it is saved, because the policy is now off.
      expect(find.text('Current session only'), findsOneWidget);
      expect(find.text('Saved in this browser'), findsNothing);
      expect(
        store.effectivePolicy,
        RetentionPolicy.off,
        reason: 'containment applies even though deletion failed',
      );
      expect(
        find.text('Remove unreadable saved data'),
        findsOneWidget,
        reason: 'the alert says to try again, so the control must be here',
      );
    });

    testWidgets(
      'data gone but preference unconfirmed claims only the removal',
      (tester) async {
        seedRetained();
        await launch(tester);

        backend.failWrites.add(Store.settingsKey);
        await toggleKeep(tester);

        expect(store.rawContentPresence(), RawKeyPresence.absent);
        expect(
          find.text(
            'Removed from this browser, but your choice may not be '
            'saved.',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining('may not apply on your next visit'),
          findsOneWidget,
        );
      },
    );
  });

  group('remove saved document', () {
    testWidgets('clears the document but leaves the choice on', (tester) async {
      seedRetained();
      await launch(tester);

      await confirmRemoval(tester, 'Remove saved document');

      expect(store.rawContentPresence(), RawKeyPresence.absent);
      expect(
        switchIsOn(),
        isTrue,
        reason: 'removing one document does not change the future default',
      );
      expect(find.text('Continue reading'), findsNothing);
      expect(find.text('Removed from this browser.'), findsOneWidget);
    });

    testWidgets('cancelling it changes nothing', (tester) async {
      seedRetained();
      await launch(tester);

      await tester.ensureVisible(find.text('Remove saved document'));
      await tester.tap(find.text('Remove saved document'));
      await settle(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await settle(tester);

      expect(store.rawKeyPresence(Store.documentKey), RawKeyPresence.present);
      expect(find.text('Continue reading'), findsOneWidget);
    });

    testWidgets('its confirmation says the choice is unaffected', (
      tester,
    ) async {
      seedRetained();
      await launch(tester);

      await tester.ensureVisible(find.text('Remove saved document'));
      await tester.tap(find.text('Remove saved document'));
      await settle(tester);

      expect(find.text('Remove saved document?'), findsOneWidget);
      expect(find.textContaining('notes.md'), findsWidgets);
      expect(
        find.textContaining('"Keep for next time" stays on'),
        findsOneWidget,
      );
    });

    testWidgets('the removed document cannot be written back', (tester) async {
      seedRetained();
      await launch(tester);

      // Enter the reader, so that leaving it fires the position flush that
      // would otherwise land after the removal.
      await tester.tap(find.text('Continue reading'));
      await settle(tester);
      await returnHome(tester);

      await confirmRemoval(tester, 'Remove saved document');
      await store.settlePendingOperations();

      expect(
        store.rawContentPresence(),
        RawKeyPresence.absent,
        reason: 'verified absence must still hold after the reader unwinds',
      );
    });
  });

  group('every write path while off', () {
    testWidgets('editing a document stores nothing', (tester) async {
      await launch(tester);
      await pasteDocument(tester);

      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await settle(tester);
      await tester.ensureVisible(find.text('Edit local copy'));
      await tester.tap(find.text('Edit local copy'));
      await settle(tester);
      await tester.enterText(find.byType(TextField), '# Edited\n\nMore.');
      await settle(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await settle(tester);
      await store.settlePendingOperations();

      expect(store.rawContentPresence(), RawKeyPresence.absent);
    });

    testWidgets('changing the document language stores nothing', (
      tester,
    ) async {
      await launch(tester);
      // The Language control exists only for a document that contains Han
      // script, so this one has to.
      await pasteDocument(tester, source: '# 報告\n\n說編輯設與錯誤處請閱讀單');

      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await settle(tester);
      await tester.ensureVisible(find.text('Language'));
      await tester.tap(find.text('Language'));
      await settle(tester);
      await tester.tap(find.text('Simplified Chinese').last);
      await settle(tester);
      await store.settlePendingOperations();

      expect(store.rawContentPresence(), RawKeyPresence.absent);
      expect(
        backend.writes.where((k) => k != Store.settingsKey),
        isEmpty,
        reason: 'a per-document preference follows the document, not settings',
      );
    });

    testWidgets('scrolling the reader stores no position', (tester) async {
      await launch(tester);
      await pasteDocument(tester);

      await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
      await tester.pump(const Duration(milliseconds: 600));
      await store.settlePendingOperations();

      expect(store.rawKeyPresence(Store.positionKey), RawKeyPresence.absent);
    });
  });

  group('replacement', () {
    testWidgets('while off it stays session only', (tester) async {
      await launch(tester);
      await pasteDocument(tester);
      await returnHome(tester);

      await pasteDocument(tester);
      await returnHome(tester);
      await store.settlePendingOperations();

      expect(store.rawContentPresence(), RawKeyPresence.absent);
      expect(find.text('Current session only'), findsOneWidget);
    });

    testWidgets('while on it does not carry the old reading place over', (
      tester,
    ) async {
      seedRetained();
      await launch(tester);

      // Replace the retained document with a pasted one.
      await pasteDocument(tester, source: '# Replacement\n\nBody.');
      await returnHome(tester);
      await store.settlePendingOperations();

      final stored = store.loadDocument();
      expect(stored, isNotNull);
      expect(stored!.id, isNot('doc-1'), reason: 'the new document is stored');
      expect(
        store.loadPosition('doc-1'),
        isNull,
        reason: 'the outgoing document\'s reading place does not survive it',
      );
      // A position for the *new* document is expected and correct - the reader
      // records one as soon as it is scrolled or left. The requirement is that
      // it can only ever belong to the document it was taken in.
      final carried = store.loadPosition(stored.id);
      if (carried != null) {
        expect(carried.documentId, stored.id);
      }
      expect(find.text('Saved in this browser'), findsOneWidget);
    });

    testWidgets('while on with a failing write claims nothing was saved', (
      tester,
    ) async {
      // A taller viewport: the failure message sits at the bottom as a snack
      // bar, and on the default 800x600 surface it overlaps the reader menu
      // this test has to open afterwards.
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      seedRetained();
      await launch(tester);

      backend.failWrites.add(Store.documentKey);
      await pasteDocument(tester);
      await settle(tester);

      expect(
        find.text('This document could not be saved in this browser.'),
        findsOneWidget,
      );

      await store.settlePendingOperations();
      expect(
        store.rawKeyPresence(Store.documentKey),
        RawKeyPresence.absent,
        reason:
            'the replacement did not land, and the outgoing document was '
            'still removed - so nothing is retained and nothing claims to be',
      );
      expect(
        store.loadPosition('doc-1'),
        isNull,
        reason: 'the outgoing document keeps nothing behind either',
      );
    });
  });

  group('resume semantics', () {
    testWidgets('a retained document with no matching position starts at the '
        'beginning', (tester) async {
      // A stored position belonging to some other document: the id filter must
      // reject it rather than applying it to the wrong text.
      backend.data[Store.settingsKey] = jsonEncode(
        const Settings(keepForNextTime: true).toJson(),
      );
      backend.data[Store.documentKey] = jsonEncode(sampleDocument().toJson());
      backend.data[Store.positionKey] = jsonEncode(
        ReadingPosition(
          documentId: 'a-different-document',
          blockIndex: 40,
          fraction: 0,
          savedAt: DateTime.now(),
        ).toJson(),
      );

      await launch(tester);
      expect(store.loadPosition('doc-1'), isNull);

      await tester.tap(find.text('Continue reading'));
      await settle(tester);

      expect(find.textContaining('Kept notes'), findsWidgets);
      expect(
        readerList(tester).initialScrollIndex,
        0,
        reason: 'a position that belongs to another document is not applied',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('returning home and continuing keeps the same document', (
      tester,
    ) async {
      seedRetained();
      await launch(tester);

      await tester.tap(find.text('Continue reading'));
      await settle(tester);
      await returnHome(tester);

      expect(find.text('Continue reading'), findsOneWidget);
      expect(find.text('Saved in this browser'), findsOneWidget);
      expect(store.rawKeyPresence(Store.documentKey), RawKeyPresence.present);
    });
  });

  group('truthful save status', () {
    testWidgets('a failed edit of a retained document is reported and not '
        'claimed saved', (tester) async {
      useTallViewport(tester);
      seedRetained();
      await launch(tester);
      await tester.tap(find.text('Continue reading'));
      await settle(tester);

      backend.failWrites.add(Store.documentKey);
      await editDocumentTo(tester, '# Edited notes\n\nNew body.');

      expect(
        find.text('Your changes could not be saved in this browser.'),
        findsOneWidget,
      );
      await store.settlePendingOperations();
      expect(
        store.loadDocument()!.source,
        '# Kept notes\n\nBody text.',
        reason: 'what would come back on a reopen is the pre-edit copy',
      );

      await returnHome(tester);
      expect(find.text('Saved in this browser'), findsNothing);
      expect(
        find.text('Latest changes not saved in this browser'),
        findsOneWidget,
      );
      expect(
        find.text('Remove saved document'),
        findsOneWidget,
        reason: 'a copy is still stored, so it must still be removable',
      );
    });

    testWidgets('a failed language change of a retained document is reported '
        'and not claimed saved', (tester) async {
      useTallViewport(tester);
      backend.data[Store.settingsKey] = jsonEncode(
        const Settings(keepForNextTime: true).toJson(),
      );
      backend.data[Store.documentKey] = jsonEncode(
        MarkdownDocument.fromSource(
          '# 報告\n\n說編輯設與錯誤處請閱讀單',
          id: 'doc-han',
          sourceName: 'han.md',
        ).toJson(),
      );
      await launch(tester);
      await tester.tap(find.text('Continue reading'));
      await settle(tester);

      backend.failWrites.add(Store.documentKey);
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await settle(tester);
      await tester.ensureVisible(find.text('Language'));
      await tester.tap(find.text('Language'));
      await settle(tester);
      await tester.tap(find.text('Simplified Chinese').last);
      await settle(tester);

      expect(
        find.text('Your changes could not be saved in this browser.'),
        findsOneWidget,
      );
      await store.settlePendingOperations();
      expect(
        store.loadDocument()!.scriptPreference,
        DocumentScriptPreference.auto,
      );

      // The language sheet stays open after a choice, by design; dismiss it
      // the way a user would before going back to Home.
      await tester.tapAt(const Offset(20, 20));
      await settle(tester);
      expect(find.text('Simplified Chinese'), findsNothing);

      await returnHome(tester);
      expect(find.text('Saved in this browser'), findsNothing);
      expect(
        find.text('Latest changes not saved in this browser'),
        findsOneWidget,
      );
    });

    testWidgets('a successful edit of a retained document stays saved', (
      tester,
    ) async {
      useTallViewport(tester);
      seedRetained();
      await launch(tester);
      await tester.tap(find.text('Continue reading'));
      await settle(tester);

      await editDocumentTo(tester, '# Edited notes\n\nNew body.');
      await store.settlePendingOperations();

      expect(store.loadDocument()!.source, '# Edited notes\n\nNew body.');
      expect(
        find.text('Your changes could not be saved in this browser.'),
        findsNothing,
      );
      await returnHome(tester);
      expect(find.text('Saved in this browser'), findsOneWidget);
    });
  });

  group('a removal can always be retried', () {
    testWidgets('after a failed ON to OFF removal, retrying clears it', (
      tester,
    ) async {
      useTallViewport(tester);
      seedRetained();
      await launch(tester);

      backend.failDeletes.add(Store.documentKey);
      await toggleKeep(tester);
      expect(find.textContaining('Try removing it again'), findsOneWidget);
      expect(find.text('Remove unreadable saved data'), findsOneWidget);

      backend.failDeletes.clear();
      await confirmRemoval(tester, 'Remove unreadable saved data');

      expect(store.rawContentPresence(), RawKeyPresence.absent);
      expect(find.text('Removed from this browser.'), findsOneWidget);
      expect(find.textContaining('may still remain'), findsNothing);
      expect(find.text('Remove unreadable saved data'), findsNothing);
      expect(
        find.text('Current session only'),
        findsOneWidget,
        reason: 'the document stays readable for the rest of this session',
      );
    });

    testWidgets('a presence read that fails still offers removal, and the '
        'delete is still attempted', (tester) async {
      useTallViewport(tester);
      backend.data[Store.documentKey] = jsonEncode(sampleDocument().toJson());
      backend.failReads.add(Store.documentKey);

      final startup = await launch(tester);

      expect(startup.cleanup, CleanupOutcome.indeterminate);
      expect(
        backend.data.containsKey(Store.documentKey),
        isFalse,
        reason: 'the delete ran although presence could not be read first',
      );
      expect(find.text('Remove unreadable saved data'), findsOneWidget);
      expect(find.textContaining('Try removing it again'), findsOneWidget);
      expect(find.text('Continue reading'), findsNothing);
      expect(find.text('notes.md'), findsNothing);

      await tester.ensureVisible(find.text('Remove unreadable saved data'));
      await tester.tap(find.text('Remove unreadable saved data'));
      await settle(tester);
      // The read failure clears before the user confirms the retry.
      backend.failReads.clear();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await settle(tester);

      expect(find.text('Removed from this browser.'), findsOneWidget);
      expect(find.text('Remove unreadable saved data'), findsNothing);
      expect(find.textContaining('may still remain'), findsNothing);
    });

    testWidgets('with no storage at all, nothing offers a removal that cannot '
        'work', (tester) async {
      await launch(tester, using: UnavailableBackend());

      expect(find.textContaining('not letting Saudo store data'), findsWidgets);
      expect(find.textContaining('Try removing it again'), findsNothing);
      expect(find.text('Remove unreadable saved data'), findsNothing);
      expect(find.text('Remove saved document'), findsNothing);
      expect(switchIsOn(), isFalse);
      expect(
        (find.byType(Switch).evaluate().single.widget as Switch).onChanged,
        isNull,
        reason: 'nothing can be kept, so the choice cannot be turned on',
      );

      await pasteDocument(tester);
      await returnHome(tester);
      expect(find.text('Current session only'), findsOneWidget);
    });

    testWidgets('replacing the document does not hide data that remains', (
      tester,
    ) async {
      useTallViewport(tester);
      seedRetained();
      await launch(tester);

      backend.failDeletes.add(Store.documentKey);
      await toggleKeep(tester);
      expect(find.textContaining('may still remain'), findsOneWidget);

      await pasteDocument(tester, source: '# Replacement\n\nBody.');
      await returnHome(tester);
      await store.settlePendingOperations();

      expect(store.rawContentPresence(), RawKeyPresence.present);
      expect(
        find.textContaining('may still remain'),
        findsOneWidget,
        reason: 'the data is still there, so the user is still told',
      );
      expect(find.text('Remove unreadable saved data'), findsOneWidget);
    });
  });

  group('position restoration', () {
    testWidgets('continuing a retained document restores its saved place', (
      tester,
    ) async {
      backend.data[Store.settingsKey] = jsonEncode(
        const Settings(keepForNextTime: true).toJson(),
      );
      backend.data[Store.documentKey] = jsonEncode(
        MarkdownDocument.fromSource(
          longSource(),
          id: 'doc-long',
          sourceName: 'long.md',
        ).toJson(),
      );
      backend.data[Store.positionKey] = jsonEncode(
        ReadingPosition(
          documentId: 'doc-long',
          blockIndex: 25,
          fraction: 0.2,
          savedAt: DateTime.now(),
        ).toJson(),
      );
      await launch(tester);

      await tester.tap(find.text('Continue reading'));
      await settle(tester);

      final list = readerList(tester);
      expect(list.initialScrollIndex, 25);
      expect(list.initialAlignment, closeTo(-0.2, 1e-9));
    });

    testWidgets('continuing in the same session restores the in-memory place '
        'without storing it', (tester) async {
      await launch(tester);
      await pasteDocument(tester, source: longSource());

      await tester.drag(
        find.byType(ScrollablePositionedList),
        const Offset(0, -2500),
      );
      await tester.pump(const Duration(milliseconds: 700));
      // Reading forward hides the reader's controls by design; a short scroll
      // back up brings them back, as it would for a user reaching for the menu.
      await tester.drag(
        find.byType(ScrollablePositionedList),
        const Offset(0, 40),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await returnHome(tester);

      await tester.tap(find.text('Continue reading'));
      await settle(tester);

      expect(readerList(tester).initialScrollIndex, greaterThan(0));
      await store.settlePendingOperations();
      expect(
        store.rawKeyPresence(Store.positionKey),
        RawKeyPresence.absent,
        reason: 'the place is remembered for this session, not stored',
      );
    });
  });

  group('accessibility and layout', () {
    testWidgets('the choice and both removals are reachable by semantics', (
      tester,
    ) async {
      seedRetained();
      await launch(tester);

      final handle = tester.ensureSemantics();

      // Asserted by announcement and by behaviour, not against an exact flag
      // set: the flags a SwitchListTile emits vary by Flutter version, and
      // pinning them would make this a test of the framework rather than of
      // whether the control is usable without sight.
      //
      // The helper text is part of the control's own announcement, so what the
      // choice does is read out with it rather than being stranded as prose the
      // user has to find separately.
      final choice = tester.getSemantics(find.byType(Switch));
      expect(choice.label, contains('Keep for next time'));
      expect(
        choice.label,
        contains('Store this document and your reading place in this browser'),
      );

      // The destructive control announces its consequence, so the warning is
      // not carried by colour or position alone.
      final removal = tester.getSemantics(
        annotationFor('Remove saved document'),
      );
      expect(removal.hint, contains('Removes saved data from this browser'));

      // And the choice is genuinely operable, not merely labelled. Asserted
      // last, because turning it off correctly takes the removal control away
      // with it - there is no saved document left to remove.
      await tester.tap(find.byType(Switch));
      await settle(tester);
      expect(switchIsOn(), isFalse);
      expect(find.text('Remove saved document'), findsNothing);

      handle.dispose();
    });

    testWidgets('the recovery control is announced as a destructive button', (
      tester,
    ) async {
      // Off-policy data under OFF: the one state in which the choice really is
      // blocked, so the one in which it has to explain itself.
      seedLegacy();
      backend.failDeletes.add(Store.documentKey);
      await launch(tester);

      final handle = tester.ensureSemantics();

      final recovery = tester.getSemantics(
        annotationFor('Remove unreadable saved data'),
      );
      expect(recovery.hint, contains('Removes saved data from this browser'));

      // And the disabled choice explains itself rather than simply not working.
      final choice = tester.getSemantics(find.byType(Switch));
      expect(
        choice.label,
        contains('Unavailable until saved reading data is removed'),
      );

      handle.dispose();
    });

    testWidgets('Home fits a small phone viewport without overflowing', (
      tester,
    ) async {
      // The narrowest case that matters: a retained document, so Home is
      // carrying its heaviest load - continue, both load actions, the choice
      // and the destructive removal - on a 360x640 screen.
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      seedRetained();
      await launch(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Keep for next time'), findsOneWidget);
      expect(find.text('Continue reading'), findsOneWidget);
    });

    testWidgets('every Home control stays reachable on a small phone', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      seedRetained();
      await launch(tester);

      // Scrollable rather than clipped: the content is taller than the screen,
      // and reaching the last control must not require a larger device.
      for (final control in const [
        'Continue reading',
        'Load from file',
        'Paste Markdown',
        'Keep for next time',
        'Remove saved document',
      ]) {
        await tester.ensureVisible(find.text(control));
        await settle(tester);
        expect(find.text(control), findsOneWidget, reason: control);
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('terminology', () {
    testWidgets('never promises permanence, backup, sync or secure erasure', (
      tester,
    ) async {
      seedRetained();
      await launch(tester);

      for (final forbidden in const [
        'permanent',
        'permanently',
        'forever',
        'backup',
        'backed up',
        'sync',
        'synced',
        'cloud',
        'securely',
        'secure erase',
        'guaranteed',
      ]) {
        expect(
          find.textContaining(forbidden, findRichText: true),
          findsNothing,
          reason: 'D-015 forbids promising "$forbidden"',
        );
      }
    });
  });
}

// --- helpers ---------------------------------------------------------------

/// The reader keeps an animation alive, so `pumpAndSettle` never returns once it
/// is on screen. Two pumps is what the rest of this suite uses.
/// The [Semantics] annotation an action declares for itself.
///
/// Matched on the widget's own declared label rather than through
/// `bySemanticsLabel`, which searches rendered semantics and does not reach an
/// annotation whose subtree is excluded - which these deliberately are, so that
/// each action announces as one control instead of four fragments.
Finder annotationFor(String label) => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.label == label,
  description: 'Semantics(label: "$label")',
);

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> pasteDocument(
  WidgetTester tester, {
  String source = '# Session\n\nBody.',
}) async {
  await tester.ensureVisible(find.text('Paste Markdown'));
  await tester.tap(find.text('Paste Markdown'));
  await settle(tester);

  // Replacing a document asks before the effort, not after it.
  if (find.text('Replace current document?').evaluate().isNotEmpty) {
    await tester.tap(find.widgetWithText(FilledButton, 'Replace'));
    await settle(tester);
  }

  await tester.enterText(find.byType(TextField), source);
  await settle(tester);
  await tester.tap(find.widgetWithText(TextButton, 'Open'));
  await settle(tester);
}

String longSource() => List.generate(
  40,
  (i) => '## Section $i\n\nParagraph $i body text.',
).join('\n\n');

ScrollablePositionedList readerList(WidgetTester tester) => tester
    .widget<ScrollablePositionedList>(find.byType(ScrollablePositionedList));

void useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> editDocumentTo(WidgetTester tester, String source) async {
  await tester.tap(find.byIcon(Icons.more_horiz_rounded));
  await settle(tester);
  await tester.ensureVisible(find.text('Edit local copy'));
  await tester.tap(find.text('Edit local copy'));
  await settle(tester);
  await tester.enterText(find.byType(TextField), source);
  await settle(tester);
  await tester.tap(find.widgetWithText(TextButton, 'Save'));
  await settle(tester);
}

Future<void> returnHome(WidgetTester tester) async {
  // A result message can sit over the reader's controls; clear it first so the
  // menu is reachable, as a user would by waiting or swiping it away.
  // `clearSnackBars` only animates the current bar out, which leaves it over the
  // menu button for a frame or more; `removeCurrentSnackBar` takes it away now.
  tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first)
    ..clearSnackBars()
    ..removeCurrentSnackBar();
  await tester.pump();
  await tester.tap(find.byIcon(Icons.more_horiz_rounded));
  await settle(tester);
  await tester.ensureVisible(find.text('Return to main'));
  await settle(tester);
  await tester.tap(find.text('Return to main'));
  await settle(tester);
}
