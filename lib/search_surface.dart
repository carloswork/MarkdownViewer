import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'document_search.dart';
import 'markdown_theme.dart';

const double kSearchPaneHorizontalInset = 16;
const double kMinimumSearchPaneContentWidth = 328;
const double kSearchPaneWidth =
    kMinimumSearchPaneContentWidth + 2 * kSearchPaneHorizontalInset;
const double kSearchPaneDividerWidth = 1;
const double kWideReaderSidePadding = 32;
const double kMinimumReaderContentWidthBesideSearch = 656;
const double kMinimumReaderRegionBesideSearch =
    kMinimumReaderContentWidthBesideSearch + 2 * kWideReaderSidePadding;
const double kSearchPaneBreakpoint =
    kSearchPaneWidth +
    kSearchPaneDividerWidth +
    kMinimumReaderRegionBesideSearch;

bool usesPersistentSearchPane(double readerViewportWidth) =>
    readerViewportWidth >= kSearchPaneBreakpoint;

enum SearchSurfaceMode { pane, sheet }

class _SearchFocusScope extends StatefulWidget {
  const _SearchFocusScope({required this.mode, required this.child});

  final SearchSurfaceMode mode;
  final Widget child;

  @override
  State<_SearchFocusScope> createState() => _SearchFocusScopeState();
}

class _SearchFocusScopeState extends State<_SearchFocusScope> {
  late final FocusScopeNode _node = FocusScopeNode(
    debugLabel: 'Search ${widget.mode.name} scope',
    traversalEdgeBehavior: _edgeBehavior,
  );

  TraversalEdgeBehavior get _edgeBehavior =>
      widget.mode == SearchSurfaceMode.sheet
      ? TraversalEdgeBehavior.closedLoop
      : TraversalEdgeBehavior.parentScope;

  @override
  void didUpdateWidget(_SearchFocusScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _node.traversalEdgeBehavior = _edgeBehavior;
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusScope.withExternalFocusNode(
    focusScopeNode: _node,
    child: widget.child,
  );
}

class SearchSurface extends StatelessWidget {
  const SearchSurface({
    super.key,
    required this.mode,
    required this.palette,
    required this.controller,
    required this.fieldFocusNode,
    required this.resultFocusNode,
    required this.resultListFocusNode,
    required this.previousFocusNode,
    required this.nextFocusNode,
    required this.closeFocusNode,
    required this.isPreparing,
    required this.result,
    required this.activeMatchIndex,
    required this.onQueryChanged,
    required this.onSubmitted,
    required this.onSelect,
    required this.onPrevious,
    required this.onNext,
    required this.onClose,
  });

  final SearchSurfaceMode mode;
  final ReaderPalette palette;
  final TextEditingController controller;
  final FocusNode fieldFocusNode;
  final FocusNode resultFocusNode;
  final FocusNode resultListFocusNode;
  final FocusNode previousFocusNode;
  final FocusNode nextFocusNode;
  final FocusNode closeFocusNode;
  final bool isPreparing;
  final DocumentSearchResult? result;
  final int? activeMatchIndex;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<String> onSubmitted;
  final ValueChanged<int> onSelect;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final current = result;
    final canNavigate =
        !isPreparing &&
        current != null &&
        current.isAvailable &&
        !current.isOverflow &&
        current.matches.isNotEmpty;

