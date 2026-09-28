import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/main.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/retention.dart';
import 'package:markdown_viewer/store.dart';

import 'support/fake_storage.dart';

/// DF-052 CP1 Round 2 finding 2 — the render-sourced Search index must be proven
/// against the *current* Reader reached by the real entry paths, not a synthetic
/// direct-capture helper.
///
/// This drives the whole app through normal open (retained document → Continue
/// reading), Paste Markdown, and Edit local copy, then searches the mounted
/// Reader those paths produce. The Human CP1 addendum's requirement is the
/// assertion here: new visible text is searchable and replaced/removed text is
/// not, in the Reader the user actually reaches.
void main() {
  const wide = Size(1400, 900);

  late FakeBackend backend;
  var launches = 0;

  setUp(() => backend = FakeBackend());

  void useWide(WidgetTester tester) {
    tester.view.physicalSize = wide;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> settle(WidgetTester tester, {int frames = 10}) async {
    await tester.pump();
    for (var frame = 0; frame < frames; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> launch(WidgetTester tester) async {
    await store.init(backend: backend);
    final startup = await retention.resolveStartup();
    await tester.pumpWidget(
      MarkdownViewerApp(
        key: ValueKey('entry-launch-${launches++}'),
        initialSettings: startup.settingsLoad.settings,
        initialDocument: startup.effectivePolicy == RetentionPolicy.on
            ? store.loadDocument()
            : null,
        startup: startup,
      ),
    );
    await settle(tester);
  }

  Future<void> openSearch(WidgetTester tester) async {
    await tester.tap(
      find.byIcon(Icons.more_horiz_rounded),
      warnIfMissed: false,
    );
    await settle(tester);
    await tester.tap(find.text('Search document'));
    await settle(tester);
  }

  Future<String> count(WidgetTester tester, String query) async {
    await tester.enterText(find.byKey(const ValueKey('search-field')), query);
    await tester.pump(const Duration(milliseconds: 151));
    await settle(tester);
    return tester
        .widget<Text>(find.byKey(const ValueKey('search-result-count')))
        .data!;
  }

  testWidgets('normal open: the retained document is the searchable Reader', (
    tester,
  ) async {
    useWide(tester);
    const source = '# Opened\n\nopenalpha body\n\nopenbeta body\n';
    final document = MarkdownDocument.fromSource(source, id: 'opened');
    backend.data[Store.settingsKey] = jsonEncode(
      const Settings(keepForNextTime: true).toJson(),
    );
    backend.data[Store.documentKey] = jsonEncode(document.toJson());

    await launch(tester);
    await tester.tap(find.text('Continue reading'));
    await settle(tester);

    await openSearch(tester);
    expect(await count(tester, 'openalpha'), '1 result');
    expect(await count(tester, 'openbeta'), '1 result');
    expect(await count(tester, 'notpresent'), '0 results');
  });

  testWidgets('Paste Markdown: the pasted document becomes searchable', (
    tester,
  ) async {
    useWide(tester);
    await launch(tester);
    await tester.tap(find.text('Paste Markdown'));
    await settle(tester);
    await tester.enterText(
      find.byType(TextField),
      '# Pasted\n\nfreshone body\n\nfreshtwo body\n',
    );
    await settle(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Open'));
    await settle(tester);

    await openSearch(tester);
    expect(await count(tester, 'freshone'), '1 result');
    expect(await count(tester, 'freshtwo'), '1 result');
    expect(await count(tester, 'dropme'), '0 results');
  });

  testWidgets(
    'Edit local copy: added text is searchable and removed text is gone',
    (tester) async {
      useWide(tester);
      await launch(tester);

      // Reach a Reader by pasting a first document.
      await tester.tap(find.text('Paste Markdown'));
      await settle(tester);
      await tester.enterText(
        find.byType(TextField),
        '# Doc\n\nkeepone body\n\ndropme body\n',
      );
      await settle(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Open'));
      await settle(tester);

      // Confirm the pre-edit Reader indexes the old text.
      await openSearch(tester);
      expect(await count(tester, 'dropme'), '1 result');
      await tester.tap(find.byKey(const ValueKey('search-close')));
      await settle(tester);

      // Edit local copy: replace the source, dropping "dropme" and adding
      // "addedthree".
      await tester.tap(
        find.byIcon(Icons.more_horiz_rounded),
        warnIfMissed: false,
      );
      await settle(tester);
      await tester.tap(find.text('Edit local copy'));
      await settle(tester);
      await tester.enterText(
        find.byType(TextField),
        '# Doc\n\nkeepone body\n\naddedthree body\n',
      );
      await settle(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await settle(tester);

      // The post-edit Reader indexes the new text and no longer the old.
      await openSearch(tester);
      expect(
        await count(tester, 'addedthree'),
        '1 result',
        reason: 'newly visible text is searchable in the edited Reader',
      );
      expect(await count(tester, 'keepone'), '1 result');
      expect(
        await count(tester, 'dropme'),
        '0 results',
        reason: 'removed text ceases to be searchable',
      );
    },
  );
}
