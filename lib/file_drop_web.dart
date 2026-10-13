import 'dart:convert';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'file_drop_types.dart';
import 'file_loader.dart';

FileDropLease? _active;

FileDropLease mountFileDrop({
  required bool Function() eligible,
  required void Function(bool) onHover,
  required void Function(DropCandidate) onCandidate,
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
      for (var i = 0; i < transfer.items.length; i++) {
        final item = transfer.items[i];
        if (item.kind == 'file') items.add(item);
      }
      if (items.length != 1 || transfer.files.length != 1) {
        onRejected('Please drop one Markdown or text file, or use Load from file.');
        return;
      }
      final item = items.single;
      final entry = item.webkitGetAsEntry();
      final file = item.getAsFile();
      if (entry == null || !entry.isFile || entry.isDirectory || file == null) {
        onRejected('Cannot classify this as a regular file; use the picker.');
        return;
      }
      final name = file.name;
      if (name.isEmpty || !isMarkdownFileName(name)) {
        onRejected('Choose a named Markdown file (.md, .markdown or .txt).');
        return;
      }
      onCandidate(DropCandidate(name, () async {
        final buffer = await file.arrayBuffer().toDart;
        final contents = utf8.decode(buffer.toDart.asUint8List());
        return LoadedFile(name: name, contents: contents);
      }));
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
