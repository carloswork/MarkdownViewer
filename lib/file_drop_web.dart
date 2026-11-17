import 'dart:convert';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'file_drop_types.dart';

FileDropLease? _active;

FileDropLease mountFileDrop({
  required bool Function() eligible,
  required void Function(bool) onHover,
  required void Function(List<FileCandidate>) onCandidates,
  required void Function(String) onRejected,
}) {
  _active?.dispose();
  bool alive = true;
  bool hovering = false;
  void hover(bool value) {
    if (!alive || hovering == value) return;
    hovering = value;
    onHover(value);
  }

  bool hasFiles(web.DataTransfer transfer) {
    for (var i = 0; i < transfer.items.length; i++) {
      if (transfer.items[i].kind == 'file') return true;
    }
    final types = transfer.types.toDart;
    return types.any((type) => type.toDart == 'Files') ||
        transfer.files.length > 0;
  }

  final over = ((web.Event event) {
    final transfer = (event as web.DragEvent).dataTransfer;
    if (transfer == null || !hasFiles(transfer)) return;
    event.preventDefault();
    final accept = alive && eligible();
    transfer.dropEffect = accept ? 'copy' : 'none';
    hover(accept);
  }).toJS;
  final drop = ((web.Event event) {
    final transfer = (event as web.DragEvent).dataTransfer;
    if (transfer == null || !hasFiles(transfer)) return;
    event.preventDefault(); // Before classification or asynchronous reading.
    hover(false);
    if (!alive || !eligible()) return;
    try {
      final items = <web.DataTransferItem>[];
      var otherItems = 0;
      for (var i = 0; i < transfer.items.length; i++) {
        final item = transfer.items[i];
        if (item.kind == 'file') {
          items.add(item);
        } else {
          otherItems++;
        }
      }
      if (items.isEmpty) return;
      // A file batch that also carries anything else, text for example, is
      // not classified as a batch of regular files (DF-020 §4.5 step 1).
      if (otherItems > 0 || items.length != transfer.files.length) {
        onRejected('Cannot classify this as a regular file; use the picker.');
        return;
      }
      // Every item is classified before any is accepted (DF-020 §4.5): one
      // directory or non-file item rejects the whole drop. Names and contents
      // are checked by the loading pipeline, for the batch as a whole.
      final candidates = <FileCandidate>[];
      for (final item in items) {
        final entry = item.webkitGetAsEntry();
        final file = item.getAsFile();
        if (entry == null ||
            !entry.isFile ||
            entry.isDirectory ||
            file == null) {
          onRejected('Cannot classify this as a regular file; use the picker.');
          return;
        }
        final name = file.name;
        if (name.isEmpty) {
          onRejected('Choose a named Markdown file (.md, .markdown or .txt).');
          return;
        }
        candidates.add(
          FileCandidate(name, () async {
            final buffer = await file.arrayBuffer().toDart;
            return utf8.decode(buffer.toDart.asUint8List());
          }),
        );
      }
      onCandidates(candidates);
    } catch (_) {
      onRejected('Cannot classify this drop; use the picker.');
    }
  }).toJS;
  final leave = ((web.Event event) {
    final drag = event as web.DragEvent;
    if (drag.relatedTarget == null ||
        drag.clientX <= 0 || drag.clientY <= 0 ||
        drag.clientX >= web.window.innerWidth ||
        drag.clientY >= web.window.innerHeight) {
      hover(false);
    }
  }).toJS;
  final reset = ((web.Event _) => hover(false)).toJS;
  final visibility = ((web.Event _) {
    if (web.document.hidden) hover(false);
  }).toJS;
  final listeners = <String, JSFunction>{
    'dragover': over, 'drop': drop, 'dragleave': leave,
    'dragend': reset, 'blur': reset,
  };
  for (final listener in listeners.entries) {
    web.window.addEventListener(listener.key, listener.value, true.toJS);
  }
  web.document.addEventListener('visibilitychange', visibility, true.toJS);
  late final FileDropLease lease;
  lease = FileDropLease(() {
    hover(false);
    alive = false;
    for (final listener in listeners.entries) {
      web.window.removeEventListener(listener.key, listener.value, true.toJS);
    }
    web.document.removeEventListener('visibilitychange', visibility, true.toJS);
    if (identical(_active, lease)) _active = null;
  });
  _active = lease;
  return lease;
}
