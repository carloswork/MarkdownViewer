import 'package:markdown/markdown.dart' as md;

/// The exact parser version is pinned in pubspec.yaml. These options mirror
/// markdown_widget 2.3.2+8's MarkdownGenerator defaults.
final RegExp markdownWidgetLineSplitter = RegExp(r'(\r?\n)|(\r)');

const int maxRetainedSearchAnchors = 20000;
const int _snippetContextCodeUnits = 56;

/// One renderer-aligned logical text run inside a top-level Markdown block.
///
/// Matches never cross run boundaries or a source newline within a run.
class SearchRun {
  const SearchRun(this.text);

  final String text;
}

/// Searchable text associated one-to-one with a rendered top-level widget.
class SearchBlock {
  const SearchBlock({
    required this.blockIndex,
    required this.runs,
    required this.heading,
  });

  final int blockIndex;
  final List<SearchRun> runs;
  final String? heading;

  int get retainedTextCodeUnits =>
      runs.fold(0, (total, run) => total + run.text.length);
}

/// Presentation-safe snippet parts. [match] is always the exact original text.
class SearchSnippet {
  const SearchSnippet({
    required this.leading,
    required this.match,
    required this.trailing,
    required this.leadingTruncated,
    required this.trailingTruncated,
  });

  final String leading;
  final String match;
  final String trailing;
  final bool leadingTruncated;
  final bool trailingTruncated;

  String get plainText =>
      '${leadingTruncated ? '…' : ''}$leading$match$trailing${trailingTruncated ? '…' : ''}';
}

class SearchMatch {
  const SearchMatch({
    required this.ordinal,
    required this.blockIndex,
    required this.runIndex,
    required this.start,
    required this.end,
    required this.heading,
    required this.snippet,
  });

  /// One-based, query-local result ordinal.
  final int ordinal;
  final int blockIndex;
  final int runIndex;
  final int start;
  final int end;
  final String? heading;
  final SearchSnippet snippet;
}

class DocumentSearchResult {
  const DocumentSearchResult._({
    required this.query,
    required this.total,
    required this.matches,
    required this.isAvailable,
    required this.message,
  });

  const DocumentSearchResult.available({
    required String query,
    required int total,
    required List<SearchMatch> matches,
  }) : this._(
         query: query,
         total: total,
         matches: matches,
         isAvailable: true,
         message: null,
       );

  const DocumentSearchResult.unavailable(String query)
    : this._(
        query: query,
        total: 0,
        matches: const [],
        isAvailable: false,
        message: 'Search is unavailable for this document',
      );

  final String query;
  final int total;

  /// False when the semantic blocks do not map one-to-one to rendered blocks.
  final bool isAvailable;
  final String? message;

  /// At most [maxRetainedSearchAnchors] document-ordered anchors.
  ///
  /// Callers must withhold navigation whenever [isOverflow] is true.
  final List<SearchMatch> matches;

  bool get isNeutral => query.isEmpty;
  bool get isOverflow => total > maxRetainedSearchAnchors;
}

/// Lazy, memory-only semantic index for one Reader/document identity.
class DocumentSearchIndex {
  DocumentSearchIndex._(this.blocks);

  factory DocumentSearchIndex.build(String source) {
    final document = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    );
    final nodes = document.parseLines(source.split(markdownWidgetLineSplitter));
    return DocumentSearchIndex._(_projectBlocks(nodes));
  }

  final List<SearchBlock> blocks;

  int get retainedTextCodeUnits =>
      blocks.fold(0, (total, block) => total + block.retainedTextCodeUnits);

  int get logicalRunCount =>
      blocks.fold(0, (total, block) => total + block.runs.length);

  /// Searches only after proving the index-to-renderer ordinal mapping.
  ///
  /// A mismatched count returns the exact unavailable state with no anchors,
  /// so callers cannot accidentally navigate via an unvalidated result.
  DocumentSearchResult search(String input, {required int renderedBlockCount}) {
    final query = input.trim();
    if (renderedBlockCount != blocks.length) {
      return DocumentSearchResult.unavailable(query);
    }
    if (query.isEmpty) {
      return const DocumentSearchResult.available(
        query: '',
        total: 0,
        matches: [],
      );
    }

    final expression = RegExp(RegExp.escape(query), caseSensitive: false);
    final matches = <SearchMatch>[];
    var total = 0;

    for (final block in blocks) {
      for (var runIndex = 0; runIndex < block.runs.length; runIndex++) {
        final text = block.runs[runIndex].text;
        for (final segment in _newlineFreeSegments(text)) {
          for (final match in expression.allMatches(segment.text)) {
            total++;
            if (matches.length >= maxRetainedSearchAnchors) continue;

            final start = segment.offset + match.start;
            final end = segment.offset + match.end;
            matches.add(
              SearchMatch(
                ordinal: total,
                blockIndex: block.blockIndex,
                runIndex: runIndex,
                start: start,
                end: end,
                heading: block.heading,
                snippet: _snippet(text, start, end),
              ),
            );
          }
        }
      }
    }

    return DocumentSearchResult.available(
      query: query,
      total: total,
      matches: List.unmodifiable(matches),
    );
  }
}

