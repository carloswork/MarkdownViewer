import 'package:flutter/material.dart';
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
        child: ListView.builder(
          key: const ValueKey('search-result-list'),
          itemCount: current.matches.length,
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
          Tooltip(
            message: 'Show search results',
            child: TextButton.icon(
              key: const ValueKey('search-reopen-results'),
              focusNode: reopenFocusNode,
              onPressed: onShowResults,
              icon: const Icon(Icons.search_rounded),
              label: Text(label),
            ),
          ),
          Tooltip(
            message: 'Previous result',
            child: IconButton(
              key: const ValueKey('compact-search-previous'),
              focusNode: previousFocusNode,
              onPressed: canNavigate ? onPrevious : null,
              icon: const Icon(Icons.keyboard_arrow_up_rounded),
            ),
          ),
          Tooltip(
            message: 'Next result',
            child: IconButton(
              key: const ValueKey('compact-search-next'),
              focusNode: nextFocusNode,
              onPressed: canNavigate ? onNext : null,
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
            ),
          ),
          Tooltip(
            message: 'Close search',
            child: IconButton(
              key: const ValueKey('compact-search-close'),
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded),
            ),
          ),
        ],
      ),
    );
  }
}
