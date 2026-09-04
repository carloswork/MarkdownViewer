import 'han_script.dart';
import 'print_surface_stub.dart'
    if (dart.library.js_interop) 'print_surface_web.dart'
    as implementation;
import 'print_surface_lifecycle.dart';

export 'print_surface_lifecycle.dart' show PrintSurfaceLease;

/// Mounts the browser-facing representation used by the native print command.
///
/// [script] is the script the Viewer resolved for this document, carried
/// alongside the source rather than re-derived inside the print surface: the
/// resolved script depends on the document's own preference, which the print
/// surface cannot see, so re-deriving it there would reintroduce exactly the
/// Viewer/print divergence this parity work exists to prevent (plan.md §6).
///
/// The returned lease must be released when the owning reader is disposed.
PrintSurfaceLease mountPrintSurface(
  String markdownSource, {
  required HanScript script,
}) => implementation.mountPrintSurface(markdownSource, script: script);

/// Removes browser print state only when [lease] still owns the current mount.
void unmountPrintSurface(PrintSurfaceLease lease) {
  implementation.unmountPrintSurface(lease);
}
