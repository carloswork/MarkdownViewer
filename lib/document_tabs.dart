import 'dart:ui' show PointerDeviceKind, SemanticsRole;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'markdown_theme.dart';
import 'models.dart';

/// Reader viewport width from which open documents are shown as tabs.
///
/// The Material compact/medium boundary: phones in portrait are below it and
/// get the `Documents` switcher in the Reader menu instead. Independent of
/// the Search pane's breakpoint.
const double kDocumentTabsBreakpoint = 600;

/// How a document is named in a tab or in the switcher.
///
/// A file is named by its filename. A pasted document has none, so it is
/// named by its derived title; Home keeps calling it `Pasted document`.
String documentTabLabel(MarkdownDocument document) =>
    document.sourceName ?? document.title;

/// The wide-layout tab strip: one tab per open document, in set order.
///
/// Shown only with two or more documents (D-3). It scrolls horizontally when
/// the tabs do not fit, keeps the active tab in view, and is a tab list to
/// assistive technology. While [busy] - a load, close or removal is being
/// verified - nothing in it acts (S10-08).
class DocumentTabBar extends StatefulWidget {
  const DocumentTabBar({
    super.key,
    required this.documents,
    required this.activeId,
    required this.busy,
    required this.onSelect,
    required this.onClose,
    this.onReorder,
  });

  final List<MarkdownDocument> documents;
  final String? activeId;
  final bool busy;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onClose;

  /// A tab was dropped on the tab at [toIndex], possibly its own (DF-086):
  /// the app moves [id] there and makes it active (D-004). Null: no drag.
  final void Function(String id, int toIndex)? onReorder;

  @override
  State<DocumentTabBar> createState() => _DocumentTabBarState();
}

class _DocumentTabBarState extends State<DocumentTabBar> {
  /// One key per open document, so each tab keeps its State - and its
  /// keyboard focus - when it becomes active or moves (DF-086). Keying only
  /// the active tab would rebuild a tab the moment it is selected, and a
  /// keyboard user's focus would fall to the next control.
  final _tabKeys = <String, GlobalKey>{};

  GlobalKey _keyFor(String id) => _tabKeys.putIfAbsent(id, GlobalKey.new);

  /// The strip's width at its last layout. A narrower strip can push the
  /// active tab out of view without the active document or the count
  /// changing, so a width change reveals it too (S10-07).
  double? _lastWidth;

  /// The document whose tab is being dragged, shown dimmed in place.
  String? _draggingId;

  /// Scrolls the strip while a dragged tab is held near either edge.
  EdgeDraggingAutoScroller? _autoScroller;

  /// Inside the strip's scroll view, for its viewport and its scrolling.
  BuildContext? _scrollContext;

  /// Where the dragging pointer is, in global coordinates.
  Offset? _pointer;

  /// The tab the dragged tab would land on, for the insertion mark.
  int? _hoverIndex;

  @override
  void dispose() {
    _autoScroller?.stopAutoScroll();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _revealActive();
  }

