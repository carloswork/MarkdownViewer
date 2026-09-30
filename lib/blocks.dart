import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:markdown_widget/markdown_widget.dart';

import 'han_script.dart';
import 'markdown_theme.dart';
import 'reader_text_unit.dart';

/// Above this many characters, syntax highlighting is skipped.
///
/// Highlighting is pure-Dart regex work on the main isolate; a very large block
/// produces a visible hitch under CanvasKit. Plain monospace is a fine trade.
const int kMaxHighlightChars = 20000;

/// A fenced code block.
///
/// Default behaviour is horizontal scrolling, not wrapping: wrapped code breaks
/// indentation, which makes technical content harder to read rather than easier.
/// The user can opt into wrapping in settings.
class CodeBlock extends StatelessWidget {
  const CodeBlock({
    super.key,
    required this.code,
    required this.language,
    required this.palette,
    required this.wrap,
    this.script = kDefaultHanScript,
    this.ownerId,
  });

  final String code;
  final String language;
  final ReaderPalette palette;
  final bool wrap;

  /// The document's resolved Han lead, threaded from `buildMarkdownConfig`.
  ///
  /// The fenced-code `baseStyle` is built here rather than in `markdown_theme`,
  /// so without this the Han families would reach inline code and prose but not
  /// fenced blocks - and technical Markdown routinely puts Chinese identifiers
  /// and comments inside them (plan.md §7.2).
  final HanScript script;

  /// DF-052 CP2: the structural occurrence owner id, set when this block is
  /// built through the Reader's capture pass ([reader_text_unit.dart]). When
  /// present the block reads its per-owner match state from [ReaderSearchScope]
  /// and paints occurrence overlays across the highlighted token leaves; when
  /// null (print surface, tests) the block renders exactly as before.
  final OccurrenceOwnerId? ownerId;

  /// Returns a copy carrying [id]; used by the capture pass so the app-owned
  /// `PreConfig.builder` widget need not know the id at construction.
  CodeBlock withOwner(OccurrenceOwnerId id) => CodeBlock(
    key: key,
    code: code,
    language: language,
    palette: palette,
    wrap: wrap,
    script: script,
    ownerId: id,
  );

  @override
  Widget build(BuildContext context) {
    final trimmed = code.trimRight();
    final baseStyle = TextStyle(
      fontFamily: kCodeFont,
      fontSize: kBodyFontSize - 3,
      height: 1.45,
      color: palette.text,
      fontFamilyFallback: codeFontFallbackFor(script),
    );

    final id = ownerId;
    final scope = id == null ? null : ReaderSearchScope.maybeOf(context);
    final state = id == null ? null : scope?.model.matchStateFor(id);
    Widget text = _buildCodeText(trimmed, baseStyle, state);
    // Wrap the drawing code `Text.rich` (never the surrounding Container, whose
    // language-bar `Text` is a separate RenderParagraph) as one render candidate
    // when this is the active occurrence (plan.md §D-1). The vertical-axis
    // reveal skips the wrap-off inner horizontal scroller below.
    if (id != null && scope != null && state?.active != null) {
      text = ActiveOccurrenceLocator(
        ownerId: id,
        registry: scope.registry,
        revision: scope.revision,
        label: scope.model.activeLabel ?? '',
        child: text,
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: palette.codeBackground,
        border: Border.all(color: palette.codeBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CodeBlockBar(language: language, palette: palette, code: trimmed),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: wrap
                ? text
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: text,
                  ),
          ),
        ],
      ),
    );
  }

  /// Renders the code, highlighted when that is both possible and worthwhile.
  ///
  /// A fenced block with no language is the common case in AI-generated
  /// technical writing - directory trees, call graphs, console output - and the
  /// highlighter throws `ArgumentError.notNull('language')` rather than
  /// degrading when handed a null language. Untagged blocks therefore render as
  /// plain monospace, which is also the correct presentation for them.
  ///
  /// The catch is deliberate belt-and-braces: an unknown language already falls
  /// back to plaintext inside the highlighter, but no single code block should
  /// ever be able to take down the surrounding document.
  Widget _buildCodeText(String trimmed, TextStyle baseStyle, OwnerMatchState? state) {
    final indication = OccurrenceIndicationStyle.of(palette);

    // Overlays partition the displayed code by cumulative UTF-16 offset, so a
    // match is painted whether the block is plain or syntax-highlighted, with no
    // retokenization on query change (plan.md §5.5).
    Widget draw(InlineSpan root) {
      if (state == null || state.all.isEmpty) return Text.rich(root, softWrap: wrap);
      return Text.rich(paintOccurrences(root, state, indication), softWrap: wrap);
    }

    Widget plain() {
      if (state == null || state.all.isEmpty) {
        return Text(trimmed, style: baseStyle, softWrap: wrap);
      }
      return draw(TextSpan(text: trimmed, style: baseStyle));
    }

    if (language.isEmpty || trimmed.length > kMaxHighlightChars) {
      return plain();
    }

    try {
      final spans = highLightSpans(
        trimmed,
        language: language,
        theme: palette.highlightTheme,
        textStyle: baseStyle,
        styleNotMatched: TextStyle(color: palette.text),
      );
      return draw(TextSpan(children: spans));
    } catch (error) {
      debugPrint('Code highlighting failed for language "$language": $error');
      return plain();
    }
  }
}

