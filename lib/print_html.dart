import 'dart:convert';

// `markdown` is intentionally supplied by markdown_widget. DF-026 C1 is not
// authorized to add a dependency, and the accepted plan pins this transitive
// package at 7.3.1.
// ignore: depend_on_referenced_packages
import 'package:markdown/markdown.dart' as md;

const _allowedLinkSchemes = {'http', 'https', 'mailto'};

const _allowedCommonAttributes = {
  'class',
  'colspan',
  'rowspan',
  'start',
  'lang',
  'dir',
};

const _forbiddenElements = {
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
};

final _controlCharacters = RegExp(r'[\u0000-\u001f\u007f]');
final _encodedControlCharacters = RegExp(
  r'%(?:0[0-9a-f]|1[0-9a-f]|7f)',
  caseSensitive: false,
);

const _htmlTextEscape = HtmlEscape(
  HtmlEscapeMode(escapeLtGt: true, escapeQuot: true, escapeApos: true),
);

/// Builds the inert HTML representation used by the DF-026 print path.
///
/// The Markdown is parsed with the same GitHub-flavoured extension set used by
/// the reader. Raw HTML is encoded by the parser, then the AST is structurally
/// rewritten so images and rejected links are inert and only the accepted
/// attribute allow-list can reach [md.HtmlRenderer].
String buildPrintHtml(String markdownSource) {
  final document = md.Document(
    blockSyntaxes: const [_EscapingHtmlBlockSyntax()],
    inlineSyntaxes: [_EscapingInlineHtmlSyntax()],
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: true,
  );
  final parsed = document.parseLines(
    const LineSplitter().convert(markdownSource),
  );
  final rewritten = _rewriteNodes(parsed);

  _validateTrustBoundary(rewritten);
  return md.HtmlRenderer().render(rewritten);
}

/// `markdown` 7.3.1 evaluates GFM's raw-HTML syntaxes before its default
/// encodeHtml syntax. These two leading syntaxes preserve the mandated parser
/// configuration while ensuring raw block and inline HTML enter the AST as
/// encoded text rather than renderer-ready markup.
class _EscapingHtmlBlockSyntax extends md.HtmlBlockSyntax {
  const _EscapingHtmlBlockSyntax();

  @override
  md.Node parse(md.BlockParser parser) {
    final raw = super.parse(parser) as md.Text;
    return md.Text(_htmlTextEscape.convert(raw.text));
  }
}

class _EscapingInlineHtmlSyntax extends md.InlineHtmlSyntax {
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Text(_htmlTextEscape.convert(match[0]!)));
    return true;
  }
}

List<md.Node> _rewriteNodes(Iterable<md.Node> nodes) => [
  for (final node in nodes) ..._rewriteNode(node),
];

List<md.Node> _rewriteNode(md.Node node) {
  if (node is md.Text) return [node];
  if (node is md.UnparsedContent) {
    return [md.Text(_htmlTextEscape.convert(node.textContent))];
  }
  if (node is! md.Element) return const [];

  final tag = node.tag.toLowerCase();
  if (_forbiddenElements.contains(tag)) {
    return _rewriteNodes(node.children ?? const []);
  }

  if (tag == 'img') return [_imagePlaceholder(node)];
  if (tag == 'a') return _rewriteLink(node);
  if (tag == 'input' && node.attributes['type'] == 'checkbox') {
    final checked = node.attributes.containsKey('checked');
    return [md.Text(checked ? '[x] ' : '[ ] ')];
  }

  final children = node.children;
  final rewritten = children == null
      ? md.Element.empty(tag)
      : md.Element(tag, _rewriteNodes(children));
  _copyCommonAttributes(node, rewritten);
  return [rewritten];
}

md.Element _imagePlaceholder(md.Element image) {
  final alt = image.attributes['alt'] ?? '';
  final destination = image.attributes['src'] ?? '';
  return md.Element('span', [md.Text('[Image: $alt ($destination)]')])
    ..attributes['class'] = 'print-image-placeholder';
}

List<md.Node> _rewriteLink(md.Element link) {
  final children = _rewriteNodes(link.children ?? const []);
  final rawDestination = link.attributes['href'] ?? '';
  final destination = rawDestination.trim();
  final visibleDestination = md.Text(' ($rawDestination)');

  if (!_isAllowedLinkDestination(destination)) {
    return [...children, visibleDestination];
  }

  final rewritten = md.Element('a', [...children, visibleDestination])
    ..attributes['href'] = destination
    ..attributes['rel'] = 'noopener noreferrer';
  _copyCommonAttributes(link, rewritten);
  return [rewritten];
}

bool _isAllowedLinkDestination(String destination) {
  if (_controlCharacters.hasMatch(destination) ||
      _encodedControlCharacters.hasMatch(destination)) {
    return false;
  }
  final uri = Uri.tryParse(destination);
  return uri != null && _allowedLinkSchemes.contains(uri.scheme.toLowerCase());
}

void _copyCommonAttributes(md.Element source, md.Element target) {
  for (final entry in source.attributes.entries) {
    if (_allowedCommonAttributes.contains(entry.key.toLowerCase())) {
      target.attributes[entry.key.toLowerCase()] = entry.value;
    }
  }
}

void _validateTrustBoundary(Iterable<md.Node> nodes) {
  for (final node in nodes) {
    if (node is! md.Element) continue;

    final tag = node.tag.toLowerCase();
    if (_forbiddenElements.contains(tag) || tag == 'img') {
      throw StateError('Forbidden print element survived the AST rewrite.');
    }

    for (final entry in node.attributes.entries) {
      final name = entry.key.toLowerCase();
      final isCommon = _allowedCommonAttributes.contains(name);
      final isAllowedHref = name == 'href' && tag == 'a';
      final isFixedRel =
          name == 'rel' && tag == 'a' && entry.value == 'noopener noreferrer';
      if (!isCommon && !isAllowedHref && !isFixedRel) {
        throw StateError(
          'Disallowed print attribute survived the AST rewrite.',
        );
      }
    }

    if (tag == 'a') {
      final href = node.attributes['href'];
      if (href == null ||
          !_isAllowedLinkDestination(href) ||
          node.attributes['rel'] != 'noopener noreferrer') {
        throw StateError('Disallowed print link survived the AST rewrite.');
      }
    }

    _validateTrustBoundary(node.children ?? const []);
  }
}
