import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

/// A Markdown file the user chose, already read into memory.
class LoadedFile {
  const LoadedFile({required this.name, required this.contents});

  /// The original filename, e.g. 'sample_large_document.md'.
  final String name;

  final String contents;
}

/// Raised when the user picked something that is not usable as Markdown.
class UnsupportedFileException implements Exception {
  const UnsupportedFileException(this.fileName);

  final String fileName;

  @override
  String toString() => 'Unsupported file: $fileName';
}

/// Extensions treated as Markdown. `.txt` is accepted deliberately: plain text
/// is valid Markdown and refusing it would be pedantic.
const Set<String> kMarkdownExtensions = {
  'md',
  'markdown',
  'mdown',
  'mkd',
  'txt',
};

bool isMarkdownFileName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return false;
  return kMarkdownExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// Picker filter used on desktop only. See [_shouldFilterPicker].
///
/// Derived from [kMarkdownExtensions] rather than repeating the list, so the
/// picker filter and the validator below cannot drift apart.
@visibleForTesting
final XTypeGroup markdownTypeGroup = XTypeGroup(
  label: 'Markdown',
  extensions: kMarkdownExtensions.toList(),
);

/// Whether to hand the picker a type filter.
///
/// Desktop pickers honour it and it saves the user wading through every file.
/// Mobile browsers must be left alone: iOS decides what the Files chooser
/// offers partly from the `accept` attribute, and a narrow filter is exactly
/// what makes `.md` appear greyed out and unselectable. Real-device testing
/// proved the unfiltered picker works on iPhone, so mobile keeps precisely the
/// behaviour it has today.
bool get _shouldFilterPicker =>
    defaultTargetPlatform != TargetPlatform.iOS &&
    defaultTargetPlatform != TargetPlatform.android;

/// The picker the app calls.
///
/// A plain function reference rather than a constant so tests can substitute a
/// fake and exercise the replacement flow's branches without a real file
/// dialog. Nothing in production reassigns it; tests must restore it in
/// `tearDown`. Deliberately not `@visibleForTesting` - production reads it on
/// every load, which is exactly what that annotation forbids.
Future<LoadedFile?> Function() pickMarkdownFile = openAndReadMarkdownFile;

/// The only place in the app that knows a file-picking package exists.
///
/// Returns null when the user cancels. Throws [UnsupportedFileException] when
/// the chosen file is not Markdown. The extension is validated here in every
/// case, so a wrong choice produces a clear message whether or not the picker
/// itself filtered.
Future<LoadedFile?> openAndReadMarkdownFile() async {
  final XFile? file = await openFile(
    acceptedTypeGroups: _shouldFilterPicker
        ? <XTypeGroup>[markdownTypeGroup]
        : const <XTypeGroup>[],
  );
  if (file == null) return null;

  final name = file.name.isNotEmpty ? file.name : 'document.md';
  if (!isMarkdownFileName(name)) {
    throw UnsupportedFileException(name);
  }

  // Reads the picked file in the browser. No upload, no network.
  final contents = await file.readAsString();
  debugPrint('Loaded "$name" (${contents.length} chars) locally.');

  return LoadedFile(name: name, contents: contents);
}
