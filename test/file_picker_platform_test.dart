import 'dart:convert';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/file_loader.dart';

class PickerProbe extends FileSelectorPlatform {
  List<XTypeGroup>? filters;
  String name = 'fixture.md';
  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    filters = acceptedTypeGroups;
    return [
      XFile.fromData(
        Uint8List.fromList(utf8.encode('# Picker\n\nLocal.')),
        name: name,
        path: name,
      ),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FileSelectorPlatform previous;
  late PickerProbe probe;
  setUp(() {
    previous = FileSelectorPlatform.instance;
    probe = PickerProbe();
    FileSelectorPlatform.instance = probe;
  });
  tearDown(() {
    FileSelectorPlatform.instance = previous;
    debugDefaultTargetPlatformOverride = null;
  });
  for (final platform in [
    TargetPlatform.iOS,
    TargetPlatform.android,
    TargetPlatform.windows,
  ]) {
    test(
      '$platform preserves picker filtering and local decoded contents',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        final file = await (await openMarkdownFiles())!.single.read();
        expect(file.name, 'fixture.md');
        expect(file.contents, '# Picker\n\nLocal.');
        if (platform == TargetPlatform.windows) {
          expect(
            probe.filters?.single.extensions,
            kMarkdownExtensions.toList(),
          );
        } else {
          expect(probe.filters, isEmpty);
        }
      },
    );
  }
  test('unfiltered iOS picker still rejects an unsupported filename', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    probe.name = 'fixture.bin';
    // DF-020 §4.5 steps 2 and 4 (PC-2): the picker hands the file over under
    // its own name, and the batch pipeline rejects it by that name without
    // reading it (navigation_test "an unsupported file is rejected without
    // asking"; df020_intake_test V-10 [PC-2]).
    final candidate = (await openMarkdownFiles())!.single;
    expect(candidate.name, 'fixture.bin');
    expect(isMarkdownFileName(candidate.name), isFalse);
    expect(probe.filters, isEmpty);
  });

  test('a pick with no name is labelled document.md (S13-04)', () async {
    probe.name = '';
    final candidate = (await openMarkdownFiles())!.single;
    expect(candidate.name, 'document.md');
    expect((await candidate.read()).contents, '# Picker\n\nLocal.');
  });
}
