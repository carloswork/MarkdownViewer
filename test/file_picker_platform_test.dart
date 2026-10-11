import 'dart:convert';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/file_loader.dart';

class PickerProbe extends FileSelectorPlatform {
  List<XTypeGroup>? filters;
  String name = 'fixture.md';
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    filters = acceptedTypeGroups;
    return XFile.fromData(
      Uint8List.fromList(utf8.encode('# Picker\n\nLocal.')),
      name: name,
      path: name,
    );
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
        final file = await openAndReadMarkdownFile();
        expect(file?.name, 'fixture.md');
        expect(file?.contents, '# Picker\n\nLocal.');
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
    await expectLater(
      openAndReadMarkdownFile(),
      throwsA(isA<UnsupportedFileException>()),
    );
    expect(probe.filters, isEmpty);
  });
}
