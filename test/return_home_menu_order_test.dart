import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/reader_screen.dart';
import 'package:markdown_viewer/store.dart';

import 'support/fake_storage.dart';

/// Return to main replaces the Reader, and opening wide Search replaces its
/// list. Neither may happen while the menu sheet is still on screen: in a
/// browser with the accessibility tree enabled, that ordering leaves the tree
/// failing on every later update, and the Reader's position tracking stops
/// with it. The failure itself is web-engine only, so these guard the ordering
/// that avoids it.
void main() {
  setUp(() async {
    await store.init(backend: MemoryBackend());
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('Return to main leaves only after the menu has closed', (
    tester,
  ) async {
    bool? menuMountedWhenLeaving;
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderScreen(
          document: MarkdownDocument.fromSource('# Report\n\nBody.'),
          settings: const Settings(),
          onSettingsChanged: (_) {},
          onScriptPreferenceChanged: (_) {},
          onEdit: () {},
          onLoadFile: () {},
          onReturnHome: () => menuMountedWhenLeaving = find
              .text('Return to main')
              .evaluate()
              .isNotEmpty,
          onPositionChanged: (_) {},
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await settle(tester);

    await tester.tap(find.text('Return to main'));
    await settle(tester);
    await settle(tester);

    expect(menuMountedWhenLeaving, isFalse);
  });

  testWidgets(
    'wide Search opens from the menu only after the menu has closed',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(
            document: MarkdownDocument.fromSource('# Report\n\nBody.'),
            settings: const Settings(),
            onSettingsChanged: (_) {},
            onScriptPreferenceChanged: (_) {},
            onEdit: () {},
            onLoadFile: () {},
            onReturnHome: () {},
            onPositionChanged: (_) {},
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await settle(tester);

      await tester.tap(find.text('Search document'));
      var paneWhileMenuMounted = false;
      for (var frame = 0; frame < 40; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (find.byType(TextField).evaluate().isNotEmpty &&
            find.text('Return to main').evaluate().isNotEmpty) {
          paneWhileMenuMounted = true;
        }
      }
      await settle(tester);

      expect(find.byType(TextField), findsOneWidget);
      expect(paneWhileMenuMounted, isFalse);
    },
  );

  testWidgets('the menu cannot be reopened while it is closing to leave', (
    tester,
  ) async {
    var returnedHome = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderScreen(
          document: MarkdownDocument.fromSource('# Report\n\nBody.'),
          settings: const Settings(),
          onSettingsChanged: (_) {},
          onScriptPreferenceChanged: (_) {},
          onEdit: () {},
          onLoadFile: () {},
          onReturnHome: () => returnedHome++,
          onPositionChanged: (_) {},
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await settle(tester);

    await tester.tap(find.text('Return to main'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // While the menu is still closing, a second tap reaches the menu button.
    await tester.tap(
      find.byIcon(Icons.more_horiz_rounded),
      warnIfMissed: false,
    );
    await settle(tester);
    await settle(tester);

    expect(returnedHome, 1);
    expect(find.text('Return to main'), findsNothing);
  });
}
