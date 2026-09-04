import 'han_script.dart';
import 'print_surface_lifecycle.dart';

final _lifecycle = PrintSurfaceLifecycle();

/// The arguments one print-surface mount was given.
class PrintSurfaceMount {
  const PrintSurfaceMount({required this.markdownSource, required this.script});

  final String markdownSource;

  /// The script the *Viewer* resolved, passed in rather than re-derived here.
  final HanScript script;
}

/// The most recent mount, or null if there has not been one.
///
/// Non-web builds have no print surface to build, so the arguments a mount was
/// given are its only observable consequence. Keeping the latest pair - two
/// fields rather than a growing list, so nothing accumulates in a long session
/// - is what lets the DF-031 CP-C parity property be asserted behaviourally
/// instead of structurally: that a preference change re-invokes the mount with
/// the newly resolved script (plan.md §5.5 fact 3, §12 CP-C items 1 and 5).
PrintSurfaceMount? lastPrintSurfaceMount;

/// How many mounts have happened. Distinguishes a re-mount carrying the same
/// script from no re-mount at all.
int printSurfaceMountCount = 0;

/// Clears the recorded mounts. For tests that assert counts.
void resetPrintSurfaceMounts() {
  lastPrintSurfaceMount = null;
  printSurfaceMountCount = 0;
}

/// Non-web builds keep their existing native rendering and printing behaviour.
PrintSurfaceLease mountPrintSurface(
  String markdownSource, {
  required HanScript script,
}) {
  lastPrintSurfaceMount = PrintSurfaceMount(
    markdownSource: markdownSource,
    script: script,
  );
  printSurfaceMountCount++;
  return _lifecycle.beginMount();
}

void unmountPrintSurface(PrintSurfaceLease lease) {
  _lifecycle.release(lease);
}
