import 'file_loader.dart';

export 'file_loader.dart' show FileCandidate;

class FileDropLease {
  FileDropLease(this._release);
  final void Function() _release;
  bool _disposed = false;
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _release();
  }
}

typedef FileDropMount =
    FileDropLease Function({
      required bool Function() eligible,
      required void Function(bool) onHover,
      required void Function(List<FileCandidate>) onCandidates,
      required void Function(String) onRejected,
    });
