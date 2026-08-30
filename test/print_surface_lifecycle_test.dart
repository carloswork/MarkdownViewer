import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/print_surface_lifecycle.dart';

void main() {
  group('PrintSurfaceLifecycle', () {
    test('a newer document supersedes every in-flight older mount', () {
      final lifecycle = PrintSurfaceLifecycle();
      final previous = lifecycle.beginMount();
      final current = lifecycle.beginMount();

      expect(lifecycle.isCurrent(previous), isFalse);
      expect(lifecycle.isCurrent(current), isTrue);
    });

    test('teardown invalidates an in-flight mount exactly once', () {
      final lifecycle = PrintSurfaceLifecycle();
      final pending = lifecycle.beginMount();

      expect(lifecycle.release(pending), isTrue);
      expect(lifecycle.isCurrent(pending), isFalse);
      expect(lifecycle.release(pending), isFalse);
    });

    test('late disposal of a replaced reader cannot clear its successor', () {
      final lifecycle = PrintSurfaceLifecycle();
      final replaced = lifecycle.beginMount();
      final successor = lifecycle.beginMount();

      expect(lifecycle.release(replaced), isFalse);
      expect(lifecycle.isCurrent(successor), isTrue);
    });

    test('disposing first permits a later reader to become current', () {
      final lifecycle = PrintSurfaceLifecycle();
      final first = lifecycle.beginMount();
      expect(lifecycle.release(first), isTrue);

      final later = lifecycle.beginMount();
      expect(lifecycle.isCurrent(later), isTrue);
    });
  });
}
