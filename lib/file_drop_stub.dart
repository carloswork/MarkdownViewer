import 'file_drop_types.dart';

FileDropLease mountFileDrop({
  required bool Function() eligible,
  required void Function(bool) onHover,
  required void Function(DropCandidate) onCandidate,
  required void Function(String) onRejected,
}) => FileDropLease(() {});
