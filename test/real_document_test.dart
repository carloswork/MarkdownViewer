import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/markdown_theme.dart';

import 'rendering_test.dart' show renderDocument, wrapForTest;

/// Optional end-to-end render of a large real-world Markdown document.
///
/// This is an **opt-in** test. No document is committed and no default location
/// is assumed: a large document is usually someone's own working material, and
/// committing one would put private content into version control and undercut
/// the product's own privacy claim. Point the test at a local file to run it:
///
/// ```
/// flutter test --dart-define=REAL_DOC=/path/to/large_document.md
/// ```
///
/// Without that define the test is skipped, so the normal public test run does
/// not depend on any particular machine. Coverage does not depend on it either:
/// `rendering_test.dart` carries a committed synthetic fixture exercising the
/// same Markdown constructs, including the untagged fence that caused the
/// original rendering defect.
const String _documentPath = String.fromEnvironment('REAL_DOC');

void main() {
  if (_documentPath.isEmpty) {
    test(
      'large document renders completely',
      () {},
      skip:
          'Opt-in test. Run with '
          '--dart-define=REAL_DOC=<path to a large .md file> to enable it.',
    );
    return;
  }

  final file = File(_documentPath);

  if (!file.existsSync()) {
    // Explicitly opted in, so a bad path is a mistake worth failing on rather
    // than silently skipping.
    test('large document renders completely', () {
      fail('REAL_DOC is set to "$_documentPath" but no file exists there.');
    });
    return;
  }

  testWidgets('every block of a large document renders without throwing', (
    tester,
  ) async {
    final markdown = file.readAsStringSync();
    // ignore: avoid_print
    print(
      '  document: ${markdown.length} chars, '
      '${'\n'.allMatches(markdown).length + 1} lines',
    );

    final blocks = renderDocument(markdown).blocks;
    expect(blocks, isNotEmpty);
    // ignore: avoid_print
    print('  top-level blocks: ${blocks.length}');

    // Each block is built in isolation so a single failure is attributable and
    // does not mask the others. Before the untagged-fence fix, every fenced
    // block without a language threw here.
    final failures = <String>[];
    for (var i = 0; i < blocks.length; i++) {
      await tester.pumpWidget(wrapForTest([blocks[i]]));
      final error = tester.takeException();
      if (error != null) failures.add('block $i: $error');
    }

    // ignore: avoid_print
    print('  blocks that threw: ${failures.length}');
    expect(
      failures,
      isEmpty,
      reason: 'No block may throw. First few: ${failures.take(3).join(' | ')}',
    );
  });

  testWidgets('the same document also renders in dark mode', (tester) async {
    final markdown = file.readAsStringSync();
    // Built with the dark palette, and pumped in one pass rather than block by
    // block: the light-mode test above already attributes failures precisely,
    // so this only needs to prove the dark configuration builds at all.
    final blocks = renderDocument(markdown, palette: ReaderPalette.dark).blocks;

    await tester.pumpWidget(wrapForTest(blocks));
    expect(tester.takeException(), isNull);
  });
}