class _CodeBlockBar extends StatelessWidget {
  const _CodeBlockBar({
    required this.language,
    required this.palette,
    required this.code,
  });

  final String language;
  final ReaderPalette palette;
  final String code;

  /// Copies the block, and says so either way.
  ///
  /// A clipboard write is not always permitted: `navigator.clipboard` only
  /// exists in a secure context, so an app served over plain HTTP from a LAN
  /// address (as during device testing) cannot copy at all. Previously the
  /// resulting exception escaped an async callback, the confirmation never ran,
  /// and the button looked dead. Deployment over HTTPS is the supported case;
  /// this just makes the unsupported one honest rather than silent.
  Future<void> _copy(BuildContext context) async {
    // Resolved before the await: the context must not be used across it.
    final messenger = ScaffoldMessenger.of(context);

    var copied = false;
    try {
      await Clipboard.setData(ClipboardData(text: code));
      copied = true;
    } catch (error) {
      // Deliberately not diagnosed further. A missing secure context is the
      // cause we have actually measured, but a permission policy or an
      // unavailable platform integration can raise the same exception, so the
      // message offers https as a likely cause rather than asserting it.
      debugPrint('Clipboard write failed: $error');
    }

    // The block may have scrolled out of the tree while the write was pending.
    if (!messenger.mounted) return;

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            copied
                ? 'Code copied'
                : "Couldn't copy to clipboard. A secure (https) connection "
                      'may be required.',
          ),
          duration: Duration(seconds: copied ? 1 : 3),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              language.isEmpty ? 'code' : language,
              style: TextStyle(
                fontFamily: kCodeFont,
                fontSize: 11,
                color: palette.muted,
                letterSpacing: 0.4,
              ),
            ),
          ),
          _IconAction(
            icon: Icons.copy_rounded,
            tooltip: 'Copy code',
            color: palette.muted,
            onTap: () => _copy(context),
          ),
        ],
      ),
    );
  }
}

/// A Markdown table.
///
/// Scrolls horizontally on its own so a wide table never forces the page to
/// scroll sideways, with a right-edge fade so it is discoverable that there are
/// more columns, and a full-screen view for tables that are genuinely too wide
/// to read in a phone-width strip.
class TableBlock extends StatefulWidget {
  const TableBlock({super.key, required this.table, required this.palette});

  final Widget table;
  final ReaderPalette palette;

  @override
  State<TableBlock> createState() => _TableBlockState();
}

