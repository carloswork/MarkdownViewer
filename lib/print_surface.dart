import 'print_surface_stub.dart'
    if (dart.library.js_interop) 'print_surface_web.dart'
    as implementation;
import 'print_surface_lifecycle.dart';

export 'print_surface_lifecycle.dart' show PrintSurfaceLease;

/// Mounts the browser-facing representation used by the native print command.
///
/// The returned lease must be released when the owning reader is disposed.
PrintSurfaceLease mountPrintSurface(String markdownSource) =>
    implementation.mountPrintSurface(markdownSource);

/// Removes browser print state only when [lease] still owns the current mount.
void unmountPrintSurface(PrintSurfaceLease lease) {
  implementation.unmountPrintSurface(lease);
}