  @override
  void didUpdateWidget(DocumentTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeId != widget.activeId ||
        !_sameOrder(oldWidget.documents, widget.documents)) {
      final open = {for (final document in widget.documents) document.id};
      _tabKeys.removeWhere((id, _) => !open.contains(id));
      _revealActive();
    }
  }

  /// Whether [a] and [b] list the same documents in the same order. A count
  /// change or a manual move (DF-086) can each push the active tab out of view.
  static bool _sameOrder(List<MarkdownDocument> a, List<MarkdownDocument> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  void _revealActive() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final id = widget.activeId;
      final context = id == null ? null : _tabKeys[id]?.currentContext;
      if (context == null) return;
      Scrollable.ensureVisible(context, alignment: 0.5);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = ReaderPalette.of(context);
    return Material(
      color: palette.background,
      child: SafeArea(
        bottom: false,
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: palette.codeBorder)),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              if (_lastWidth != null && _lastWidth != width) _revealActive();
              _lastWidth = width;
              return _strip(palette);
            },
          ),
        ),
      ),
    );
  }

  Widget _strip(ReaderPalette palette) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      // The tab list sits inside the scroller so that its semantic
      // children are the tabs themselves.
      child: Builder(
        builder: (scrollContext) {
          _scrollContext = scrollContext;
          return Semantics(
            role: SemanticsRole.tabBar,
            container: true,
            explicitChildNodes: true,
            child: Row(
              children: [
                for (final (index, document) in widget.documents.indexed)
                  _draggableTab(index, document, palette),
              ],
            ),
          );
        },
      ),
    );
  }

  /// A tab that can be dragged onto another tab's place (DF-086).
  ///
  /// Mouse and trackpad start a drag after the usual slop, so a click still
  /// selects; touch and stylus need a long press, so a swipe still scrolls
  /// the strip. Tab drags are Flutter pointer drags, never HTML drag events,
  /// so the file-drop adapter does not see them. While [DocumentTabBar.busy]
  /// no drag starts and no drop applies (S10-08).
  ///
  /// The tab a drop lands on is worked out from where the pointer is over the
  /// tabs as they are laid out now ([_tabAt]), not by hit-testing drop
  /// targets: while the strip auto-scrolls, a scrolling view ignores the
  /// pointer, so a drop held at the edge would otherwise land nowhere.
  Widget _draggableTab(
    int index,
    MarkdownDocument document,
    ReaderPalette palette,
  ) {
    final id = document.id;
    final label = documentTabLabel(document);
    final active = id == widget.activeId;
    final busy = widget.busy;
    final tab = Opacity(
      opacity: _draggingId == id ? 0.4 : 1,
      child: _DocumentTab(
        key: _keyFor(id),
        label: label,
        active: active,
        busy: busy,
        palette: palette,
        onSelect: () => widget.onSelect(id),
        onClose: () => widget.onClose(id),
      ),
    );
    if (widget.onReorder == null) return tab;

    // What follows the pointer: a picture of the tab, outside the semantics
    // and focus trees.
    final feedback = ExcludeFocus(
      child: ExcludeSemantics(
        child: Material(
          elevation: 3,
          color: palette.surface,
          borderRadius: BorderRadius.circular(8),
          child: _DocumentTab(
            label: label,
            active: true,
            busy: false,
            palette: palette,
            onSelect: () {},
            onClose: () {},
          ),
        ),
      ),
    );
    final drags = busy ? 0 : 1;
    void started() => setState(() => _draggingId = id);

    // The insertion mark: on the side the dragged tab will land.
    final from = _draggingId == null || _hoverIndex != index
        ? -1
        : widget.documents.indexWhere((d) => d.id == _draggingId);
    final mark = BorderSide(width: 2, color: palette.text);
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: Border(
          left: from > index ? mark : BorderSide.none,
          right: from >= 0 && from < index ? mark : BorderSide.none,
        ),
      ),
      child: _MouseTabDraggable(
        data: id,
        maxSimultaneousDrags: drags,
        feedback: feedback,
        onDragStarted: started,
        onDragUpdate: _dragMoved,
        onDragEnd: (_) => _dropped(),
        child: _TouchTabDraggable(
          data: id,
          maxSimultaneousDrags: drags,
          feedback: feedback,
          onDragStarted: started,
          onDragUpdate: _dragMoved,
          onDragEnd: (_) => _dropped(),
          child: tab,
        ),
      ),
    );
  }

  void _dragMoved(DragUpdateDetails details) {
    _pointer = details.globalPosition;
    _updateHover();
    final scrollable = _scrollContext == null
        ? null
        : Scrollable.maybeOf(_scrollContext!);
    if (scrollable == null) return;
    _autoScroller ??= EdgeDraggingAutoScroller(
      scrollable,
      velocityScalar: 20,
      onScrollViewScrolled: _autoScrolled,
    );
    _autoScroller!.startAutoScrollIfNecessary(_pointerRect(_pointer!));
  }

  Rect _pointerRect(Offset pointer) =>
      Rect.fromCenter(center: pointer, width: 40, height: 40);

  /// After each auto-scroll step: the tabs have moved under a pointer that
  /// may be held still, so the landing tab is worked out again, and the
  /// scroller is re-armed from the pointer's place relative to the new scroll
  /// offset. Otherwise a still pointer at the edge scrolls only one step.
  void _autoScrolled() {
    _updateHover();
    final pointer = _pointer;
    if (pointer != null) {
      _autoScroller?.startAutoScrollIfNecessary(_pointerRect(pointer));
    }
  }

  void _updateHover() {
    final pointer = _pointer;
    final hover = pointer == null ? null : _tabAt(pointer);
    if (mounted && hover != _hoverIndex) setState(() => _hoverIndex = hover);
  }

  /// A drag ended: the dragged tab takes the place of the tab under the
  /// pointer (its own place: it is only activated), or nothing happens when
  /// it was released off the strip.
  void _dropped() {
    final id = _draggingId;
    final pointer = _pointer;
    final target = pointer == null ? null : _tabAt(pointer);
    _endDrag();
    if (id == null || target == null || widget.busy) return;
    widget.onReorder?.call(id, target);
  }

  /// The index of the tab at [global], as the strip is laid out now.
  ///
  /// Only a point inside the visible strip counts (with a little vertical
  /// tolerance, since a horizontal drag drifts). Between the first or last tab
  /// and the strip's edge, the nearest end tab counts.
  int? _tabAt(Offset global) {
    final context = _scrollContext;
    final view = context == null
        ? null
        : Scrollable.maybeOf(context)?.context.findRenderObject();
    if (view is! RenderBox || !view.hasSize) return null;
    final strip = view.localToGlobal(Offset.zero) & view.size;
    if (!strip.inflate(16).contains(global) ||
        global.dx < strip.left ||
        global.dx >= strip.right) {
      return null;
    }
    final documents = widget.documents;
    for (var i = 0; i < documents.length; i++) {
      final box = _tabKeys[documents[i].id]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      final left = box.localToGlobal(Offset.zero).dx;
      if (i == 0 && global.dx < left) return 0;
      if (global.dx < left + box.size.width) return i;
    }
    return documents.isEmpty ? null : documents.length - 1;
  }

  void _endDrag() {
    _autoScroller?.stopAutoScroll();
    _autoScroller = null;
    _pointer = null;
    if (mounted && (_draggingId != null || _hoverIndex != null)) {
      setState(() {
        _draggingId = null;
        _hoverIndex = null;
      });
    }
  }
}

