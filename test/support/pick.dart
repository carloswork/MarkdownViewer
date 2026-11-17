import 'package:markdown_viewer/file_loader.dart';

/// Adapts a single-file pick, the shape the picker had before DF-020, to the
/// batch picker seam (M5): the picked file becomes a batch of one.
///
/// A pick that throws [UnsupportedFileException] becomes a batch of one file
/// with that name, which the loading pipeline then rejects by its name, as the
/// picker used to.
Future<List<FileCandidate>?> Function() pickOne(
  Future<LoadedFile?> Function() pick,
) => () async {
  try {
    final file = await pick();
    return file == null ? null : [picked(file)];
  } on UnsupportedFileException catch (error) {
    return [
      FileCandidate(
        error.fileName,
        () async => throw StateError('an unsupported file must not be read'),
      ),
    ];
  }
};

/// [file] as one candidate of a batch.
FileCandidate picked(LoadedFile file) =>
    FileCandidate.loaded(file.name, () async => file);
