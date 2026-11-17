// DF-020 CP4: batch intake through the real app.
//
// V-10, V-11 and V-11r, DF-020 plan §6.2. The drop classification in the
// browser is checked separately, in the compiled synthetic drop
// (test/browser/df020_drop_batch.mjs, against the production build).

import 'dart:async';
import 'dart:convert';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/document_session.dart';
import 'package:markdown_viewer/document_tabs.dart';
import 'package:markdown_viewer/file_drop.dart';
import 'package:markdown_viewer/file_loader.dart';
import 'package:markdown_viewer/main.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/reader_screen.dart';
import 'package:markdown_viewer/retained_format.dart';
import 'package:markdown_viewer/retention.dart';
import 'package:markdown_viewer/store.dart';

import 'support/fake_storage.dart';

const wide = Size(1000, 900);

String longSource(String name) => [
  '# $name',
  for (var i = 0; i < 40; i++) '## $name section $i\n\nParagraph $i of $name.',
].join('\n\n');

MarkdownDocument fileDoc(String id) => MarkdownDocument.fromSource(
  longSource(id.toUpperCase()),
  id: id,
  sourceName: '$id.md',
);

ReadingPosition pos(String id, int block) => ReadingPosition(
  documentId: id,
  blockIndex: block,
  fraction: 0,
  savedAt: DateTime.utc(2026, 11, 17),
);

/// A file of a batch, with new content that names it, through the production
/// candidate constructor.
FileCandidate file(String name, [String? contents]) => FileCandidate(
  name,
  () async => contents ?? '# New $name\n\nLoaded copy of $name.',
);

/// A batch file whose read waits for [gate], then yields [contents] or throws
/// [error]. [reads] counts the reads actually issued.
class GatedFile {
  GatedFile(this.name, {this.contents, this.error});
  final String name;
  final String? contents;
  final Object? error;
  final gate = Completer<void>();
  var reads = 0;
  var settled = false;

  FileCandidate get candidate => FileCandidate(name, () async {
    reads++;
    await gate.future;
    settled = true;
    if (error != null) throw error!;
    return contents ?? '# New $name\n\nLoaded copy of $name.';
  });
}

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// An `XFile` that counts how often its contents are read.
class CountingXFile extends XFile {
  CountingXFile(String name, List<int> bytes)
    : super.fromData(Uint8List.fromList(bytes), name: name, path: name);
  var reads = 0;

  @override
  Future<String> readAsString({Encoding encoding = utf8}) {
    reads++;
    return super.readAsString(encoding: encoding);
  }
}

/// The platform picker, answering with [files].
class PickerProbe extends FileSelectorPlatform {
  PickerProbe(this.files);
  final List<CountingXFile> files;

  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => files;
}

ReaderScreen reader(WidgetTester tester) =>
    tester.widget<ReaderScreen>(find.byType(ReaderScreen));

/// The open documents as the tab bar shows them, in order.
List<MarkdownDocument> tabs(WidgetTester tester) =>
    tester.widget<DocumentTabBar>(find.byType(DocumentTabBar)).documents;

List<String?> tabNames(WidgetTester tester) => [
  for (final document in tabs(tester)) document.sourceName,
];

String? activeTab(WidgetTester tester) =>
    tester.widget<DocumentTabBar>(find.byType(DocumentTabBar)).activeId;

