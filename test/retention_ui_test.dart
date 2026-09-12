import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/main.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/retention.dart';
import 'package:markdown_viewer/settings_screen.dart';
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

  /// Turns the choice over, from Home or from Settings.
  ///
  /// The choice lives on Settings. Started from Home, this goes there and comes
  /// back, so the Home assertions that follow are still about Home.
  Future<void> toggleKeep(WidgetTester tester) async {
    final fromHome = !onSettings();
    await openSettings(tester);
    await tester.ensureVisible(keepSwitch());
    await tester.tap(keepSwitch());
    await settle(tester);
    if (fromHome) await closeSettings(tester);
  }

  /// Confirms a removal. `Remove saved document` lives on Settings, so from
  /// Home this goes there and comes back; the recovery control is used where
  /// the test already is, because Home and Settings both carry it.
  Future<void> confirmRemoval(WidgetTester tester, String action) async {
    final viaSettings = action == 'Remove saved document' && !onSettings();
    if (viaSettings) await openSettings(tester);
    await tester.ensureVisible(find.text(action));
    await tester.tap(find.text(action));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await settle(tester);
    if (viaSettings) await closeSettings(tester);
  }

  /// Whether the choice is shown as on: the switch itself on Settings, or the
  /// Settings entry on Home, which must state it exactly once.
  bool switchIsOn() {
    if (onSettings()) {
      return (keepSwitch().evaluate().single.widget as Switch).value;
    }
    final on = find.text('Keep for next time is on').evaluate().length;
    final off = find.text('Keep for next time is off').evaluate().length;
    expect(on + off, 1, reason: 'Home states the choice exactly once');
    return on == 1;
  }

  group('startup matrix', () {
    testWidgets('a fresh profile lands on an empty Home with the choice off', (
      tester,
    ) async {
      final startup = await launch(tester);

      expect(startup.effectivePolicy, RetentionPolicy.off);
      expect(find.text('Load from file'), findsOneWidget);
      expect(find.text('Continue reading'), findsNothing);
      // Default OFF is visible on Home itself, before any document exists,
      // not only one screen away.
      expect(find.text('Keep for next time is off'), findsOneWidget);
      await openSettings(tester);
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
      await openSettings(tester);
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

      await openSettings(tester);
      await tester.ensureVisible(find.text('Remove saved document'));
      await tester.tap(find.text('Remove saved document'));
      await settle(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await settle(tester);

      expect(store.rawKeyPresence(Store.documentKey), RawKeyPresence.present);
      expect(find.text('Remove saved document'), findsOneWidget);
      await closeSettings(tester);
      expect(find.text('Continue reading'), findsOneWidget);
    });

    testWidgets('its confirmation says the choice is unaffected', (
      tester,
    ) async {
      seedRetained();
      await launch(tester);

      await openSettings(tester);
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
      await openSettings(tester);
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

      expect(
        find.textContaining('not allowing this site to store data'),
        findsWidgets,
      );
      expect(find.text('Keep for next time is unavailable'), findsOneWidget);
      expect(find.textContaining('Try removing it again'), findsNothing);
      expect(find.text('Remove unreadable saved data'), findsNothing);

      await openSettings(tester);
      expect(find.textContaining('Try removing it again'), findsNothing);
      expect(find.text('Remove unreadable saved data'), findsNothing);
      expect(find.text('Remove saved document'), findsNothing);
      expect(switchIsOn(), isFalse);
      expect(
        (keepSwitch().evaluate().single.widget as Switch).onChanged,
        isNull,
        reason: 'nothing can be kept, so the choice cannot be turned on',
      );
      await closeSettings(tester);

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

  group('carried combinations', () {
    testWidgets('neither the OFF choice nor the removal confirmed says both', (
      tester,
    ) async {
      useTallViewport(tester);
      seedRetained();
      await launch(tester);

      backend.failWrites.add(Store.settingsKey);
      backend.failDeletes.addAll([Store.documentKey, Store.positionKey]);
      await toggleKeep(tester);

      expect(find.text('Removed from this browser.'), findsNothing);
      expect(
        find.text('Saved reading data could not be removed.'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'may still remain in this browser, and your choice',
        ),
        findsOneWidget,
        reason: 'preference and data uncertainty are reported together',
      );
      expect(
        switchIsOn(),
        isFalse,
        reason: 'session behaviour goes off whether or not anything confirmed',
      );
      expect(find.text('Remove unreadable saved data'), findsOneWidget);
      expect(store.rawContentPresence(), RawKeyPresence.present);
    });

    testWidgets('an unreadable choice and removed legacy data are both '
        'reported', (tester) async {
      backend.data[Store.settingsKey] = 'not json at all';
      backend.data[Store.documentKey] = jsonEncode(sampleDocument().toJson());
      backend.data[Store.positionKey] = jsonEncode(
        ReadingPosition(
          documentId: 'doc-1',
          blockIndex: 2,
          fraction: 0,
          savedAt: DateTime.now(),
        ).toJson(),
      );

      final startup = await launch(tester);

      expect(startup.preferenceUncertain, isTrue);
      expect(startup.cleanup, CleanupOutcome.confirmedAbsent);
      expect(
        find.textContaining('saved choice could not be read'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Previously saved reading data was removed'),
        findsOneWidget,
      );
      expect(find.text('Continue reading'), findsNothing);
      expect(find.text('notes.md'), findsNothing);
      expect(store.rawContentPresence(), RawKeyPresence.absent);
    });

    testWidgets('the newer retention states promise nothing they cannot keep', (
      tester,
    ) async {
      useTallViewport(tester);

      // No storage at all: the storage alert and the disabled-choice subtitle.
      await launch(tester, using: UnavailableBackend());
      expect(
        find.textContaining('not allowing this site to store data'),
        findsWidgets,
      );
      expectNoForbiddenPromises();
      await openSettings(tester);
      expectNoForbiddenPromises();

      // A retained document whose latest edit did not save.
      backend = FakeBackend();
      seedRetained();
      await launch(tester);
      await tester.tap(find.text('Continue reading'));
      await settle(tester);
      backend.failWrites.add(Store.documentKey);
      await editDocumentTo(tester, '# Edited notes\n\nNew body.');
      await returnHome(tester);
      expect(
        find.text('Latest changes not saved in this browser'),
        findsOneWidget,
      );
      expectNoForbiddenPromises();

      // Neither the OFF choice nor the removal confirmed.
      backend.failWrites
        ..clear()
        ..add(Store.settingsKey);
      backend.failDeletes.addAll([Store.documentKey, Store.positionKey]);
      await toggleKeep(tester);
      expect(find.textContaining('your choice may not apply'), findsOneWidget);
      expectNoForbiddenPromises();
    });
  });

  group('accessibility and layout', () {
    testWidgets('the choice and both removals are reachable by semantics', (
      tester,
    ) async {
      seedRetained();
      await launch(tester);
      await openSettings(tester);

      final handle = tester.ensureSemantics();

      // Asserted by announcement and by behaviour, not against an exact flag
      // set: the flags a SwitchListTile emits vary by Flutter version, and
      // pinning them would make this a test of the framework rather than of
      // whether the control is usable without sight.
      //
      // The helper text is part of the control's own announcement, so what the
      // choice does is read out with it rather than being stranded as prose the
      // user has to find separately.
      final choice = tester.getSemantics(keepSwitch());
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
      await tester.tap(keepSwitch());
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
      await openSettings(tester);
      final choice = tester.getSemantics(keepSwitch());
      expect(
        choice.label,
        contains('Unavailable until saved reading data is removed'),
      );

      handle.dispose();
    });

    testWidgets('Home fits a small phone viewport without overflowing', (
      tester,
    ) async {
      // The narrowest case that matters: a retained document, so Home and
      // Settings each carry their heaviest load on a 360x640 screen.
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      seedRetained();
      await launch(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Continue reading'), findsOneWidget);
      expect(find.text('Keep for next time is on'), findsOneWidget);

      await openSettings(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Keep for next time'), findsOneWidget);
      expect(find.text('Remove saved document'), findsOneWidget);
    });

    testWidgets('every Home and Settings control stays reachable on a small '
        'phone', (tester) async {
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
        'Settings',
      ]) {
        await tester.ensureVisible(find.text(control));
        await settle(tester);
        expect(find.text(control), findsOneWidget, reason: control);
      }

      await openSettings(tester);
      for (final control in const [
        'Keep for next time',
        'Remove saved document',
        'Wrap long code lines',
      ]) {
        await tester.ensureVisible(find.text(control));
        await settle(tester);
        expect(find.text(control), findsOneWidget, reason: control);
      }
      expect(tester.takeException(), isNull);
    });

    // plan.md §23 item 16 requires the controls to be keyboard-discoverable,
    // not only reachable by pointer and announced to a screen reader. These
    // drive the real app through the keyboard alone: no `tap`, no
    // `ensureVisible`, no direct focus request.
    testWidgets('the Settings entry is reached and opened by keyboard', (
      tester,
    ) async {
      useTallViewport(tester);
      await launch(tester);

      await tabTo(
        tester,
        actionNamed('Settings'),
        description: "Home's Settings entry",
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);

      expect(onSettings(), isTrue, reason: 'the key press opened Settings');
    });

    testWidgets('the choice is reached and turned over by keyboard', (
      tester,
    ) async {
      useTallViewport(tester);
      await launch(tester);
      await openSettings(tester);
      expect(switchIsOn(), isFalse);

      // Material focuses the switch's whole tile rather than the switch inside
      // it, and activating that tile is what turns the choice over.
      await tabTo(
        tester,
        (widget) => widget is SwitchListTile,
        description: 'the Keep for next time switch tile',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await settle(tester);

      // The same state change the pointer path asserts, on screen and stored.
      expect(switchIsOn(), isTrue);
      expect(store.loadSettingsResult().settings.keepForNextTime, isTrue);
      expect(store.effectivePolicy, RetentionPolicy.on);
    });

    testWidgets('the saved-document removal is reached and confirmed by '
        'keyboard', (tester) async {
      useTallViewport(tester);
      seedRetained();
      await launch(tester);
      await openSettings(tester);

      await tabTo(
        tester,
        actionNamed('Remove saved document'),
        description: 'Remove saved document',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);

      // The destructive action still asks first, exactly as it does by touch.
      expect(find.text('Remove saved document?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await settle(tester);

      expect(store.rawContentPresence(), RawKeyPresence.absent);
      expect(switchIsOn(), isTrue, reason: 'removal leaves the choice alone');
    });
  });

  group('settings', () {
    testWidgets('Home carries the load actions and a Settings entry, not the '
        'choice or the removal', (tester) async {
      useTallViewport(tester);
      seedRetained();
      await launch(tester);

      expect(find.text('Continue reading'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
      expect(find.text('Keep for next time'), findsNothing);
      expect(find.text('Remove saved document'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Paste Markdown')).dy,
        lessThan(tester.getTopLeft(find.text('Settings')).dy),
        reason: 'the document actions come first',
      );
    });

    testWidgets('Settings opens from Home and Back returns there', (
      tester,
    ) async {
      useTallViewport(tester);
      seedRetained();
      await launch(tester);

      await openSettings(tester);
      expect(find.text('Reading data'), findsOneWidget);
      expect(find.text('Keep for next time'), findsOneWidget);
      expect(find.text('Remove saved document'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Load from file'), findsNothing);

      await closeSettings(tester);
      expect(find.text('Load from file'), findsOneWidget);
      expect(
        find.text('Continue reading'),
        findsOneWidget,
        reason: 'visiting Settings leaves the document where it was',
      );
    });

    testWidgets('the Settings entry announces the state of the choice', (
      tester,
    ) async {
      useTallViewport(tester);
      await launch(tester);
      final handle = tester.ensureSemantics();

      expect(
        tester.getSemantics(annotationFor('Settings')).hint,
        contains('Keep for next time is off'),
      );

      await toggleKeep(tester);
      expect(
        tester.getSemantics(annotationFor('Settings')).hint,
        contains('Keep for next time is on'),
      );

      handle.dispose();
    });

    testWidgets('Settings keeps the caveat and drops the long prose', (
      tester,
    ) async {
      useTallViewport(tester);
      await launch(tester);
      await openSettings(tester);

      // The switch's own helper says what the choice does.
      expect(
        find.textContaining(
          'Store this document and your reading place in this browser',
        ),
        findsOneWidget,
      );
      // Beneath it, only the part the helper cannot carry: browser-local and
      // browser-owned.
      expect(find.textContaining('Nothing is uploaded'), findsOneWidget);
      expect(
        find.textContaining('the browser can clear it on its own'),
        findsOneWidget,
      );
      // Run 3 step 8: the ON/OFF prose is gone, and stays gone. On a small
      // phone it pushed the rest of Settings past the first screen.
      expect(find.textContaining('reloaded or closed'), findsNothing);
      expect(find.textContaining('When it is on'), findsNothing);
      expect(find.textContaining('Turning it off removes them'), findsNothing);
      expectNoForbiddenPromises();
    });

    testWidgets('removing the saved document from Settings stays there and '
        'leaves the choice on', (tester) async {
      useTallViewport(tester);
      seedRetained();
      await launch(tester);
      await openSettings(tester);

      await confirmRemoval(tester, 'Remove saved document');

      expect(onSettings(), isTrue);
      expect(find.text('Removed from this browser.'), findsOneWidget);
      expect(find.text('Remove saved document'), findsNothing);
      expect(switchIsOn(), isTrue);
      expect(store.rawContentPresence(), RawKeyPresence.absent);
    });

    testWidgets('no user-facing text names Saudo, in any retention state', (
      tester,
    ) async {
      useTallViewport(tester);

      void expectNoProductName(String state) {
        expect(
          find.textContaining('Saudo', findRichText: true),
          findsNothing,
          reason: '$state: "Saudo" is not an official product name',
        );
      }

      Future<void> check(String state) async {
        expectNoProductName('$state, Home');
        await openSettings(tester);
        expectNoProductName('$state, Settings');
        await closeSettings(tester);
      }

      await launch(tester);
      await check('fresh profile');

      backend = FakeBackend();
      seedRetained();
      await launch(tester);
      await check('retained document');

      backend = FakeBackend();
      seedLegacy();
      backend.failDeletes.add(Store.documentKey);
      await launch(tester);
      await check('unresolved saved data');

      await launch(tester, using: UnavailableBackend());
      await check('no storage');
    });
  });

  group('appearance never writes back the retention choice', () {
    testWidgets('turning the choice on and then changing appearance keeps it '
        'on', (tester) async {
      useTallViewport(tester);
      await launch(tester);
      // Settings builds its appearance controls now, while the choice is off,
      // so their copy of the settings says off from here on.
      await openSettings(tester);

      await toggleKeep(tester);
      expect(switchIsOn(), isTrue);
      await tester.ensureVisible(find.text('Light'));
      await tester.tap(find.text('Light'));
      await settle(tester);
      await store.settlePendingOperations();

      final stored = store.loadSettingsResult().settings;
      expect(stored.appearance, AppearanceMode.light);
      expect(
        stored.keepForNextTime,
        isTrue,
        reason: 'the controls\' stale copy of the choice must not be stored',
      );

      await relaunch(tester);
      expect(switchIsOn(), isTrue);
    });

    testWidgets('turning the choice off and then changing appearance keeps it '
        'off', (tester) async {
      useTallViewport(tester);
      seedRetained();
      await launch(tester);
      await openSettings(tester);

      await toggleKeep(tester);
      expect(find.text('Removed from this browser.'), findsOneWidget);
      await tester.ensureVisible(find.text('Dark'));
      await tester.tap(find.text('Dark'));
      await settle(tester);
      await store.settlePendingOperations();

      final stored = store.loadSettingsResult().settings;
      expect(stored.appearance, AppearanceMode.dark);
      expect(
        stored.keepForNextTime,
        isFalse,
        reason: 'a stale ON would retain the next visit\'s document unasked',
      );

      await relaunch(tester);
      expect(switchIsOn(), isFalse);
      expect(find.text('Continue reading'), findsNothing);
    });

    testWidgets('an appearance change made while the choice is being saved is '
        'stored after it, with the choice', (tester) async {
      useTallViewport(tester);
      await launch(tester);
      await openSettings(tester);

      // Hold the preference write open, so the appearance change arrives while
      // the transition is still running.
      final hold = backend.stall(Store.settingsKey);
      await tester.ensureVisible(keepSwitch());
      await tester.tap(keepSwitch());
      await tester.pump();
      await tester.ensureVisible(find.text('Dark'));
      await tester.tap(find.text('Dark'));
      await tester.pump();

      hold.complete();
      await settle(tester);
      await store.settlePendingOperations();

      final stored = store.loadSettingsResult().settings;
      expect(stored.keepForNextTime, isTrue);
      expect(
        stored.appearance,
        AppearanceMode.dark,
        reason: 'the held-back appearance change is not lost either',
      );
      expect(switchIsOn(), isTrue);
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

      // The longer explanation lives on Settings, so it is held to the same
      // rule.
      await openSettings(tester);
      expectNoForbiddenPromises();
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

/// Whether the focused element sits inside a widget matching [predicate].
///
/// Walks up from the focus node's own context, because the node a control
/// focuses is inside it: an `InkWell`'s focus sits under the `Semantics`
/// annotation that names the action, and a `Switch`'s sits under the `Switch`.
bool focusedInside(bool Function(Widget) predicate) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context is! Element) return false;
  var found = predicate(context.widget);
  context.visitAncestorElements((ancestor) {
    if (predicate(ancestor.widget)) found = true;
    return !found;
  });
  return found;
}

/// Presses Tab until the focus is inside a widget matching [predicate].
///
/// Fails rather than returning quietly: a control the keyboard never reaches
/// is exactly what plan.md §23 item 16 forbids.
Future<void> tabTo(
  WidgetTester tester,
  bool Function(Widget) predicate, {
  required String description,
  int maxPresses = 30,
}) async {
  for (var press = 0; press < maxPresses; press++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    if (focusedInside(predicate)) return;
  }
  fail('focus never reached $description in $maxPresses tab presses');
}

/// An action card, identified by the label its own `Semantics` declares.
bool Function(Widget) actionNamed(String label) =>
    (widget) => widget is Semantics && widget.properties.label == label;

/// The `Keep for next time` switch, found through its own tile: Settings has a
/// second switch, for wrapping code.
Finder keepSwitch() => find.descendant(
  of: find.widgetWithText(SwitchListTile, 'Keep for next time'),
  matching: find.byType(Switch),
);

bool onSettings() => find.byType(SettingsScreen).evaluate().isNotEmpty;

Future<void> openSettings(WidgetTester tester) async {
  if (onSettings()) return;
  // The Settings entry is the last action on Home, where a result message can
  // sit over it; clear that first, as `returnHome` does for the reader menu.
  tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first)
    ..clearSnackBars()
    ..removeCurrentSnackBar();
  await tester.pump();
  await tester.ensureVisible(find.text('Settings'));
  await settle(tester);
  await tester.tap(find.text('Settings'));
  await settle(tester);
  expect(onSettings(), isTrue, reason: 'Settings did not open');
}

Future<void> closeSettings(WidgetTester tester) async {
  if (!onSettings()) return;
  await tester.tap(find.byTooltip('Back'));
  await settle(tester);
}

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

/// Words D-015 forbids the retention surface from promising.
const List<String> forbiddenPromises = [
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
];

/// Scans everything currently built for a forbidden promise.
///
/// Separate from the original terminology test, which scans only a retained
/// document's Home: the storage-unavailable, out-of-date and unresolved states
/// carry their own copy, and a rule that is only enforced where it was first
/// written erodes wherever it was not.
void expectNoForbiddenPromises() {
  for (final forbidden in forbiddenPromises) {
    expect(
      find.textContaining(forbidden, findRichText: true),
      findsNothing,
      reason: 'D-015 forbids promising "$forbidden"',
    );
  }
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