/// Mouse and trackpad: a horizontal drag that starts after the usual slop.
class _MouseTabDraggable extends Draggable<String> {
  const _MouseTabDraggable({
    required super.child,
    required super.feedback,
    super.data,
    super.maxSimultaneousDrags,
    super.onDragStarted,
    super.onDragUpdate,
    super.onDragEnd,
  }) : super(axis: Axis.horizontal);

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) => HorizontalMultiDragGestureRecognizer(
    supportedDevices: const {
      PointerDeviceKind.mouse,
      PointerDeviceKind.trackpad,
    },
  )..onStart = onStart;
}

/// Touch and stylus: a long press starts the drag, so a swipe still scrolls.
class _TouchTabDraggable extends LongPressDraggable<String> {
  const _TouchTabDraggable({
    required super.child,
    required super.feedback,
    super.data,
    super.maxSimultaneousDrags,
    super.onDragStarted,
    super.onDragUpdate,
    super.onDragEnd,
  }) : super(axis: Axis.horizontal, hapticFeedbackOnStart: false);

  @override
  DelayedMultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) => DelayedMultiDragGestureRecognizer(
    supportedDevices: const {
      PointerDeviceKind.touch,
      PointerDeviceKind.stylus,
      PointerDeviceKind.invertedStylus,
    },
  )..onStart = onStart;
}

/// One tab: the tab itself, then its close control.
///
/// Keyboard (DF-086 D-005, DF-020 S10-06): the tab's own semantics node is
/// focusable, so in the browser's accessibility mode it is a focus stop, and
/// a browser focus on it moves Flutter focus to [_focus]. That node belongs to
/// a focus detector around the label only, never around the close control:
/// were it the close control's focus ancestor, Shift+Tab in the browser would
/// skip every tab but the first. Enter and Space select the tab. While [busy]
/// the tab stays focusable, so focus does not jump, but nothing acts (S10-08).
class _DocumentTab extends StatefulWidget {
  const _DocumentTab({
    super.key,
    required this.label,
    required this.active,
    required this.busy,
    required this.palette,
    required this.onSelect,
    required this.onClose,
  });

  final String label;
  final bool active;
  final bool busy;
  final ReaderPalette palette;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  State<_DocumentTab> createState() => _DocumentTabState();
}

class _DocumentTabState extends State<_DocumentTab> {
  final _focus = FocusNode(debugLabel: 'Document tab');