void main() {
  late FakeBackend backend;
  late void Function(List<FileCandidate>) drop;
  var launches = 0;

  setUp(() => backend = FakeBackend());
  tearDown(() => pickMarkdownFiles = openMarkdownFiles);

  FileDropLease mount({
    required bool Function() eligible,
    required void Function(bool) onHover,
    required void Function(List<FileCandidate>) onCandidates,
    required void Function(String) onRejected,
  }) {
    drop = (candidates) {
      if (eligible()) onCandidates(candidates);
    };
    return FileDropLease(() {});
  }

  void useWide(WidgetTester tester) {
    tester.view.physicalSize = wide;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// Seeds a saved set under ON, as an earlier page lifetime left it.
  void seedOn(List<String> ids, {required String active}) {
    backend.data[Store.settingsKey] = jsonEncode(
      const Settings(keepForNextTime: true).toJson(),
    );
    backend.data[Store.documentKey] = encodeDocumentSet([
      for (final id in ids) fileDoc(id),
    ]);
    backend.data[Store.positionKey] = encodeReadingState(active, {
      for (final (i, id) in ids.indexed) id: pos(id, 2 + i * 5),
    });
  }

  Future<void> launch(WidgetTester tester) async {
    await store.init(backend: backend);
    final startup = await retention.resolveStartup();
    await tester.pumpWidget(
      MarkdownViewerApp(
        key: ValueKey('df020-intake-${launches++}'),
        initialSettings: startup.settingsLoad.settings,
        initialDocument: startup.effectivePolicy == RetentionPolicy.on
            ? store.loadDocument()
            : null,
        startup: startup,
        fileDropMount: mount,
      ),
    );
    await settle(tester);
    backend.writes.clear();
  }

  Future<void> continueReading(WidgetTester tester) async {
    await tester.tap(find.text('Continue reading'));
    await settle(tester);
  }

  Future<void> loadFromHome(
    WidgetTester tester,
    List<FileCandidate> batch,
  ) async {
    pickMarkdownFiles = () async => batch;
    await tester.ensureVisible(find.text('Load from file'));
    await tester.tap(find.text('Load from file'));
    await settle(tester);
  }

  Future<void> loadFromReader(
    WidgetTester tester,
    List<FileCandidate> batch,
  ) async {
    pickMarkdownFiles = () async => batch;
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await settle(tester);
    await tester.tap(find.text('Load from file'));
    await settle(tester);
    await settle(tester);
  }

  Finder inDialog(Finder finder) =>
      find.descendant(of: find.byType(AlertDialog), matching: finder);

  Finder sameForOthers() => find.text('Do the same for other documents');

  /// The seeded `a.md`, `b.md`, `d.md` under ON, active `d.md`, each at its
  /// own place, are still exactly what is open.
  Future<void> expectSeededSetUnchanged(WidgetTester tester) async {
    if (find.text('Continue reading').evaluate().isNotEmpty) {
      await continueReading(tester);
    }
    expect([for (final d in tabs(tester)) d.id], ['a', 'b', 'd']);
    expect(
      [for (final d in tabs(tester)) d.source],
      [longSource('A'), longSource('B'), longSource('D')],
    );
    expect(activeTab(tester), 'd');
    expect(reader(tester).sessionPosition?.blockIndex, 12);
    for (final (id, block) in [('a', 2), ('b', 7)]) {
      await tester.tap(
        find.descendant(
          of: find.byType(DocumentTabBar),
          matching: find.text('$id.md'),
        ),
      );
      await settle(tester);
      expect(reader(tester).document.id, id);
      expect(reader(tester).sessionPosition?.blockIndex, block);
    }
  }

  // --- V-10 --------------------------------------------------------------------

  group('V-10: batch order, the active document and appending', () {
    test('D-2 compares case-insensitively, code units break ties, and it is '
        'not numeric', () {
      final names = ['b.md', '10.md', '9.md', 'B.md', 'a.md', 'A.md'];
      names.sort(compareFileNames);
      expect(names, ['10.md', '9.md', 'A.md', 'a.md', 'B.md', 'b.md']);
    });

    testWidgets('picked from the Reader, the files are added after the open '
        'one in D-2 order and the first is active; nothing is asked', (
      tester,
    ) async {
      useWide(tester);
      await launch(tester);
      await loadFromHome(tester, [file('x.md')]);
      expect(reader(tester).document.sourceName, 'x.md');

      await loadFromReader(tester, [file('c.md'), file('b.md'), file('A.md')]);

      expect(find.byType(AlertDialog), findsNothing);
      expect(tabNames(tester), ['x.md', 'A.md', 'b.md', 'c.md']);
      expect(reader(tester).document.sourceName, 'A.md');
      expect(activeTab(tester), reader(tester).document.id);
      expect(reader(tester).sessionPosition, isNull);
      // OFF: nothing about the documents is stored.
      expect(
        backend.writes.where(
          (key) => key == Store.documentKey || key == Store.positionKey,
        ),
        isEmpty,
      );
    });

    final orders = [
      ['b.md', 'A.md', 'c.md'],
      ['b.md', 'c.md', 'A.md'],
      ['A.md', 'b.md', 'c.md'],
      ['A.md', 'c.md', 'b.md'],
      ['c.md', 'A.md', 'b.md'],
      ['c.md', 'b.md', 'A.md'],
    ];
    for (final order in orders) {
      testWidgets('a drop delivered as $order loads A.md, b.md, c.md with '
          'A.md active', (tester) async {
        useWide(tester);
        await launch(tester);
        drop([for (final name in order) file(name)]);
        await settle(tester);
        expect(tabNames(tester), ['A.md', 'b.md', 'c.md']);
        expect(reader(tester).document.sourceName, 'A.md');
      });
    }

    testWidgets('under ON, an added batch is appended to the saved set and '
        'saved', (tester) async {
      useWide(tester);
      seedOn(['a', 'b', 'd'], active: 'd');
      await launch(tester);
      await loadFromHome(tester, [file('f.md'), file('e.md')]);

      expect(find.byType(AlertDialog), findsNothing);
      expect(tabNames(tester), ['a.md', 'b.md', 'd.md', 'e.md', 'f.md']);
      expect(reader(tester).document.sourceName, 'e.md');
      final saved = decodeDocumentKey(backend.data[Store.documentKey]!);
      expect(
        [for (final d in saved.documents) d.sourceName],
        ['a.md', 'b.md', 'd.md', 'e.md', 'f.md'],
      );
      final reading = decodeReadingKey(backend.data[Store.positionKey]!);
      expect(reading.activeId, reader(tester).document.id);
      expect(reading.positions['d']?.blockIndex, 12, reason: 'kept');
    });

    testWidgets('names match only when exactly equal: a.md does not replace '
        'A.md (S13-02)', (tester) async {
      useWide(tester);
      await launch(tester);
      await loadFromHome(tester, [file('A.md')]);
      await loadFromReader(tester, [file('a.md')]);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tabNames(tester), ['A.md', 'a.md']);
    });

    testWidgets('under ON, an added batch that cannot be saved stays open and '
        'says so in the plural (S09-11)', (tester) async {
      useWide(tester);
      seedOn(['a'], active: 'a');
      await launch(tester);
      backend.failWrites.add(Store.documentKey);
      await loadFromHome(tester, [file('e.md'), file('f.md')]);
      expect(tabNames(tester), ['a.md', 'e.md', 'f.md']);
      expect(
        find.text('These documents could not be saved in this browser.'),
        findsOneWidget,
      );
    });

    // Every rejection class: the whole batch is rejected with the first
    // failure in D-2 order, nothing is asked, and nothing changes or is
    // written.
    final rejections =
        <String, (List<FileCandidate> Function(), String message)>{
          'an unsupported file': (
            () => [file('z.md'), file('photo.png'), file('c.md')],
            'Cannot open "photo.png". Choose a Markdown file '
                '(.md, .markdown or .txt).',
          ),
          'an empty file': (
            () => [file('c.md'), file('e.md', ' \n\t\n')],
            '"e.md" is empty.',
          ),
          'two files with one name (D-5)': (
            () => [file('notes.md'), file('c.md'), file('notes.md')],
            'Cannot open these files: more than one is named "notes.md".',
          ),
          'two nameless picks, both labelled document.md (S13-04)': (
            () => [file('document.md'), file('document.md')],
            'Cannot open these files: more than one is named "document.md".',
          ),
          'an unreadable file': (
            () => [
              file('c.md'),
              FileCandidate('e.md', () async => throw StateError('disk')),
            ],
            'Could not read "e.md": Bad state: disk',
          ),
          'failures named in D-2 order, not delivery order': (
            () => [file('z.png'), file('c.md', '   ')],
            '"c.md" is empty.',
          ),
          'one name, an empty copy delivered second': (
            () => [file('notes.md'), file('notes.md', '')],
            '"notes.md" is empty.',
          ),
          'one name, an empty copy delivered first': (
            () => [file('notes.md', ''), file('notes.md')],
            '"notes.md" is empty.',
          ),
          'a matching file batched with an invalid one': (
            () => [file('a.md'), file('q.png')],
            'Cannot open "q.png". Choose a Markdown file '
                '(.md, .markdown or .txt).',
          ),
        };
    for (final MapEntry(key: name, value: (batch, message))
        in rejections.entries) {
      for (final viaDrop in [false, true]) {
        testWidgets('${viaDrop ? 'dropped' : 'picked'}: $name rejects the '
            'whole batch', (tester) async {
          useWide(tester);
          seedOn(['a', 'b', 'd'], active: 'd');
          await launch(tester);
          final before = Map<String, String>.of(backend.data);

          if (viaDrop) {
            drop(batch());
            await settle(tester);
          } else {
            await loadFromHome(tester, batch());
          }

          expect(find.text(message), findsOneWidget);
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.text('Continue reading'), findsOneWidget);
          expect(backend.data, before);
          expect(backend.writes, isEmpty);
          await expectSeededSetUnchanged(tester);
        });
      }
    }
  });

  // --- V-10 [PC-2] -------------------------------------------------------------

  group('V-10 [PC-2]: read eligibility, the read barrier and precedence', () {
    const unsupported = 'Choose a Markdown file (.md, .markdown or .txt).';

    for (final (name, contents) in [
      ('notes.rtf', 'Readable plain text.'),
      ('photo.png', null),
    ]) {
      testWidgets('an unsupported $name is rejected by its name and never '
          'read or decoded', (tester) async {
        useWide(tester);
        seedOn(['a', 'b', 'd'], active: 'd');
        await launch(tester);
        final before = Map<String, String>.of(backend.data);
        var reads = 0;
        // Readable text, or bytes that cannot decode: either way it must not
        // be read.
        final candidate = FileCandidate(name, () async {
          reads++;
          return contents ??
              utf8.decode([0x89, 0x50, 0x4e, 0x47, 0xff, 0xfe, 0x00]);
        });
        await loadFromHome(tester, [file('c.md'), candidate]);

        expect(reads, 0);
        expect(find.text('Cannot open "$name". $unsupported'), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(backend.data, before);
        expect(backend.writes, isEmpty);
        await expectSeededSetUnchanged(tester);
      });
    }

    testWidgets('the same name through the real picker: the unsupported file '
        'is not read, the Markdown files are', (tester) async {
      useWide(tester);
      seedOn(['a', 'b', 'd'], active: 'd');
      await launch(tester);
      final probe = PickerProbe([
        CountingXFile('c.md', utf8.encode('# C\n\nText.')),
        CountingXFile('photo.png', [0x89, 0x50, 0x4e, 0x47, 0xff, 0xfe, 0x00]),
      ]);
      final previous = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = probe;
      addTearDown(() => FileSelectorPlatform.instance = previous);
      pickMarkdownFiles = openMarkdownFiles;
      await tester.ensureVisible(find.text('Load from file'));
      await tester.tap(find.text('Load from file'));
      await settle(tester);

      expect(probe.files[0].reads, 1, reason: 'eligible: read');
      expect(probe.files[1].reads, 0, reason: 'unsupported: not read');
      expect(
        find.text('Cannot open "photo.png". $unsupported'),
        findsOneWidget,
      );
      await expectSeededSetUnchanged(tester);
    });

    testWidgets('a malformed Markdown file is a read failure, not an '
        'unsupported one', (tester) async {
      useWide(tester);
      seedOn(['a', 'b', 'd'], active: 'd');
      await launch(tester);
      await loadFromHome(tester, [
        FileCandidate('bad.md', () async => utf8.decode([0x23, 0xff, 0xfe])),
      ]);
      expect(
        find.textContaining('Could not read "bad.md": FormatException'),
        findsOneWidget,
      );
      await expectSeededSetUnchanged(tester);
    });

    testWidgets('every eligible read settles before a failure is reported, a '
        'confirmation is asked or anything changes', (tester) async {
      useWide(tester);
      seedOn(['a', 'b', 'd'], active: 'd');
      await launch(tester);
      final before = Map<String, String>.of(backend.data);
      final failing = GatedFile('x.md', error: StateError('disk'));
      final matching = GatedFile('a.md');
      final slow = GatedFile('y.md');
      await loadFromHome(tester, [
        failing.candidate,
        matching.candidate,
        slow.candidate,
      ]);
      expect([failing.reads, matching.reads, slow.reads], [1, 1, 1]);

      // The failure and the matching file settle; one read is still open.
      failing.gate.complete();
      matching.gate.complete();
      await settle(tester);
      expect(find.textContaining('Could not read'), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Continue reading'), findsOneWidget);
      expect(backend.data, before);
      expect(backend.writes, isEmpty);

      slow.gate.complete();
      await settle(tester);
      expect(
        find.text('Could not read "x.md": Bad state: disk'),
        findsOneWidget,
      );
      expect(find.byType(AlertDialog), findsNothing);
      await expectSeededSetUnchanged(tester);
    });

    testWidgets('a matching file is not confirmed until every read settles', (
      tester,
    ) async {
      useWide(tester);
      seedOn(['a', 'b', 'd'], active: 'd');
      await launch(tester);
      final matching = GatedFile('a.md');
      final slow = GatedFile('c.md');
      await loadFromHome(tester, [matching.candidate, slow.candidate]);
      matching.gate.complete();
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      slow.gate.complete();
      await settle(tester);
      expect(inDialog(find.textContaining('"a.md"')), findsOneWidget);
    });

    // Competing failures: the first failing file in D-2 order is reported,
    // however the reads complete.
    final competing = <String, (List<GatedFile> Function(), String)>{
      'an empty a.md before an unreadable b.md': (
        () => [
          GatedFile('b.md', error: StateError('disk')),
          GatedFile('a.md', contents: ' '),
        ],
        '"a.md" is empty.',
      ),
      'an unsupported a.png before an unreadable b.md': (
        () => [
          GatedFile('b.md', error: StateError('disk')),
          GatedFile('a.png'),
        ],
        'Cannot open "a.png". $unsupported',
      ),
      'an unreadable y.md before an unsupported z.png': (
        () => [
          GatedFile('z.png'),
          GatedFile('y.md', error: StateError('disk')),
        ],
        'Could not read "y.md": Bad state: disk',
      ),
      // Equal names (§4.5 step 4): the result is the name's, whichever copy
      // arrives or settles first.
      'notes.md valid and notes.md empty': (
        () => [GatedFile('notes.md'), GatedFile('notes.md', contents: '')],
        '"notes.md" is empty.',
      ),
      'notes.md unreadable and notes.md empty': (
        () => [
          GatedFile('notes.md', error: StateError('disk')),
          GatedFile('notes.md', contents: ''),
        ],
        'Could not read "notes.md": Bad state: disk',
      ),
    };
    for (final MapEntry(key: name, value: (make, message))
        in competing.entries) {
      for (final reversedDelivery in [false, true]) {
        for (final reversedCompletion in [false, true]) {
          testWidgets(
            '$name, delivered ${reversedDelivery ? 'reversed' : 'in order'}'
            ', settling ${reversedCompletion ? 'last-first' : 'first-first'}',
            (tester) async {
              useWide(tester);
              seedOn(['a', 'b', 'd'], active: 'd');
              await launch(tester);
              final files = make();
              final delivered = reversedDelivery
                  ? files.reversed.toList()
                  : files;
              await loadFromHome(tester, [
                for (final f in delivered) f.candidate,
              ]);
              final order = reversedCompletion
                  ? delivered.reversed.toList()
                  : delivered;
              for (final f in order) {
                f.gate.complete();
                await tester.pump();
              }
              await settle(tester);
              for (final f in files) {
                expect(
                  f.reads,
                  isMarkdownFileName(f.name) ? 1 : 0,
                  reason: f.name,
                );
              }
              expect(find.text(message), findsOneWidget);
              expect(find.byType(AlertDialog), findsNothing);
              await expectSeededSetUnchanged(tester);
            },
          );
        }
      }
    }
  });

  // --- V-11 --------------------------------------------------------------------

  group('V-11: the confirmation sequence', () {
    testWidgets('one dialog per match in D-2 order, the checkbox only while '
        'more remain; the new copies take the old slots and start at the top, '
        'and the first file is active', (tester) async {
      useWide(tester);
      seedOn(['a', 'b', 'd'], active: 'd');
      await launch(tester);

      await loadFromHome(tester, [file('c.md'), file('b.md'), file('a.md')]);
      expect(
        inDialog(
          find.text(
            '"a.md" and your place in it will be removed from this device.',
          ),
        ),
        findsOneWidget,
      );
      expect(inDialog(find.text('Replace current document?')), findsOneWidget);
      expect(sameForOthers(), findsOneWidget);
      await tester.tap(find.text('Replace'));
      await settle(tester);

      expect(
        inDialog(
          find.text(
            '"b.md" and your place in it will be removed from this device.',
          ),
        ),
        findsOneWidget,
      );
      expect(sameForOthers(), findsNothing, reason: 'the last confirmation');
      await tester.tap(find.text('Replace'));
      await settle(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(tabNames(tester), ['a.md', 'b.md', 'd.md', 'c.md']);
      final ids = [for (final d in tabs(tester)) d.id];
      expect(ids[0], isNot('a'));
      expect(ids[1], isNot('b'));
      expect(ids[2], 'd');
      expect(activeTab(tester), ids[0]);
      expect(
        reader(tester).document.source,
        '# New a.md\n\nLoaded copy of a.md.',
      );
      expect(reader(tester).sessionPosition, isNull, reason: 'at the top');

      // S09-12: the old copies are gone from storage, and a reopen restores
      // the new set without them.
      final saved = decodeDocumentKey(backend.data[Store.documentKey]!);
      expect([for (final d in saved.documents) d.id], ids);
      final reading = decodeReadingKey(backend.data[Store.positionKey]!);
      expect(reading.positions.keys, isNot(contains('a')));
      expect(reading.positions.keys, isNot(contains('b')));
      expect(reading.positions['d']?.blockIndex, 12);
      await launch(tester);
      await continueReading(tester);
      expect([for (final d in tabs(tester)) d.id], ids);
      expect(activeTab(tester), ids[0]);
    });

    testWidgets('"Do the same" accepts the remaining matches without asking', (
      tester,
    ) async {
      useWide(tester);
      seedOn(['a', 'b', 'd'], active: 'b');
      await launch(tester);

      await loadFromHome(tester, [
        file('d.md'),
        file('b.md'),
        file('a.md'),
        file('c.md'),
      ]);
      expect(inDialog(find.textContaining('"a.md"')), findsOneWidget);
      await tester.tap(sameForOthers());
      await settle(tester);
      await tester.tap(find.text('Replace'));
      await settle(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(tabNames(tester), ['a.md', 'b.md', 'd.md', 'c.md']);
      expect(
        {for (final d in tabs(tester)) d.id}.intersection({'a', 'b', 'd'}),
        isEmpty,
      );
      expect(reader(tester).document.sourceName, 'a.md');
    });

    testWidgets('a single match shows no checkbox', (tester) async {
      useWide(tester);
      seedOn(['a', 'b'], active: 'b');
      await launch(tester);
      await loadFromHome(tester, [file('a.md'), file('c.md')]);
      expect(inDialog(find.textContaining('"a.md"')), findsOneWidget);
      expect(sameForOthers(), findsNothing);
    });

    for (final n in [1, 2, 3]) {
      testWidgets(
        'Cancel at dialog $n rejects everything and changes nothing',
        (tester) async {
          useWide(tester);
          seedOn(['a', 'b', 'd'], active: 'd');
          await launch(tester);
          final before = Map<String, String>.of(backend.data);

          await loadFromHome(tester, [
            file('d.md'),
            file('c.md'),
            file('b.md'),
            file('a.md'),
          ]);
          for (var i = 1; i < n; i++) {
            await tester.tap(find.text('Replace'));
            await settle(tester);
          }
          expect(
            inDialog(find.textContaining('"${['a', 'b', 'd'][n - 1]}.md"')),
            findsOneWidget,
          );
          expect(sameForOthers(), n < 3 ? findsOneWidget : findsNothing);
          await tester.tap(find.text('Cancel'));
          await settle(tester);

          expect(find.byType(AlertDialog), findsNothing);
          expect(find.text('Continue reading'), findsOneWidget, reason: 'Home');
          expect(backend.data, before);
          expect(backend.writes, isEmpty);
          await expectSeededSetUnchanged(tester);
        },
      );
    }

    testWidgets('under OFF a confirmed replacement takes the old slot, with '
        'nothing stored', (tester) async {
      useWide(tester);
      await launch(tester);
      await loadFromHome(tester, [file('b.md'), file('a.md')]);
      final oldA = tabs(tester).first.id;
      await loadFromReader(tester, [file('a.md', '# Second a\n\nAgain.')]);
      expect(sameForOthers(), findsNothing);
      await tester.tap(find.text('Replace'));
      await settle(tester);
      expect(tabNames(tester), ['a.md', 'b.md']);
      expect(tabs(tester).first.id, isNot(oldA));
      expect(reader(tester).document.source, '# Second a\n\nAgain.');
      expect(
        backend.writes.where(
          (key) => key == Store.documentKey || key == Store.positionKey,
        ),
        isEmpty,
      );
    });
  });

  // --- V-11r -------------------------------------------------------------------

  group('V-11r: a replacement whose removal is not verified (E-1)', () {
    testWidgets('nothing loads, the open set is unchanged, the plural error '
        'claims no removal, and the same load can be retried', (tester) async {
      useWide(tester);
      seedOn(['a', 'b', 'd'], active: 'd');
      await launch(tester);
      List<FileCandidate> batch() => [file('c.md'), file('b.md'), file('a.md')];

      // The removal transaction's write fails; the restore that follows lands.
      backend.injectWrites[Store.documentKey] = [InjectedOutcome.failed];
      await loadFromHome(tester, batch());
      await tester.tap(find.text('Replace'));
      await settle(tester);
      await tester.tap(find.text('Replace'));
      await settle(tester);

      expect(
        find.text(
          'These files were not loaded. Removal of the saved copies of '
          '"a.md" and "b.md" from this browser could not be confirmed.',
        ),
        findsOneWidget,
      );
      expect(find.text('Continue reading'), findsOneWidget, reason: 'Home');
      await expectSeededSetUnchanged(tester);
      expect(
        find.descendant(
          of: find.byType(DocumentTabBar),
          matching: find.text('c.md'),
        ),
        findsNothing,
      );
      final restored = decodeDocumentKey(backend.data[Store.documentKey]!);
      expect([for (final d in restored.documents) d.id], ['a', 'b', 'd']);

      // Retry: the same load now succeeds.
      tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first)
        ..clearSnackBars()
        ..removeCurrentSnackBar();
      await settle(tester);
      await loadFromReader(tester, batch());
      await tester.tap(find.text('Replace'));
      await settle(tester);
      await tester.tap(find.text('Replace'));
      await settle(tester);
      expect(tabNames(tester), ['a.md', 'b.md', 'd.md', 'c.md']);
      expect([for (final d in tabs(tester)) d.id].take(2), isNot(['a', 'b']));
      expect(reader(tester).document.sourceName, 'a.md');
    });

    testWidgets('one file: the singular error, with the out-of-date sentence '
        'when the restore cannot be confirmed either', (tester) async {
      useWide(tester);
      seedOn(['a', 'b', 'd'], active: 'd');
      await launch(tester);
      backend.injectWrites[Store.documentKey] = [
        InjectedOutcome.failed,
        InjectedOutcome.failed,
      ];
      await loadFromHome(tester, [file('a.md')]);
      await tester.tap(find.text('Replace'));
      await settle(tester);

      expect(
        find.text(
          '"a.md" was not replaced. Removal of its saved copy from this '
          'browser could not be confirmed. Saved documents in this browser '
          'may be out of date.',
        ),
        findsOneWidget,
      );
      await expectSeededSetUnchanged(tester);
    });

    testWidgets('from the Reader: while the removal is held the tabs and close '
        'controls are inert, and a failure leaves the active document and its '
        'place', (tester) async {
      useWide(tester);
      seedOn(['a', 'b', 'd'], active: 'd');
      await launch(tester);
      await continueReading(tester);
      final held = backend.stall(Store.documentKey);
      backend.injectWrites[Store.documentKey] = [InjectedOutcome.failed];

      await loadFromReader(tester, [file('b.md')]);
      await tester.tap(find.text('Replace'));
      await settle(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(DocumentTabBar),
          matching: find.text('a.md'),
        ),
        warnIfMissed: false,
      );
      await tester.tap(find.byTooltip('Close a.md'), warnIfMissed: false);
      await settle(tester);
      expect(reader(tester).document.id, 'd', reason: 'inert while held');
      expect(tabNames(tester), ['a.md', 'b.md', 'd.md']);

      held.complete();
      await settle(tester);
      expect(
        find.text(
          '"b.md" was not replaced. Removal of its saved copy from this '
          'browser could not be confirmed.',
        ),
        findsOneWidget,
      );
      expect([for (final d in tabs(tester)) d.id], ['a', 'b', 'd']);
      expect(reader(tester).document.id, 'd');
      expect(reader(tester).sessionPosition?.blockIndex, 12);
    });
  });
}