class _TextSegment {
  const _TextSegment(this.text, this.offset);

  final String text;
  final int offset;
}

Iterable<_TextSegment> _newlineFreeSegments(String text) sync* {
  var start = 0;
  for (var index = 0; index < text.length; index++) {
    final codeUnit = text.codeUnitAt(index);
    if (codeUnit != 10 && codeUnit != 13) continue;
    if (index > start) yield _TextSegment(text.substring(start, index), start);
    if (codeUnit == 13 &&
        index + 1 < text.length &&
        text.codeUnitAt(index + 1) == 10) {
      index++;
    }
    start = index + 1;
  }
  if (start < text.length) yield _TextSegment(text.substring(start), start);
}

SearchSnippet _snippet(String text, int start, int end) {
  final rawLeadingStart = start > _snippetContextCodeUnits
      ? start - _snippetContextCodeUnits
      : 0;
  final rawTrailingEnd = end + _snippetContextCodeUnits < text.length
      ? end + _snippetContextCodeUnits
      : text.length;
  return SearchSnippet(
    leading: _normalizeDisplayWhitespace(
      text.substring(rawLeadingStart, start),
    ),
    match: text.substring(start, end),
    trailing: _normalizeDisplayWhitespace(text.substring(end, rawTrailingEnd)),
    leadingTruncated: rawLeadingStart > 0,
    trailingTruncated: rawTrailingEnd < text.length,
  );
}

String _normalizeDisplayWhitespace(String value) =>
    value.replaceAll(RegExp(r'\s+'), ' ');

List<SearchBlock> _projectBlocks(List<md.Node> nodes) {
  final blocks = <SearchBlock>[];
  String? nearestHeading;

  for (var blockIndex = 0; blockIndex < nodes.length; blockIndex++) {
    final node = nodes[blockIndex];
    final collector = _RunCollector();
    _projectNode(node, collector);
    final runs = collector.finish();

    if (node is md.Element && _headingTags.contains(node.tag)) {
      final headingText = runs.map((run) => run.text).join().trim();
      if (headingText.isNotEmpty) nearestHeading = headingText;
    }

    blocks.add(
      SearchBlock(
        blockIndex: blockIndex,
        runs: List.unmodifiable(runs),
        heading: nearestHeading,
      ),
    );
  }

  return List.unmodifiable(blocks);
}

const Set<String> _headingTags = {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'};
const Set<String> _inlineContainers = {'a', 'del', 'strong', 'em'};
const Set<String> _structuralContainers = {
  'p',
  'blockquote',
  'ul',
  'ol',
  'li',
  'table',
  'thead',
  'tbody',
  'tr',
  'th',
  'td',
};

void _projectNode(md.Node node, _RunCollector collector) {
  if (node is md.Text) {
    collector.append(node.text);
    return;
  }
  if (node is! md.Element) return;

  final tag = node.tag;
  if (_headingTags.contains(tag) || _inlineContainers.contains(tag)) {
    _projectChildren(node, collector);
    return;
  }

  if (_structuralContainers.contains(tag)) {
    collector.boundary();
    _projectChildren(node, collector);
    collector.boundary();
    return;
  }

  switch (tag) {
    case 'code':
      collector.append(node.textContent);
    case 'pre':
      collector.addSeparate(node.textContent);
    case 'br':
      collector.boundary();
    case 'hr':
    case 'input':
      collector.boundary();
    case 'img':
      final alt = node.attributes['alt'] ?? '';
      if (alt.isNotEmpty) collector.addSeparate(alt);
      final source = node.attributes['src'] ?? '';
      if (source.startsWith('http://') || source.startsWith('https://')) {
        collector.addSeparate(source);
      }
    default:
      // markdown_widget's WidgetVisitor fallback creates one TextNode from
      // element.textContent and does not accept descendant text nodes into it.
      collector.addSeparate(node.textContent);
  }
}

void _projectChildren(md.Element element, _RunCollector collector) {
  for (final child in element.children ?? const <md.Node>[]) {
    _projectNode(child, collector);
  }
}

class _RunCollector {
  final List<String> _runs = [];
  StringBuffer? _current;

  void append(String text) {
    if (text.isEmpty) return;
    (_current ??= StringBuffer()).write(text);
  }

  void boundary() {
    final current = _current;
    if (current != null && current.isNotEmpty) _runs.add(current.toString());
    _current = null;
  }

  void addSeparate(String text) {
    boundary();
    if (text.isNotEmpty) _runs.add(text);
  }

  List<SearchRun> finish() {
    boundary();
    return _runs.map(SearchRun.new).toList(growable: false);
  }
}