  /// Whether focus should be shown: keyboard focus, not a pointer's.
  bool _highlight = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _select() {
    if (!widget.busy) widget.onSelect();
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    final active = widget.active;
    final busy = widget.busy;
    final label = widget.label;
    return Semantics(
      role: SemanticsRole.tab,
      container: true,
      explicitChildNodes: true,
      selected: active,
      enabled: !busy,
      focusable: true,
      focused: _focus.hasFocus,
      onFocus: _focus.requestFocus,
      label: label,
      onTap: busy ? null : widget.onSelect,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
        child: Material(
          color: active ? palette.surface : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            // The keyboard focus indicator.
            side: _highlight && _focus.hasFocus
                ? BorderSide(color: palette.text, width: 2)
                : BorderSide.none,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: busy ? null : widget.onSelect,
            excludeFromSemantics: true,
            // The tab's single focus stop is the detector below.
            canRequestFocus: false,
            child: Padding(
              padding: const EdgeInsets.only(left: 12, right: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FocusableActionDetector(
                    focusNode: _focus,
                    // The tab's own semantics node carries focus.
                    includeFocusSemantics: false,
                    onFocusChange: (_) => setState(() {}),
                    onShowFocusHighlight: (show) =>
                        setState(() => _highlight = show),
                    actions: {
                      ActivateIntent: CallbackAction<ActivateIntent>(
                        onInvoke: (_) => _select(),
                      ),
                      ButtonActivateIntent:
                          CallbackAction<ButtonActivateIntent>(
                            onInvoke: (_) => _select(),
                          ),
                    },
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 180),
                      // The full name is the tab's label for assistive
                      // technology; the visible text may be truncated.
                      child: ExcludeSemantics(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: active
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: active ? palette.text : palette.muted,
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close $label',
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    color: palette.muted,
                    onPressed: busy ? null : widget.onClose,
                    icon: Icon(
                      Icons.close_rounded,
                      semanticLabel: 'Close $label',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The narrow-layout switcher: the open documents as a modal list, following
/// the Contents pattern. Selecting one switches to it; each can be closed.
///
/// Resolves to the action chosen, or null when dismissed.
Future<DocumentsSheetAction?> showDocumentsSheet(
  BuildContext context, {
  required List<MarkdownDocument> documents,
  required String? activeId,
}) {
  final palette = ReaderPalette.of(context);
  return showModalBottomSheet<DocumentsSheetAction>(
    context: context,
    backgroundColor: palette.background,
    isScrollControlled: true,
    builder: (context) => _DocumentsSheet(
      documents: documents,
      activeId: activeId,
      palette: palette,
    ),
  );
}

/// What the switcher asked for.
class DocumentsSheetAction {
  const DocumentsSheetAction.select(this.id) : close = false;
  const DocumentsSheetAction.close(this.id) : close = true;

  final String id;
  final bool close;
}

class _DocumentsSheet extends StatelessWidget {
  const _DocumentsSheet({
    required this.documents,
    required this.activeId,
    required this.palette,
  });

  final List<MarkdownDocument> documents;
  final String? activeId;
  final ReaderPalette palette;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                'Documents',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: palette.text,
                ),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final document in documents)
                    _DocumentRow(
                      label: documentTabLabel(document),
                      active: document.id == activeId,
                      palette: palette,
                      onSelect: () => Navigator.pop(
                        context,
                        DocumentsSheetAction.select(document.id),
                      ),
                      onClose: () => Navigator.pop(
                        context,
                        DocumentsSheetAction.close(document.id),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _DocumentRow extends StatelessWidget {
  const _DocumentRow({
    required this.label,
    required this.active,
    required this.palette,
    required this.onSelect,
    required this.onClose,
  });

  final String label;
  final bool active;
  final ReaderPalette palette;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minTileHeight: 48,
      selected: active,
      leading: Icon(
        active ? Icons.check_rounded : Icons.description_outlined,
        color: active ? palette.text : palette.muted,
      ),
      title: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 16,
          color: palette.text,
          fontWeight: active ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      onTap: onSelect,
      trailing: IconButton(
        tooltip: 'Close $label',
        color: palette.muted,
        onPressed: onClose,
        icon: Icon(Icons.close_rounded, semanticLabel: 'Close $label'),
      ),
    );
  }
}

/// `Move document` (DF-086 D-003): the three moves for the document at
/// [index] of [count], as a sheet. A move that is not available (the document
/// is already first, or last) is shown disabled.
///
/// The wide layout's tabs run left to right; the narrow `Documents` list runs
/// top to bottom, so there the moves are up and down ([horizontal] false).
/// Resolves to the target index, or null when dismissed.
Future<int?> showMoveDocumentSheet(
  BuildContext context, {
  required int index,
  required int count,
  required bool horizontal,
}) {
  final palette = ReaderPalette.of(context);
  return showModalBottomSheet<int>(
    context: context,
    backgroundColor: palette.background,
    builder: (context) {
      // A move that is not available stays a button to assistive
      // technology, exposed as disabled, rather than becoming plain text.
      Widget move(IconData icon, String label, int? to) => MergeSemantics(
        child: Semantics(
          button: true,
          child: ListTile(
            minTileHeight: 48,
            visualDensity: VisualDensity.compact,
            enabled: to != null,
            leading: Icon(icon, color: palette.muted),
            title: Text(
              label,
              style: TextStyle(
                fontSize: 16,
                color: to != null ? palette.text : palette.muted,
              ),
            ),
            onTap: to == null ? null : () => Navigator.pop(context, to),
          ),
        ),
      );
      final first = index <= 0;
      final last = index >= count - 1;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                'Move document',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: palette.text,
                ),
              ),
            ),
            move(Icons.first_page_rounded, 'Move to first', first ? null : 0),
            move(
              horizontal
                  ? Icons.chevron_left_rounded
                  : Icons.keyboard_arrow_up_rounded,
              horizontal ? 'Move left' : 'Move up',
              first ? null : index - 1,
            ),
            move(
              horizontal
                  ? Icons.chevron_right_rounded
                  : Icons.keyboard_arrow_down_rounded,
              horizontal ? 'Move right' : 'Move down',
              last ? null : index + 1,
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}
