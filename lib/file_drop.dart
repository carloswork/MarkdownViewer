import 'file_drop_stub.dart'
    if (dart.library.js_interop) 'file_drop_web.dart' as implementation;
import 'file_drop_types.dart';
export 'file_drop_types.dart';

FileDropLease mountFileDrop({
  required bool Function() eligible,
  required void Function(bool) onHover,
  required void Function(List<FileCandidate>) onCandidates,
  required void Function(String) onRejected,
}) => implementation.mountFileDrop(
  eligible: eligible,
  onHover: onHover,
  onCandidates: onCandidates,
  onRejected: onRejected,
);