class _TableBlockState extends State<TableBlock> {
  final ScrollController _controller = ScrollController();
  bool _canScrollRight = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_update);
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  void _update() {
    if (!mounted || !_controller.hasClients) return;
    final position = _controller.position;
    final canScroll = position.maxScrollExtent - position.pixels > 1;
    if (canScroll != _canScrollRight) {
      setState(() => _canScrollRight = canScroll);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_update);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              SingleChildScrollView(
                controller: _controller,
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  // Without an upper bound, IntrinsicColumnWidth lets a table
                  // with one prose-heavy column grow to an absurd width.
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: widget.table,
                ),
              ),
              if (_canScrollRight)
                Positioned(
                  top: 0,
                  bottom: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Container(
                      width: 28,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            palette.background.withValues(alpha: 0),
                            palette.background,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: _IconAction(
              icon: Icons.open_in_full_rounded,
              tooltip: 'Open table full screen',
              color: palette.muted,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      _FullScreenTable(table: widget.table, palette: palette),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FullScreenTable extends StatelessWidget {
  const _FullScreenTable({required this.table, required this.palette});

  final Widget table;
  final ReaderPalette palette;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(
        backgroundColor: palette.background,
        surfaceTintColor: Colors.transparent,
        foregroundColor: palette.text,
        elevation: 0,
        title: Text(
          'Table',
          style: TextStyle(fontSize: 16, color: palette.text),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Rotate the device for more width.',
                style: TextStyle(fontSize: 12, color: palette.muted),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.vertical,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  child: table,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Stands in for a remote image instead of loading it.
///
/// Loading `![](https://…)` from a pasted document would tell a third-party
/// server that this document is being read, and on iOS Safari it is also a
/// known CanvasKit memory-leak crash. The URL is shown and can be opened
/// deliberately, which keeps the decision with the reader.
class RemoteImagePlaceholder extends StatelessWidget {
  const RemoteImagePlaceholder({
    super.key,
    required this.url,
    required this.alt,
    required this.palette,
    required this.onOpen,
    this.runOwnerIds,
  });

  final String url;
  final String alt;
  final ReaderPalette palette;
  final void Function(String url) onOpen;

  /// DF-052 CP2: one structural occurrence owner id per displayed run, index-
  /// aligned to [displayedTextLines] (label, status, and — for a remote image —
  /// URL). Set by the capture pass so each run reads its own per-owner match
  /// state from [ReaderSearchScope] (decision.md D-004). Null off the Reader path.
  final List<OccurrenceOwnerId>? runOwnerIds;

  /// Returns a copy carrying the per-run owner [ids]; used by the capture pass.
  RemoteImagePlaceholder withRunOwners(List<OccurrenceOwnerId> ids) =>
      RemoteImagePlaceholder(
        key: key,
        url: url,
        alt: alt,
        palette: palette,
        onOpen: onOpen,
        runOwnerIds: ids,
      );

  static bool _isRemoteUrl(String url) =>
      url.startsWith('http://') || url.startsWith('https://');

  bool get _isRemote => _isRemoteUrl(url);

  /// The generated status sentence shown for a remote image.
  static const String remoteStatus =
      'Remote image not loaded. Tap to open it in a new tab.';

  /// The generated status sentence shown for a non-remote image.
  static const String localStatus = 'Image not available offline.';

  /// The visible text lines this placeholder renders, top to bottom: the
  /// alt/fallback label, the generated status sentence, and (for a remote
  /// image) the displayed URL. Single source of truth for both `build` and
  /// DF-052 Search capture (decision.md D-004), so the searchable text cannot
  /// drift from what is drawn.
  static List<String> displayedTextLines({
    required String url,
    required String alt,
  }) {
    final isRemote = _isRemoteUrl(url);
    return <String>[
      alt.isNotEmpty ? alt : 'Image',
      isRemote ? remoteStatus : localStatus,
      if (isRemote) url,
    ];
  }

  /// Draws run [index]'s displayed text, painting occurrence overlays and — when
  /// it is the active occurrence — wrapping it as one render candidate exposing
  /// the single promoted locator (plan.md §D-1, decision.md D-004). Off the Reader
  /// path (`runOwnerIds == null`) it renders exactly as a plain `Text`.
  Widget _runText(
    BuildContext context,
    int index,
    String text,
    TextStyle style, {
    bool softWrap = false,
  }) {
    final ids = runOwnerIds;
    final id = (ids != null && index < ids.length) ? ids[index] : null;
    final scope = id == null ? null : ReaderSearchScope.maybeOf(context);
    final state = id == null ? null : scope?.model.matchStateFor(id);
    if (state == null || state.all.isEmpty) {
      return Text(text, style: style, softWrap: softWrap);
    }
    Widget painted = Text.rich(
      paintOccurrences(
        TextSpan(text: text, style: style),
        state,
        OccurrenceIndicationStyle.of(palette),
      ),
      softWrap: softWrap,
    );
    if (state.active != null && scope != null) {
      painted = ActiveOccurrenceLocator(
        ownerId: id!,
        registry: scope.registry,
        revision: scope.revision,
        label: scope.model.activeLabel ?? '',
        child: painted,
      );
    }
    return painted;
  }

  @override
  Widget build(BuildContext context) {
    final lines = displayedTextLines(url: url, alt: alt);
    final label = lines[0];
    final status = lines[1];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        onTap: _isRemote ? () => onOpen(url) : null,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: palette.surface,
            border: Border.all(color: palette.codeBorder),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.image_not_supported_outlined,
                    size: 16,
                    color: palette.muted,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: _runText(
                      context,
                      0,
                      label,
                      TextStyle(
                        fontSize: kBodyFontSize - 2,
                        color: palette.text,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              _runText(
                context,
                1,
                status,
                TextStyle(fontSize: 12, color: palette.muted),
              ),
              if (_isRemote) ...[
                const SizedBox(height: 2),
                // DF-052 D-004: Search indexes the full URL, so the full URL
                // must be presented. It wraps across as many lines as needed
                // (at the URL's break opportunities) rather than ellipsizing a
                // hidden suffix, so no searchable literal is concealed.
                _runText(
                  context,
                  2,
                  url,
                  TextStyle(
                    fontFamily: kCodeFont,
                    fontSize: 11,
                    color: palette.link,
                  ),
                  softWrap: true,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Small, low-contrast tap target used inside content blocks.
class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 16, color: color),
        ),
      ),
    );
  }
}
