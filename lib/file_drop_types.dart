import 'file_loader.dart';

/// A classified, synchronously captured browser file; reading remains lazy.
class DropCandidate {
  const DropCandidate(this.name, this.read);
  final String name;
  final Future<LoadedFile> Function() read;
}

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
      required void Function(DropCandidate) onCandidate,
      required void Function(String) onRejected,
    });
