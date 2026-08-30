import 'print_surface_lifecycle.dart';

final _lifecycle = PrintSurfaceLifecycle();

/// Non-web builds keep their existing native rendering and printing behaviour.
PrintSurfaceLease mountPrintSurface(String markdownSource) =>
    _lifecycle.beginMount();

void unmountPrintSurface(PrintSurfaceLease lease) {
  _lifecycle.release(lease);
}
