import 'print_surface_stub.dart'
    if (dart.library.js_interop) 'print_surface_web.dart'
    as implementation;

/// Mounts the browser-facing representation used by the native print command.
///
/// Checkpoint C2 deliberately mounts the current reader document only. Keeping
/// this surface current across replacement, editing and teardown is C3 scope.
void mountPrintSurface(String markdownSource) {
  implementation.mountPrintSurface(markdownSource);
}
