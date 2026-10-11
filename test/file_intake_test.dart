import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/file_drop.dart';
import 'package:markdown_viewer/file_loader.dart';
import 'package:markdown_viewer/home_screen.dart';
import 'package:markdown_viewer/main.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/reader_screen.dart';
import 'package:markdown_viewer/retention.dart';
import 'package:markdown_viewer/settings_screen.dart';
import 'package:markdown_viewer/store.dart';
import 'support/fake_storage.dart';

class DropPort {
  late bool Function() eligible;
  late void Function(bool) hover;
  late void Function(DropCandidate) candidate;
  bool disposed = false;
  FileDropLease mount({
    required bool Function() eligible,
    required void Function(bool) onHover,
    required void Function(DropCandidate) onCandidate,
    required void Function(String) onRejected,
  }) {
    this.eligible = eligible;
    hover = onHover;
    candidate = onCandidate;
    return FileDropLease(() => disposed = true);
  }

  void deliver(Future<LoadedFile> Function() read, {String name = 'new.MD'}) {
    if (eligible()) candidate(DropCandidate(name, read));
  }
}

void main() {
  late FakeBackend backend;
  late DropPort port;
  final old = MarkdownDocument.fromSource(
    '# Old\n\nOld body.',
    id: 'old',
    sourceName: 'old.md',
  );
  const next = LoadedFile(name: 'new.MD', contents: '# New\n\nNew body.');
  Future<void> tick(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> launch(
    WidgetTester tester, {
    MarkdownDocument? current,
    bool keep = false,
  }) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    backend.data[Store.settingsKey] = jsonEncode(
      Settings(keepForNextTime: keep).toJson(),
    );
    if (keep && current != null) {
      backend.data[Store.documentKey] = jsonEncode(current.toJson());
    }
    await store.init(backend: backend);
    final startup = await retention.resolveStartup();
    backend.writes.clear();
    await tester.pumpWidget(
      MarkdownViewerApp(
        initialSettings: startup.settingsLoad.settings,
        initialDocument: current,
        startup: startup,
        fileDropMount: port.mount,
      ),
    );
    await tick(tester);
  }

  HomeScreen home(WidgetTester tester) =>
      tester.widget<HomeScreen>(find.byType(HomeScreen));
  ReaderScreen reader(WidgetTester tester) =>
      tester.widget<ReaderScreen>(find.byType(ReaderScreen));
  setUp(() {
    backend = FakeBackend();
    port = DropPort();
  });
  tearDown(() {
    pickMarkdownFile = openAndReadMarkdownFile;
  });

  testWidgets('keyboard picker fallback works while drop feedback is visible', (
    tester,
  ) async {
    var picks = 0;
    pickMarkdownFile = () async {
      picks++;
      return next;
    };
    await launch(tester);
    port.hover(true);
    await tick(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tick(tester);
    expect(picks, 1);
    expect(reader(tester).document.source, next.contents);
    expect(find.text('Drop one Markdown file to open'), findsNothing);
  });

  testWidgets('phone-size layout retains the shared picker path', (
    tester,
  ) async {
    pickMarkdownFile = () async => next;
    await launch(tester);
    tester.view.physicalSize = const Size(390, 844);
    await tick(tester);
    await tester.ensureVisible(find.text('Load from file'));
    await tester.tap(find.text('Load from file'));
    await tick(tester);
    expect(reader(tester).document.sourceName, next.name);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'classified drop opens named document through OFF shared intake',
    (tester) async {
      await launch(tester);
      port.deliver(() async => next);
      await tick(tester);
      expect(reader(tester).document.sourceName, 'new.MD');
      expect(reader(tester).document.source, next.contents);
      expect(backend.writes, isEmpty);
      expect(port.eligible(), isFalse);
    },
  );
  testWidgets(
    'invalid and failed reads preserve old document, no prompt, release guard',
    (tester) async {
      await launch(tester, current: old);
      for (final acquire in <Future<LoadedFile> Function()>[
        () async => const LoadedFile(name: 'blank.md', contents: ' \n\t'),
        () async => const LoadedFile(name: 'wrong.bin', contents: '# Wrong'),
        () async => throw const FormatException('Malformed UTF-8'),
        () async => throw StateError('read failed'),
      ]) {
        port.deliver(acquire);
        await tick(tester);
        expect(home(tester).document, old);
        expect(find.text('Replace current document?'), findsNothing);
        expect(port.eligible(), isTrue);
        expect(backend.writes, isEmpty);
      }
    },
  );
  testWidgets('replacement cancel preserves retained content and position', (
    tester,
  ) async {
    await launch(tester, current: old, keep: true);
    backend.data[Store.positionKey] = 'position sentinel';
    final before = Map<String, String>.of(backend.data);
    port.deliver(() async => next);
    await tick(tester);
    expect(find.text('Replace current document?'), findsOneWidget);
    expect(port.eligible(), isFalse);
    await tester.tap(find.text('Cancel'));
    await tick(tester);
    expect(home(tester).document, old);
    expect(backend.data, before);
    expect(port.eligible(), isTrue);
  });
  testWidgets('drop acquisition blocks duplicate drop, picker and paste', (
    tester,
  ) async {
    await launch(tester);
    final pending = Completer<LoadedFile>();
    var extraReads = 0;
    var picks = 0;
    pickMarkdownFile = () async {
      picks++;
      return next;
    };
    port.deliver(() => pending.future);
    await tick(tester);
    port.deliver(() async {
      extraReads++;
      return next;
    });
    home(tester).onLoadFile();
    home(tester).onPaste();
    await tick(tester);
    expect(extraReads, 0);
    expect(picks, 0);
    expect(find.byType(TextField), findsNothing);
    pending.complete(next);
    await tick(tester);
    expect(reader(tester).document.sourceName, 'new.MD');
  });
  testWidgets(
    'picker acquisition blocks drop and duplicate picker, cancellation restores guard',
    (tester) async {
      await launch(tester);
      final pending = Completer<LoadedFile?>();
      var picks = 0;
      var reads = 0;
      pickMarkdownFile = () {
        picks++;
        return pending.future;
      };
      home(tester).onLoadFile();
      await tick(tester);
      port.deliver(() async {
        reads++;
        return next;
      });
      home(tester).onLoadFile();
      await tick(tester);
      expect(picks, 1);
      expect(reads, 0);
      pending.complete(null);
      await tick(tester);
      expect(port.eligible(), isTrue);
    },
  );
  testWidgets(
    'Settings round trip during acquisition invalidates stale file before confirmation or storage',
    (tester) async {
      await launch(tester, current: old, keep: true);
      final pending = Completer<LoadedFile>();
      port.deliver(() => pending.future);
      await tick(tester);
      home(tester).onOpenSettings();
      await tick(tester);
      tester.widget<SettingsScreen>(find.byType(SettingsScreen)).onBack();
      await tick(tester);
      final before = Map<String, String>.of(backend.data);
      pending.complete(next);
      await tick(tester);
      expect(home(tester).document, old);
      expect(backend.data, before);
      expect(find.text('Replace current document?'), findsNothing);
      expect(port.eligible(), isTrue);
    },
  );
  testWidgets(
    'Continue and Return Home invalidate acquisition even when initial route is restored',
    (tester) async {
      await launch(tester, current: old);
      final pending = Completer<LoadedFile>();
      port.deliver(() => pending.future);
      await tick(tester);
      home(tester).onContinue();
      await tick(tester);
      reader(tester).onReturnHome();
      await tick(tester);
      pending.complete(next);
      await tick(tester);
      expect(home(tester).document, old);
      expect(backend.writes, isEmpty);
      expect(find.text('Replace current document?'), findsNothing);
    },
  );
  testWidgets('disposal removes lease and abandons deferred candidate', (
    tester,
  ) async {
    await launch(tester);
    final pending = Completer<LoadedFile>();
    port.deliver(() => pending.future);
    await tick(tester);
    await tester.pumpWidget(const SizedBox());
    expect(port.disposed, isTrue);
    pending.complete(next);
    await tick(tester);
    expect(backend.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'paste editor covers Home, rejects drop and releases on cancellation',
    (tester) async {
      await launch(tester);
      home(tester).onPaste();
      await tick(tester);
      expect(find.byType(TextField), findsOneWidget);
      expect(port.eligible(), isFalse);
      var reads = 0;
      port.deliver(() async {
        reads++;
        return next;
      });
      expect(reads, 0);
      await tester.tap(find.text('Cancel'));
      await tick(tester);
      expect(port.eligible(), isTrue);
    },
  );
  testWidgets(
    'paste confirms before editor and cancelled confirmation releases guard',
    (tester) async {
      await launch(tester, current: old);
      home(tester).onPaste();
      await tick(tester);
      expect(find.text('Replace current document?'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tick(tester);
      expect(port.eligible(), isTrue);
    },
  );
  testWidgets(
    'opening lease blocks navigation and retention until cleanup/save finishes',
    (tester) async {
      await launch(tester, keep: true);
      home(tester).onOpenSettings();
      await tick(tester);
      final change = tester
          .widget<SettingsScreen>(find.byType(SettingsScreen))
          .onKeepForNextTimeChanged;
      tester.widget<SettingsScreen>(find.byType(SettingsScreen)).onBack();
      await tick(tester);
      final held = backend.stall(Store.documentKey);
      port.deliver(() async => next);
      await tick(tester);
      expect(port.eligible(), isFalse);
      home(tester).onOpenSettings();
      change(false);
      await tick(tester);
      expect(find.byType(SettingsScreen), findsNothing);
      expect(store.effectivePolicy, RetentionPolicy.on);
      held.complete();
      await tick(tester);
      expect(reader(tester).document.source, next.contents);
      expect(store.loadDocument()?.source, next.contents);
    },
  );
  testWidgets(
    'confirmed ON replacement save failure remains truthful and releases controls',
    (tester) async {
      await launch(tester, current: old, keep: true);
      backend.failWrites.add(Store.documentKey);
      port.deliver(() async => next);
      await tick(tester);
      await tester.tap(find.text('Replace'));
      await tick(tester);
      expect(reader(tester).document.source, next.contents);
      expect(
        find.text('This document could not be saved in this browser.'),
        findsOneWidget,
      );
      reader(tester).onReturnHome();
      await tick(tester);
      expect(find.text('Current session only'), findsOneWidget);
      expect(port.eligible(), isTrue);
    },
  );
  testWidgets(
    'route invalidation during confirmation prevents storage after Replace',
    (tester) async {
      await launch(tester, current: old, keep: true);
      final navigate = home(tester).onOpenSettings;
      final before = Map<String, String>.of(backend.data);
      port.deliver(() async => next);
      await tick(tester);
      expect(find.text('Replace current document?'), findsOneWidget);
      navigate();
      await tick(tester);
      await tester.tap(find.text('Replace'));
      await tick(tester);
      expect(backend.data, before);
      expect(backend.writes, isEmpty);
      tester.widget<SettingsScreen>(find.byType(SettingsScreen)).onBack();
      await tick(tester);
      expect(home(tester).document, old);
      expect(port.eligible(), isTrue);
    },
  );
  testWidgets('drop replacement clears outgoing in-memory reading position', (
    tester,
  ) async {
    await launch(tester, current: old);
    home(tester).onContinue();
    await tick(tester);
    reader(tester).onPositionChanged(
      ReadingPosition(
        documentId: old.id,
        blockIndex: 9,
        fraction: .3,
        savedAt: DateTime.now(),
      ),
    );
    reader(tester).onReturnHome();
    await tick(tester);
    port.deliver(() async => next);
    await tick(tester);
    await tester.tap(find.text('Replace'));
    await tick(tester);
    expect(reader(tester).sessionPosition, isNull);
    expect(reader(tester).document.id, isNot(old.id));
  });
  testWidgets(
    'hover is transient non-intercepting feedback and navigation clears it',
    (tester) async {
      await launch(tester);
      port.hover(true);
      await tick(tester);
      expect(find.text('Drop one Markdown file to open'), findsOneWidget);
      final semantics = tester.widget<Semantics>(
        find
            .ancestor(
              of: find.text('Drop one Markdown file to open'),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(semantics.properties.liveRegion, isTrue);
      await tester.tap(find.text('Settings'));
      await tick(tester);
      expect(find.text('Drop one Markdown file to open'), findsNothing);
      expect(port.eligible(), isFalse);
    },
  );
}
