import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/blocks.dart';
import 'package:markdown_viewer/file_loader.dart';

import 'rendering_test.dart' show renderMarkdown, wrapForTest;

/// Round 2: the code-block Copy button used to fail silently.
///
/// `navigator.clipboard` only exists in a secure context, so on a plain-HTTP LAN
/// origin the write throws. The exception escaped an async callback, the
/// confirmation SnackBar never ran, and the button looked dead. These tests pin
/// both outcomes.
void main() {
  const codeBlockMarkdown = '```dart\nvoid main() {}\n```\n';

  Future<void> tapCopy(WidgetTester tester) async {
    await tester.pumpWidget(wrapForTest(renderMarkdown(codeBlockMarkdown)));
    expect(find.byType(CodeBlock), findsOneWidget);
    await tester.tap(find.byIcon(Icons.copy_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Replaces the platform channel so the clipboard write can be made to
  /// succeed or fail on demand.
  void mockClipboard({required bool succeed}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            if (!succeed) {
              throw PlatformException(
                code: 'copy_fail',
                message: 'Clipboard API not available',
              );
            }
            return null;
          }
          return null;
        });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('a successful copy confirms to the user', (tester) async {
    mockClipboard(succeed: true);

    await tapCopy(tester);

    expect(find.text('Code copied'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed copy reports honestly instead of doing nothing', (
    tester,
  ) async {
    mockClipboard(succeed: false);

    await tapCopy(tester);

    // The regression: before Round 2 this threw, no SnackBar appeared, and the
    // button appeared to do nothing at all.
    expect(tester.takeException(), isNull);
    expect(find.text('Code copied'), findsNothing);
    expect(find.textContaining('secure'), findsOneWidget);
  });

  group('picker type filter', () {
    test('the desktop filter matches the accepted extensions', () {
      // Derived from one list, so the picker filter and the validator cannot
      // drift apart. This asserts the derivation still holds.
      expect(markdownTypeGroup.extensions!.toSet(), kMarkdownExtensions);
    });

    test('every filtered extension passes validation', () {
      for (final extension in markdownTypeGroup.extensions!) {
        expect(isMarkdownFileName('document.$extension'), isTrue);
      }
    });
  });
}