    return Material(
      key: ValueKey(
        mode == SearchSurfaceMode.pane ? 'search-pane' : 'search-sheet',
      ),
      color: palette.background,
      child: SafeArea(
        child: _SearchFocusScope(
          mode: mode,
          child: FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Search document',
                          style: TextStyle(
                            color: palette.text,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(100002),
                        child: Tooltip(
                          message: mode == SearchSurfaceMode.pane
                              ? 'Close search'
                              : 'Close results',
                          child: IconButton(
                            key: const ValueKey('search-close'),
                            constraints: const BoxConstraints(
                              minWidth: 48,
                              minHeight: 48,
                            ),
                            focusNode: closeFocusNode,
                            onPressed: onClose,
                            icon: const Icon(Icons.close_rounded),
                            color: palette.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: FocusTraversalOrder(
                    order: const NumericFocusOrder(1),
                    child: CallbackShortcuts(
                      bindings: {
                        const SingleActivator(LogicalKeyboardKey.enter): () =>
                            onSubmitted(controller.text),
                        const SingleActivator(
                          LogicalKeyboardKey.enter,
                          shift: true,
                        ): () =>
                            onSubmitted(controller.text),
                      },
                      child: TextField(
                        key: const ValueKey('search-field'),
                        controller: controller,
                        focusNode: fieldFocusNode,
                        autofocus: activeMatchIndex == null,
                        textInputAction: TextInputAction.search,
                        decoration: const InputDecoration(
                          labelText: 'Find in document',
                          hintText: 'Enter text to search',
                          prefixIcon: Icon(Icons.search_rounded),
                          border: OutlineInputBorder(),
                        ),
                        onChanged: onQueryChanged,
                        onSubmitted: onSubmitted,
                      ),
                    ),
                  ),
                ),
                Expanded(child: _results(current)),
                DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: palette.rule)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _countLabel(current),
                            key: const ValueKey('search-result-count'),
                            style: TextStyle(
                              color: palette.muted,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        if (mode == SearchSurfaceMode.pane)
                          FocusTraversalOrder(
                            order: const NumericFocusOrder(100000),
                            child: Tooltip(
                              message: 'Previous result',
                              child: IconButton(
                                key: const ValueKey('search-previous'),
                                constraints: const BoxConstraints(
                                  minWidth: 48,
                                  minHeight: 48,
                                ),
                                focusNode: previousFocusNode,
                                onPressed: canNavigate ? onPrevious : null,
                                icon: const Icon(
                                  Icons.keyboard_arrow_up_rounded,
                                ),
                              ),
                            ),
                          ),
                        if (mode == SearchSurfaceMode.pane)
                          FocusTraversalOrder(
                            order: const NumericFocusOrder(100001),
                            child: Tooltip(
                              message: 'Next result',
                              child: IconButton(
                                key: const ValueKey('search-next'),
                                constraints: const BoxConstraints(
                                  minWidth: 48,
                                  minHeight: 48,
                                ),
                                focusNode: nextFocusNode,
                                onPressed: canNavigate ? onNext : null,
                                icon: const Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Semantics(
                  liveRegion: true,
                  label: _announcement(current),
                  child: const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _results(DocumentSearchResult? current) {
    if (isPreparing) {
      return const Center(
        key: ValueKey('search-preparing'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Preparing search…'),
          ],
        ),
      );
    }
    if (current == null || current.isNeutral) {
      return _message('Enter a search term');
    }
    if (!current.isAvailable) {
      return _message(current.message!);
    }
    if (current.isOverflow) {
      return _message(
        '${current.total} matches. Refine your search to navigate.',
      );
    }
    if (current.matches.isEmpty) return _message('No results');

    final active = activeMatchIndex;
    final listLabel = active == null
        ? 'Search results'
        : 'Search results. Result ${active + 1} of ${current.total} selected';
    return Focus(
      focusNode: resultListFocusNode,
      skipTraversal: true,
      autofocus: mode == SearchSurfaceMode.sheet && active != null,
      child: Semantics(
        label: listLabel,
        child: _SearchResultList(
          itemCount: current.matches.length,
          activeIndex: active,
          itemBuilder: (context, index) {
            final match = current.matches[index];
            final selected = active == index;
            return FocusTraversalOrder(
              order: NumericFocusOrder(2 + index.toDouble()),
              child: Semantics(
                button: true,
                selected: selected,
                label: _rowLabel(match, current.total),
                child: ListTile(
                  key: ValueKey('search-result-$index'),
                  focusNode: selected ? resultFocusNode : null,
                  selected: selected,
                  selectedTileColor: palette.link.withValues(alpha: 0.12),
                  title: match.heading == null
                      ? null
                      : Text(
                          match.heading!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                  subtitle: _snippet(match.snippet),
                  trailing: Text(
                    '${match.ordinal}',
                    style: TextStyle(color: palette.muted),
                  ),
                  onTap: () => onSelect(index),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _message(String message) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(color: palette.muted),
      ),
    ),
  );

  Widget _snippet(SearchSnippet snippet) => RichText(
    maxLines: 3,
    overflow: TextOverflow.ellipsis,
    text: TextSpan(
      style: TextStyle(color: palette.muted, height: 1.35),
      children: [
        TextSpan(
          text: snippet.leadingTruncated
              ? '…${snippet.leading}'
              : snippet.leading,
        ),
        TextSpan(
          text: snippet.match,
          style: TextStyle(
            color: palette.text,
            fontWeight: FontWeight.w700,
            backgroundColor: palette.link.withValues(alpha: 0.18),
          ),
        ),
        TextSpan(text: snippet.trailing),
        if (snippet.trailingTruncated) const TextSpan(text: '…'),
      ],
    ),
  );

  String _countLabel(DocumentSearchResult? current) {
    if (isPreparing) return 'Preparing';
    if (current == null || current.isNeutral) return 'No query';
    if (!current.isAvailable) return 'Unavailable';
    if (current.total == 1) return '1 result';
    return '${current.total} results';
  }

  String _announcement(DocumentSearchResult? current) {
    if (isPreparing || current == null || current.isNeutral) return '';
    if (!current.isAvailable) return current.message!;
    if (current.isOverflow) {
      return '${current.total} results. Refine your search to navigate.';
    }
    if (current.matches.isEmpty) return 'No results';
    final active = activeMatchIndex;
    if (active == null) return '${current.total} results';
    final match = current.matches[active];
    final heading = match.heading;
    return heading == null
        ? 'Result ${active + 1} of ${current.total}'
        : 'Result ${active + 1} of ${current.total}, $heading';
  }

  String _rowLabel(SearchMatch match, int total) {
    final heading = match.heading;
    final prefix = 'Result ${match.ordinal} of $total';
    return heading == null
        ? '$prefix. ${match.snippet.plainText}'
        : '$prefix. $heading. ${match.snippet.plainText}';
  }
}

enum _RevealEdge { start, end }

/// Progress of revealing a row that started outside the laid-out range: the
/// edge it aligns to once laid out, and proven bounds on its scroll start.
class _RevealSearch {
  const _RevealSearch(this.edge, this.lower, this.upper);

  final _RevealEdge edge;
  final double lower;
  final double upper;
}

/// Virtualized results list that keeps the active row in view when the active
/// result changes while the list is mounted, scrolling only as far as needed.
///
/// A freshly mounted list keeps its initial offset, so a transition-created
/// modal still exercises the accepted results-list focus fallback.
class _SearchResultList extends StatefulWidget {
  const _SearchResultList({
    required this.itemCount,
    required this.activeIndex,
    required this.itemBuilder,
  });

  final int itemCount;
  final int? activeIndex;
  final IndexedWidgetBuilder itemBuilder;

  @override
  State<_SearchResultList> createState() => _SearchResultListState();
}

class _SearchResultListState extends State<_SearchResultList> {
  // Each unbuilt attempt lays the row out or narrows its proven bounds, and
  // every third attempt bisects them, so 64 attempts cover any list extent.
  static const int _maxRevealAttempts = 64;

  final ScrollController _controller = ScrollController();
  final Map<int, BuildContext> _activeRows = {};
  int _revealGeneration = 0;

  void _registerRow(int index, BuildContext row) => _activeRows[index] = row;

  void _unregisterRow(int index, BuildContext row) {
    if (identical(_activeRows[index], row)) _activeRows.remove(index);
  }

  @override
  void didUpdateWidget(_SearchResultList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final active = widget.activeIndex;
    if (active == null || active == oldWidget.activeIndex) return;
    _scheduleReveal(active, ++_revealGeneration, 0, null);
  }

  void _scheduleReveal(
    int index,
    int generation,
    int attempt,
    _RevealSearch? search,
  ) {
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _reveal(index, generation, attempt, search),
    );
  }

  /// The sliver holding this list's rows, found through any registered row.
  RenderSliverMultiBoxAdaptor? _rowSliver() {
    for (final row in _activeRows.values) {
      var node = row.findRenderObject();
      while (node != null && node.parent is! RenderSliverMultiBoxAdaptor) {
        node = node.parent;
      }
      final sliver = node?.parent;
      if (sliver is RenderSliverMultiBoxAdaptor && sliver.firstChild != null) {
        return sliver;
      }
    }
    return null;
  }

  /// Keeps row [index] visible. The edge it aligns to comes from where the row
  /// actually is relative to the viewport, never from the navigation direction.
  /// [search] carries, for a row that started unbuilt, the side it was found on
  /// and the scroll-offset bounds on its start learned from earlier layouts, so
  /// the final alignment still scrolls only as far as necessary.
  void _reveal(int index, int generation, int attempt, _RevealSearch? search) {
    final edge = search?.edge;
    if (!mounted ||
        generation != _revealGeneration ||
        widget.activeIndex != index ||
        !_controller.hasClients ||
        index >= widget.itemCount) {
      return;
    }
    final position = _controller.position;

    // Rows register only while their elements are active in this list.
    final row = _activeRows[index]?.findRenderObject();
    final viewport = row == null ? null : RenderAbstractViewport.maybeOf(row);
    if (row != null && viewport != null) {
      final alignStart = viewport.getOffsetToReveal(row, 0).offset;
      final alignEnd = viewport.getOffsetToReveal(row, 1).offset;
      final above = position.pixels > alignStart;
      final below = position.pixels < alignEnd;
      final side =
          edge ??
          (above
              ? _RevealEdge.start
              : below
              ? _RevealEdge.end
              : null);
      if (side == null) return; // Already fully visible.
      // A row taller than the viewport shows its start.
      final target = side == _RevealEdge.start || alignEnd > alignStart
          ? alignStart
          : alignEnd;
      _controller.jumpTo(
        target.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
      return;
    }
    if (attempt >= _maxRevealAttempts) return;

    // The row is outside the sliver's laid-out range, which is contiguous and
    // carries exact scroll offsets. Estimate the row's start from that range's
    // own boundary and average extent, keep the estimate inside the bounds that
    // earlier layouts proved, and jump so each attempt either lays the row out
    // or narrows those bounds.
    final sliver = _rowSliver();
    if (sliver == null) return;
    final rangeViewport = RenderAbstractViewport.of(sliver);
    final first = sliver.firstChild!;
    final last = sliver.lastChild!;
    final firstIndex = sliver.indexOf(first);
    final lastIndex = sliver.indexOf(last);
    final viewportExtent = position.viewportDimension;
    final firstStart = rangeViewport.getOffsetToReveal(first, 0).offset;
    final lastEnd =
        rangeViewport.getOffsetToReveal(last, 1).offset + viewportExtent;
    final averageExtent = (lastEnd - firstStart) / (lastIndex - firstIndex + 1);

    final before = index < firstIndex;
    var lower = search?.lower ?? position.minScrollExtent;
    var upper = search?.upper ?? double.infinity;
    double estimate;
    if (before) {
      upper = math.min(upper, firstStart);
      estimate = firstStart - (firstIndex - index) * averageExtent;
    } else {
      lower = math.max(lower, lastEnd);
      estimate = lastEnd + (index - lastIndex - 1) * averageExtent;
    }
    // Fall back to bisection when the local estimate leaves the proven bounds,
    // and on every third attempt, so convergence is logarithmic in distance.
    if (upper.isFinite &&
        (estimate <= lower || estimate >= upper || attempt % 3 == 2)) {
      estimate = (lower + upper) / 2;
    }
    final side = edge ?? (before ? _RevealEdge.start : _RevealEdge.end);
    var target = side == _RevealEdge.start
        ? estimate
        : estimate + averageExtent - viewportExtent;
    target = target.clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() < 0.5) {
      // Never re-issue the current offset while the row is still unbuilt.
      target =
          (before
                  ? position.pixels - viewportExtent
                  : position.pixels + viewportExtent)
              .clamp(position.minScrollExtent, position.maxScrollExtent);
      if ((target - position.pixels).abs() < 0.5) return;
    }
    _controller.jumpTo(target);
    _scheduleReveal(
      index,
      generation,
      attempt + 1,
      _RevealSearch(side, lower, upper),
    );
  }

  @override
  void dispose() {
    _revealGeneration++;
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
    key: const ValueKey('search-result-list'),
    controller: _controller,
    itemCount: widget.itemCount,
    itemBuilder: (context, index) => _SearchResultRowAnchor(
      index: index,
      list: this,
      child: widget.itemBuilder(context, index),
    ),
  );
}

/// Records which result rows currently have active elements in the list.
class _SearchResultRowAnchor extends StatefulWidget {
  const _SearchResultRowAnchor({
    required this.index,
    required this.list,
    required this.child,
  });

  final int index;
  final _SearchResultListState list;
  final Widget child;

  @override
  State<_SearchResultRowAnchor> createState() => _SearchResultRowAnchorState();
}

class _SearchResultRowAnchorState extends State<_SearchResultRowAnchor> {
  @override
  void initState() {
    super.initState();
    widget.list._registerRow(widget.index, context);
  }

  @override
  void didUpdateWidget(_SearchResultRowAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index ||
        !identical(oldWidget.list, widget.list)) {
      oldWidget.list._unregisterRow(oldWidget.index, context);
      widget.list._registerRow(widget.index, context);
    }
  }

  @override
  void activate() {
    super.activate();
    widget.list._registerRow(widget.index, context);
  }

  @override
  void deactivate() {
    widget.list._unregisterRow(widget.index, context);
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class CompactSearchNavigator extends StatelessWidget {
  const CompactSearchNavigator({
    super.key,
    required this.palette,
    required this.result,
    required this.activeMatchIndex,
    required this.reopenFocusNode,
    required this.previousFocusNode,
    required this.nextFocusNode,
    required this.onShowResults,
    required this.onPrevious,
    required this.onNext,
    required this.onClose,
  });

  final ReaderPalette palette;
  final DocumentSearchResult? result;
  final int? activeMatchIndex;
  final FocusNode reopenFocusNode;
  final FocusNode previousFocusNode;
  final FocusNode nextFocusNode;
  final VoidCallback onShowResults;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final current = result;
    final canNavigate =
        current != null &&
        current.isAvailable &&
        !current.isOverflow &&
        current.matches.isNotEmpty;
    final active = activeMatchIndex;
    final label = canNavigate && active != null
        ? '${active + 1} of ${current.total}'
        : current == null || current.isNeutral
        ? 'Search'
        : '${current.total} results';

    return Material(
      key: const ValueKey('compact-search-navigator'),
      color: palette.surface,
      elevation: 3,
      borderRadius: BorderRadius.circular(28),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            label: 'Show search results. $label',
            button: true,
            // Excluding the child's semantics also drops its tap action, so the
            // wrapper carries the same activation as the visible control.
            onTap: onShowResults,
            excludeSemantics: true,
            child: Tooltip(
              message: 'Show search results',
              child: TextButton.icon(
                key: const ValueKey('search-reopen-results'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                focusNode: reopenFocusNode,
                onPressed: onShowResults,
                icon: const Icon(Icons.search_rounded),
                label: Text(label),
              ),
            ),
          ),
          Semantics(
            label: 'Previous result',
            button: true,
            enabled: canNavigate,
            onTap: canNavigate ? onPrevious : null,
            excludeSemantics: true,
            child: Tooltip(
              message: 'Previous result',
              child: IconButton(
                key: const ValueKey('compact-search-previous'),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                focusNode: previousFocusNode,
                onPressed: canNavigate ? onPrevious : null,
                icon: const Icon(Icons.keyboard_arrow_up_rounded),
              ),
            ),
          ),
          Semantics(
            label: 'Next result',
            button: true,
            enabled: canNavigate,
            onTap: canNavigate ? onNext : null,
            excludeSemantics: true,
            child: Tooltip(
              message: 'Next result',
              child: IconButton(
                key: const ValueKey('compact-search-next'),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                focusNode: nextFocusNode,
                onPressed: canNavigate ? onNext : null,
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
              ),
            ),
          ),
          Semantics(
            label: 'Close search',
            button: true,
            onTap: onClose,
            excludeSemantics: true,
            child: Tooltip(
              message: 'Close search',
              child: IconButton(
                key: const ValueKey('compact-search-close'),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: onClose,
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
