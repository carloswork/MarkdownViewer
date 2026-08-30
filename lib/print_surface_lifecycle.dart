/// Orders asynchronous print-surface mounts without depending on a browser.
///
/// A reader owns one lease. Starting a newer mount supersedes every older
/// lease, while releasing a stale lease is deliberately inert. This makes
/// ReaderScreen replacement safe regardless of whether Flutter disposes the
/// old State before or after it creates the new one.
class PrintSurfaceLifecycle {
  int _generation = 0;

  PrintSurfaceLease beginMount() => PrintSurfaceLease._(++_generation);

  bool isCurrent(PrintSurfaceLease lease) =>
      lease._generation == _generation;

  bool release(PrintSurfaceLease lease) {
    if (!isCurrent(lease)) return false;
    _generation++;
    return true;
  }
}

class PrintSurfaceLease {
  const PrintSurfaceLease._(this._generation);

  final int _generation;
}
