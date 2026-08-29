import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/print_html.dart';

void main() {
  group('DF-026 section 7.3 policy', () {
    test('raw HTML is emitted as escaped text', () {
      const source =
          'Raw <script>alert(1)</script> and '
          '<b onclick="go()">bold</b>.';

      expect(
        buildPrintHtml(source),
        '<p>Raw &lt;script&gt;alert(1)&lt;/script&gt; and '
        '&lt;b onclick=&quot;go()&quot;&gt;bold&lt;/b&gt;.</p>',
      );
    });

    test(
      'Markdown image becomes an inert placeholder with visible details',
      () {
        final html = buildPrintHtml(
          '![diagram & notes](https://images.example.test/a.png?x=1&y=2)',
        );

        expect(
          html,
          '<p><span class="print-image-placeholder">'
          '[Image: diagram &amp; notes '
          '(https://images.example.test/a.png?x=1&y=2)]'
          '</span></p>',
        );
        expect(
          html,
          isNot(matches(RegExp(r'\s(?:src|srcset|poster|background)\s*='))),
        );
      },
    );

    test(
      'allowed links retain href and fixed rel with visible destinations',
      () {
        const source =
            '[web](http://example.test/path) '
            '[upper](HTTPS://example.test/upper) '
            '[secure](https://example.test/secure) '
            '[mail](mailto:reader@example.test)';

        expect(
          buildPrintHtml(source),
          '<p><a href="http://example.test/path" rel="noopener noreferrer">'
          'web (http://example.test/path)</a> '
          '<a href="HTTPS://example.test/upper" rel="noopener noreferrer">'
          'upper (HTTPS://example.test/upper)</a> '
          '<a href="https://example.test/secure" rel="noopener noreferrer">'
          'secure (https://example.test/secure)</a> '
          '<a href="mailto:reader@example.test" rel="noopener noreferrer">'
          'mail (mailto:reader@example.test)</a></p>',
        );
        expect(buildPrintHtml(source), isNot(contains('target=')));
      },
    );

    test('rejected and relative link destinations are inert visible text', () {
      const cases = {
        'javascript:alert(1)': 'javascript',
        'file:///C:/secret.txt': 'file',
        'data:text/plain,secret': 'data',
        'vbscript:msgbox(1)': 'vbscript',
        'custom:opaque': 'unknown',
        '../relative/path': 'relative',
      };

      for (final entry in cases.entries) {
        final html = buildPrintHtml('[${entry.value}](${entry.key})');
        expect(html, '<p>${entry.value} (${entry.key})</p>', reason: entry.key);
        expect(html, isNot(contains('<a')), reason: entry.key);
        expect(html, isNot(contains('href=')), reason: entry.key);
      }
    });

    test('encoded whitespace and controls cannot disguise a scheme', () {
      const source =
          '[leading](< https://example.test >) '
          '[entity](jav&#x61;script:alert) '
          '[control](https:&#10;//example.test/path)';
      final html = buildPrintHtml(source);

      expect(
        html,
        '<p>leading (%20https://example.test%20) '
        'entity (javascript:alert) '
        'control (https:%0A//example.test/path)</p>',
      );
      expect(html, isNot(contains('<a')));
      expect(html, isNot(contains('href=')));
    });

    test('only allow-listed attributes are emitted', () {
      const source = '''
```dart extra
code
```

3. third

- [x] done

| left | right |
| :--- | ---: |
| a | b |

[link](https://example.test "title")

<a class="raw" href="https://raw.example" rel="opener" style="color:red" onclick="go()">raw</a>
''';
      final html = buildPrintHtml(source);

      expect(
        html,
        '<pre><code class="language-dart">code\n</code></pre>\n'
        '<ol start="3">\n<li>third</li>\n</ol>\n'
        '<ul class="contains-task-list">\n'
        '<li class="task-list-item">[x] done</li>\n</ul>\n'
        '<table>\n<thead>\n<tr>\n<th>left</th>\n<th>right</th>\n</tr>\n'
        '</thead>\n<tbody>\n<tr>\n<td>a</td>\n<td>b</td>\n</tr>\n</tbody>\n'
        '</table>\n'
        '<p><a href="https://example.test" rel="noopener noreferrer">'
        'link (https://example.test)</a></p>\n'
        '<p>'
        '&lt;a class=&quot;raw&quot; href=&quot;https://raw.example&quot; '
        'rel=&quot;opener&quot; style=&quot;color:red&quot; '
        'onclick=&quot;go()&quot;&gt;raw&lt;/a&gt;</p>',
      );

      expect(_emittedAttributeNames(html), {'class', 'start', 'href', 'rel'});
      expect(html, isNot(matches(RegExp(r'\srel="(?!noopener noreferrer")'))));
      expect(
        _emittedAttributeNames(html).intersection({
          'align',
          'title',
          'style',
          'onclick',
          'type',
          'checked',
        }),
        isEmpty,
      );
    });

    test('forbidden elements are escaped and never emitted', () {
      const tags = [
        'script',
        'iframe',
        'object',
        'embed',
        'video',
        'audio',
        'svg',
        'link',
        'base',
        'meta',
        'form',
      ];
      final source = tags.map((tag) => '<$tag>payload</$tag>').join('\n');
      final html = buildPrintHtml(source);

      expect(
        html,
        tags.map((tag) => '&lt;$tag&gt;payload&lt;/$tag&gt;').join('\n'),
      );
      for (final tag in tags) {
        expect(html, isNot(contains('<$tag')), reason: tag);
      }
    });

    test('output has no automatic network-fetch path', () {
      const source = '''
![remote](https://remote.example/image.png)

[user navigation](https://allowed.example/path)

<video poster="https://remote.example/poster.png"><source src="https://remote.example/video.mp4"></video>
''';
      final html = buildPrintHtml(source);

      expect(
        html,
        '<p><span class="print-image-placeholder">'
        '[Image: remote (https://remote.example/image.png)]'
        '</span></p>\n'
        '<p><a href="https://allowed.example/path" '
        'rel="noopener noreferrer">user navigation '
        '(https://allowed.example/path)</a></p>\n'
        '<p>'
        '&lt;video poster=&quot;https://remote.example/poster.png&quot;&gt;'
        '&lt;source src=&quot;https://remote.example/video.mp4&quot;&gt;'
        '&lt;/video&gt;</p>',
      );
      expect(
        _emittedAttributeNames(html).intersection({
          'src',
          'srcset',
          'poster',
          'background',
          'formaction',
          'xlink:href',
        }),
        isEmpty,
      );
    });
  });

  test('reader block inventory has positive fixture coverage', () {
    final source = File('test/fixtures/df026-blocks.md').readAsStringSync();
    final html = buildPrintHtml(source);

    for (var level = 1; level <= 6; level++) {
      expect(html, contains('<h$level>Heading '), reason: 'heading h$level');
    }
    expect(html, contains('<p>Paragraph with <em>emphasis</em>'));
    expect(html, contains('<strong>strong emphasis</strong>'));
    expect(html, contains('<del>strikethrough</del>'));
    expect(html, contains('<code>inline code</code>'));
    expect(
      html,
      contains('<p>Hard line break first.<br />\nHard line break second.</p>'),
    );
    expect(html, contains('<pre><code class="language-dart">'));
    expect(html, contains('<ul>\n<li>Unordered item'));
    expect(html, contains('<ul>\n<li>Nested unordered item</li>'));
    expect(html, contains('<ol start="3">'));
    expect(html, contains('<ol>\n<li>Nested ordered item</li>'));
    expect(html, contains('[ ] Unchecked task'));
    expect(html, contains('[x] Checked task'));
    expect(html, contains('<blockquote>'));
    expect(html, contains('<hr />'));
    expect(html, contains('<table>'));
    expect(html, contains('<th>Left</th>'));
    expect(
      html,
      contains(
        '<a href="https://example.test/path" rel="noopener noreferrer">'
        'Allowed link (https://example.test/path)</a>',
      ),
    );
    expect(
      html,
      contains(
        '<span class="print-image-placeholder">'
        '[Image: Diagram alt (https://images.example.test/diagram.png)]'
        '</span>',
      ),
    );
  });

  test('empty document has exact empty output', () {
    expect(buildPrintHtml(''), '');
  });

  test('single-block document has exact paragraph output', () {
    expect(
      buildPrintHtml('One paragraph with *emphasis*.'),
      '<p>One paragraph with <em>emphasis</em>.</p>',
    );
  });

  test(
    'standalone HTML render makes no request beyond navigation',
    () {
      const source = '''
![off-origin](http://127.0.0.1:9/off-origin.png)

![same-origin](/same-origin.png)

![data](data:image/svg+xml,%3Csvg%3E%3C/svg%3E)

<script src="/raw-script.js"></script>
<iframe src="http://127.0.0.1:9/raw-frame.html"></iframe>
<link rel="stylesheet" href="/raw-style.css">
<video poster="/raw-poster.png"><source src="/raw-video.mp4"></video>
''';
      final emittedHtml = buildPrintHtml(source);

      expect(
        emittedHtml,
        contains(
          '<span class="print-image-placeholder">'
          '[Image: off-origin (http://127.0.0.1:9/off-origin.png)]</span>',
        ),
      );
      expect(
        emittedHtml,
        contains(
          '<span class="print-image-placeholder">'
          '[Image: same-origin (/same-origin.png)]</span>',
        ),
      );
      expect(
        emittedHtml,
        contains(
          '<span class="print-image-placeholder">'
          '[Image: data (data:image/svg+xml,%3Csvg%3E%3C/svg%3E)]</span>',
        ),
      );
      expect(
        emittedHtml,
        contains('&lt;script src=&quot;/raw-script.js&quot;'),
      );
      expect(
        emittedHtml,
        contains(
          '&lt;iframe src=&quot;http://127.0.0.1:9/raw-frame.html&quot;',
        ),
      );
      expect(emittedHtml, contains('&lt;link rel=&quot;stylesheet&quot;'));
      expect(
        emittedHtml,
        contains('&lt;video poster=&quot;/raw-poster.png&quot;'),
      );

      final template = File(
        'test/browser/df026_zero_request_harness.html',
      ).readAsStringSync();
      expect(template, contains('{{PRINT_HTML}}'));

      final scratch = Directory.systemTemp.createTempSync(
        'markdown_viewer_df026_c1_',
      );
      try {
        final harness = File('${scratch.path}/harness.html');
        harness.writeAsStringSync(
          template.replaceFirst('{{PRINT_HTML}}', emittedHtml),
        );

        final result = Process.runSync('node', [
          'test/browser/df026_zero_request_runner.mjs',
          '--chrome',
          r'C:\Program Files\Google\Chrome\Application\chrome.exe',
          '--html',
          harness.path,
        ]);

        expect(
          result.exitCode,
          0,
          reason:
              'runner stdout: ${result.stdout}\nrunner stderr: ${result.stderr}',
        );
        final evidence =
            jsonDecode(result.stdout as String) as Map<String, dynamic>;
        final requests = evidence['requests'] as List<dynamic>;
        expect(requests, hasLength(1), reason: evidence.toString());
        expect(
          requests.single,
          containsPair('resourceType', 'Document'),
          reason: evidence.toString(),
        );
        expect(evidence['requestsBeyondNavigation'], isEmpty);
        expect(evidence['sameOriginProbeRequests'], isEmpty);
      } finally {
        scratch.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('df026-long retained fixture matches its golden output', () {
    final source = File('test/fixtures/df026-long.md').readAsStringSync();
    final golden = File('test/goldens/df026-long.html').readAsStringSync();

    expect(buildPrintHtml(source), golden);
  });
}

Set<String> _emittedAttributeNames(String html) {
  final names = <String>{};
  for (final tag in RegExp(r'<[a-z][^>]*>').allMatches(html)) {
    for (final attribute in RegExp(r'\s([a-z][\w:-]*)=').allMatches(tag[0]!)) {
      names.add(attribute[1]!);
    }
  }
  return names;
}
