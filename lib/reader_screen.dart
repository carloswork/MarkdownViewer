import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'links.dart';
import 'markdown_theme.dart';
import 'models.dart';
import 'settings_sheet.dart';
import 'store.dart';
import 'toc_sheet.dart';

/// The reading surface.
///
/// One indexed list drives three requirements at once: jumping from the table
/// of contents, tracking where reading stopped, and restoring that position on
/// the next visit. That is why the document is rendered as a list of top-level
/// block widgets rather than with the package's all-in-one MarkdownWidget,
/// which exposes neither a scroll controller nor an initial index.
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.document,
    required this.settings,
    required this.onSettingsChanged,
    required this.onEdit,
    required this.onLoadFile,
    required this.onReturnHome,
  });

  final MarkdownDocument document;
  final Settings settings;
  final ValueChanged<Settings> onSettingsChanged;
  final VoidCallback onEdit;

  /// Opens the app's existing load-from-file workflow.
  ///
  /// A navigation seam only: picking, validating, confirming replacement and
  /// reporting failures all stay in one place in `main.dart`. The reader is a
  /// second entry point to that flow, not a second copy of it.
  final VoidCallback onLoadFile;

  final VoidCallback onReturnHome;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver {
  final ItemScrollController _scrollController = ItemScrollController();
  final ItemPositionsListener _positionsListener =
      ItemPositionsListener.create();

  List<Widget> _blocks = const [];
  List<TocEntry> _toc = const [];
  String? _blocksKey;

  ReadingPosition? _restore;
  ReadingPosition? _latest;
  Timer? _saveDebounce;

  bool _controlsVisible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restore = store.loadPosition(widget.document.id);
    _positionsListener.itemPositions.addListener(_onPositionsChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Picks up brightness changes. A rebuild is already scheduled, so the block
    // list can be replaced directly without calling setState.
    _rebuildBlocksIfNeeded();
  }

  @override
  void didUpdateWidget(covariant ReaderScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _rebuildBlocksIfNeeded();
  }

  @override
  void dispose() {
    _positionsListener.itemPositions.removeListener(_onPositionsChanged);
    _saveDebounce?.cancel();
    _flushPosition();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // iOS Safari can discard a backgrounded tab without further warning, so the
    // pending position is written immediately rather than waiting out the debounce.
    if (state != AppLifecycleState.resumed) {
      _saveDebounce?.cancel();
      _flushPosition();
    }
  }

  // --- Rendering ------------------------------------------------------------

  /// Parsing and building the whole document is expensive, so it happens only
  /// when something that actually changes the output changes.
  void _rebuildBlocksIfNeeded() {
    final palette = ReaderPalette.of(context);
    final document = widget.document;
    final key = [
      document.id,
      document.updatedAt.microsecondsSinceEpoch,
      palette.isDark,
      widget.settings.wrapCode,
    ].join('|');

    if (key == _blocksKey) return;

    final config = buildMarkdownConfig(
      palette: palette,
      wrapCode: widget.settings.wrapCode,
      onLinkTap: _openLink,
    );

    final entries = <TocEntry>[];
    final blocks =
        MarkdownGenerator(
          linesMargin: const EdgeInsets.symmetric(vertical: 5),
        ).buildWidgets(
          document.source,
          config: config,
          onTocList: (tocList) {
            entries
              ..clear()
              ..addAll(
                tocList.map(
                  (toc) => TocEntry(
                    level: headingTag2Level[toc.node.headingConfig.tag] ?? 1,
                    text: toc.node.childrenSpan.toPlainText().trim(),
                    blockIndex: toc.widgetIndex,
                  ),
                ),
              );
          },
        );

    _blocks = blocks;
    _toc = entries;
    _blocksKey = key;
  }

  Future<void> _openLink(String url) async {
    final messenger = ScaffoldMessenger.of(context);
    final opened = await openExternalLink(url);
    if (!opened && mounted) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Could not open $url')));
    }
  }

  // --- Reading position -----------------------------------------------------

  void _onPositionsChanged() {
    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) return;

    // The top-most block that is still at least partly on screen.
    ItemPosition? top;
    for (final position in positions) {
      if (position.itemTrailingEdge <= 0) continue;
      if (top == null || position.index < top.index) top = position;
    }
    if (top == null) return;

    _latest = ReadingPosition(
      documentId: widget.document.id,
      blockIndex: top.index,
      // itemLeadingEdge is <= 0 once scrolled into a block; stored positive as
      // "how far into this block we are", in viewport heights.
      fraction: -top.itemLeadingEdge,
      headingText: _headingBefore(top.index),
      savedAt: DateTime.now(),
    );

    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), _flushPosition);
  }

  void _flushPosition() {
    final position = _latest;
    if (position == null) return;
    _latest = null;
    store.savePosition(position);
  }

  String? _headingBefore(int blockIndex) {
    TocEntry? found;
    for (final entry in _toc) {
      if (entry.blockIndex > blockIndex) break;
      found = entry;
    }
    return found?.text;
  }

  // --- Navigation -----------------------------------------------------------

  void _jumpTo(int blockIndex) {
    if (!_scrollController.isAttached) return;
    _scrollController.scrollTo(
      index: blockIndex.clamp(0, math.max(0, _blocks.length - 1)),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _openMenu() async {
    final palette = ReaderPalette.of(context);
    final action = await showModalBottomSheet<_MenuAction>(
      context: context,
      backgroundColor: palette.background,
      builder: (context) => _ReaderMenu(
        document: widget.document,
        palette: palette,
        hasToc: _toc.isNotEmpty,
      ),
    );
    if (!mounted || action == null) return;

    switch (action) {
      case _MenuAction.contents:
        final target = await showTocSheet(context, _toc);
        if (target != null) _jumpTo(target);
      case _MenuAction.appearance:
        await showSettingsSheet(
          context,
          settings: widget.settings,
          onChanged: widget.onSettingsChanged,
        );
      case _MenuAction.edit:
        widget.onEdit();
      case _MenuAction.loadFile:
        widget.onLoadFile();
      case _MenuAction.home:
        widget.onReturnHome();
    }
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final palette = ReaderPalette.of(context);
    final media = MediaQuery.of(context);

    final horizontal = readerHorizontalPadding(media.size.width);

    final restore = _restore;
    final initialIndex = restore == null
        ? 0
        : restore.blockIndex.clamp(0, math.max(0, _blocks.length - 1)).toInt();

    return Scaffold(
      backgroundColor: palette.background,
      body: MediaQuery(
        // Flutter Web/CanvasKit does not honour the iOS system text-size
        // setting, so the in-app control is the only way to change size.
        data: media.copyWith(
          textScaler: TextScaler.linear(widget.settings.fontScale),
        ),
        child: Stack(
          children: [
            NotificationListener<UserScrollNotification>(
              onNotification: _onUserScroll,
              child: SelectionArea(
                child: ScrollablePositionedList.builder(
                  itemCount: _blocks.length,
                  itemBuilder: (context, index) => _blocks[index],
                  itemScrollController: _scrollController,
                  itemPositionsListener: _positionsListener,
                  initialScrollIndex: initialIndex,
                  // Same units as ItemPosition.itemLeadingEdge, so this restores
                  // the exact offset within the block, not just the block.
                  initialAlignment: restore == null ? 0 : -restore.fraction,
                  padding: EdgeInsets.fromLTRB(
                    horizontal,
                    media.padding.top + 16,
                    horizontal,
                    media.padding.bottom + 96,
                  ),
                ),
              ),
            ),
            _MenuButton(
              visible: _controlsVisible,
              palette: palette,
              onTap: _openMenu,
            ),
          ],
        ),
      ),
    );
  }

  bool _onUserScroll(UserScrollNotification notification) {
    // Reader-first: the only persistent control gets out of the way while
    // reading forward and comes back the moment the user scrolls up.
    final direction = notification.direction;
    if (direction == ScrollDirection.reverse && _controlsVisible) {
      setState(() => _controlsVisible = false);
    } else if (direction == ScrollDirection.forward && !_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    return false;
  }
}

enum _MenuAction { contents, appearance, edit, loadFile, home }

class _ReaderMenu extends StatelessWidget {
  const _ReaderMenu({
    required this.document,
    required this.palette,
    required this.hasToc,
  });

  final MarkdownDocument document;
  final ReaderPalette palette;
  final bool hasToc;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      // Scrollable because a modal sheet is capped at a fraction of the
      // viewport height: on a short viewport (a phone in landscape) the header
      // plus four tiles is taller than the sheet is allowed to be, and a plain
      // Column overflows instead of scrolling.
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Document identity lives here rather than in a header bar: the
            // reader keeps every pixel of vertical space for the document.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    document.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: palette.text,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Icon(
                        document.origin == DocumentOrigin.file
                            ? Icons.description_outlined
                            : Icons.content_paste_rounded,
                        size: 13,
                        color: palette.muted,
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          document.identityLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: palette.muted,
                            fontFamily: document.origin == DocumentOrigin.file
                                ? kCodeFont
                                : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${document.wordCount} words',
                    style: TextStyle(fontSize: 13, color: palette.muted),
                  ),
                ],
              ),
            ),
            if (hasToc)
              _MenuTile(
                icon: Icons.list_rounded,
                label: 'Contents',
                palette: palette,
                onTap: () => Navigator.pop(context, _MenuAction.contents),
              ),
            _MenuTile(
              icon: Icons.tune_rounded,
              label: 'Appearance',
              palette: palette,
              onTap: () => Navigator.pop(context, _MenuAction.appearance),
            ),
            _MenuTile(
              // "Edit local copy", not "Edit Markdown": this changes the copy the
              // reader stores on this device and never writes back to a file.
              icon: Icons.edit_note_rounded,
              label: 'Edit local copy',
              palette: palette,
              onTap: () => Navigator.pop(context, _MenuAction.edit),
            ),
            _MenuTile(
              // Same icon and wording as the Home action: one workflow, two
              // entry points, so it should look like the same thing.
              icon: Icons.folder_open_rounded,
              label: 'Load from file',
              palette: palette,
              onTap: () => Navigator.pop(context, _MenuAction.loadFile),
            ),
            _MenuTile(
              icon: Icons.home_rounded,
              label: 'Return to main',
              palette: palette,
              onTap: () => Navigator.pop(context, _MenuAction.home),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.icon,
    required this.label,
    required this.palette,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final ReaderPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: palette.muted),
      title: Text(label, style: TextStyle(fontSize: 16, color: palette.text)),
      onTap: onTap,
    );
  }
}

class _MenuButton extends StatelessWidget {
  const _MenuButton({
    required this.visible,
    required this.palette,
    required this.onTap,
  });

  final bool visible;
  final ReaderPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 16,
      bottom: MediaQuery.of(context).padding.bottom + 20,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: IgnorePointer(
          ignoring: !visible,
          child: Material(
            color: palette.surface,
            shape: const CircleBorder(),
            elevation: 2,
            shadowColor: Colors.black.withValues(alpha: 0.25),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(13),
                child: Icon(
                  Icons.more_horiz_rounded,
                  size: 22,
                  color: palette.text,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
