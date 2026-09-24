import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'document_search.dart';
import 'han_script.dart';
import 'links.dart';
import 'markdown_theme.dart';
import 'models.dart';
import 'print_surface.dart';
import 'script_rendering_sheet.dart';
import 'search_surface.dart';
import 'settings_sheet.dart';
import 'store.dart';
import 'toc_sheet.dart';

enum _SearchFocusRole { field, result, previous, next, close, locator, reopen }

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
    required this.onScriptPreferenceChanged,
    required this.onEdit,
    required this.onLoadFile,
    required this.onReturnHome,
    required this.onPositionChanged,
    this.sessionPosition,
    this.onSearchIndexBuilt,
  });

  final MarkdownDocument document;
  final Settings settings;
  final ValueChanged<Settings> onSettingsChanged;

  /// Persists the document's script preference and rebuilds with it.
  ///
  /// A seam only, and deliberately shaped like [onSettingsChanged]: the write is
  /// a `copyWith` plus a save plus a `setState` in `main.dart`, and it must not
  /// touch `updatedAt` (plan.md §5.5 fact 4, §5.7.2).
  final ValueChanged<DocumentScriptPreference> onScriptPreferenceChanged;

  final VoidCallback onEdit;

  /// Opens the app's existing load-from-file workflow.
  ///
  /// A navigation seam only: picking, validating, confirming replacement and
  /// reporting failures all stay in one place in `main.dart`. The reader is a
  /// second entry point to that flow, not a second copy of it.
  final VoidCallback onLoadFile;

  final VoidCallback onReturnHome;

  /// Reports where reading reached, on the same debounce as the durable save.
  ///
  /// DF-039 needs this because a durable position write is suppressed while
  /// retention is OFF, and `plan.md` §18.2 still requires returning Home in the
  /// same page lifetime to offer a continue that lands where the reader was.
  /// The app holds that position in memory; nothing here decides whether it is
  /// also stored.
  final ValueChanged<ReadingPosition> onPositionChanged;

  /// Where this page lifetime last reached, when nothing durable was stored.
  final ReadingPosition? sessionPosition;

  /// Test/evidence seam for proving lazy construction and resize reuse.
  final VoidCallback? onSearchIndexBuilt;

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

  /// The Reader's own top visible position, captured once at the moment wide
  /// Search closes.
  ///
  /// Closing wide Search changes the `LayoutBuilder` child's widget type (the
  /// pane's `Row` collapses back to the plain Reader region), so the list
  /// below is disposed and a new one takes its place. A fresh list has only
  /// `_restore` - the position from when the page was first mounted - to
  /// start from, which is not where reading last was. This anchor gives the
  /// new list the current position instead, for that one transition only. It
  /// is consumed once and cleared, so a later responsive crossing still
  /// starts from the unchanged `_restore`.
  ReadingPosition? _closeAnchor;

  bool _controlsVisible = true;
  late PrintSurfaceLease _printSurfaceLease;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _menuFocusNode = FocusNode(debugLabel: 'Reader menu');
  final FocusNode _searchFieldFocusNode = FocusNode(debugLabel: 'Search field');
  final FocusNode _searchResultFocusNode = FocusNode(
    debugLabel: 'Search result',
  );
  final FocusNode _searchResultListFocusNode = FocusNode(
    debugLabel: 'Search results',
  );
  final FocusNode _searchReopenFocusNode = FocusNode(
    debugLabel: 'Show search results',
  );
  final FocusNode _searchPreviousFocusNode = FocusNode(
    debugLabel: 'Previous result',
  );
  final FocusNode _searchNextFocusNode = FocusNode(debugLabel: 'Next result');
  final FocusNode _searchCloseFocusNode = FocusNode(debugLabel: 'Close search');
  final FocusNode _searchLocatorFocusNode = FocusNode(
    debugLabel: 'Active search result',
  );
  final ValueNotifier<int> _searchRevision = ValueNotifier(0);

  DocumentSearchIndex? _searchIndex;
  DocumentSearchResult? _searchResult;
  Timer? _searchDebounce;
  bool _searchOpen = false;
  bool _searchPreparing = false;
  bool _searchSheetOpen = false;
  bool _searchSheetSelectionInProgress = false;
  GlobalKey? _searchSheetRouteKey;
  _SearchFocusRole? _searchSheetRestoreRole;
  bool? _usesSearchPane;
  int? _activeSearchMatchIndex;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Durable first, then this page lifetime's in-memory position. Under OFF
    // there is never a durable one, and under ON the durable one is the more
    // authoritative of the two.
    final session = widget.sessionPosition;
    _restore =
        store.loadPosition(widget.document.id) ??
        (session != null && session.documentId == widget.document.id
            ? session
            : null);
    _positionsListener.itemPositions.addListener(_onPositionsChanged);
    _printSurfaceLease = mountPrintSurface(
      widget.document.source,
      script: _resolvedScript,
    );
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
    final documentChanged =
        oldWidget.document.id != widget.document.id ||
        oldWidget.document.updatedAt != widget.document.updatedAt ||
        oldWidget.document.source != widget.document.source;
    if (documentChanged) {
      if (_searchSheetOpen) unawaited(Navigator.of(context).maybePop());
      _discardSearchSession();
    }
    if (oldWidget.document.id != widget.document.id ||
        oldWidget.document.updatedAt != widget.document.updatedAt ||
        oldWidget.document.source != widget.document.source ||
        // §5.5 fact 3. A preference change satisfies none of the three
        // comparisons above - it deliberately does not bump `updatedAt` - so
        // without this the print surface would keep the previously resolved
        // chain while the Viewer showed the new one, which is exactly the
        // parity break §6 exists to prevent. The remount below carries the
        // newly resolved script, so the print stacks are rebuilt in the new
        // order rather than re-rendered in the old one.
        oldWidget.document.scriptPreference !=
            widget.document.scriptPreference) {
      _printSurfaceLease = mountPrintSurface(
        widget.document.source,
        script: _resolvedScript,
      );
    }
    _rebuildBlocksIfNeeded();
  }

  @override
  void dispose() {
    unmountPrintSurface(_printSurfaceLease);
    _positionsListener.itemPositions.removeListener(_onPositionsChanged);
    _saveDebounce?.cancel();
    _searchDebounce?.cancel();
    _searchController.dispose();
    _menuFocusNode.dispose();
    _searchFieldFocusNode.dispose();
    _searchResultFocusNode.dispose();
    _searchResultListFocusNode.dispose();
    _searchReopenFocusNode.dispose();
    _searchPreviousFocusNode.dispose();
    _searchNextFocusNode.dispose();
    _searchCloseFocusNode.dispose();
    _searchLocatorFocusNode.dispose();
    _searchRevision.dispose();
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

  /// Which Han pack leads for the document currently being read.
  ///
  /// A *derived* value, never a stored one: detection is a pure function of the
  /// effective document source and its own preference, evaluated when that
  /// source becomes - or changes as - the document being viewed. There is no
  /// background process and no per-keystroke listener (plan.md §5.6.5).
  HanScript get _resolvedScript => resolveHanScript(
    widget.document.source,
    preference: widget.document.scriptPreference,
  );

  /// What the **detector** currently returns for this document, ignoring any
  /// explicit preference.
  ///
  /// Deliberately not [_resolvedScript]: the `Auto` row's subordinate text and
  /// the menu's `Automatic — …` subtitle both have to name what detection says,
  /// which is how the user tells an inferred convention from a chosen one. Under
  /// an explicit override the two differ, and showing the override back to the
  /// user as the "detected" result would make the comparison meaningless
  /// (plan.md §5.6.2, §5.6.3).
  HanScript get _detectedScript => resolveHanScript(widget.document.source);

  /// Parsing and building the whole document is expensive, so it happens only
  /// when something that actually changes the output changes.
  void _rebuildBlocksIfNeeded() {
    final palette = ReaderPalette.of(context);
    final document = widget.document;
    final script = _resolvedScript;
    final key = [
      document.id,
      document.updatedAt.microsecondsSinceEpoch,
      palette.isDark,
      widget.settings.wrapCode,
      // §5.5 fact 2. Setting a preference deliberately does not change
      // `updatedAt`, so none of the four components above changes when the
      // language changes and this method would return early, silently keeping
      // the old chain. The *resolved* script is used rather than the raw
      // preference because it also covers the `auto` case, where an edit can
      // change what detection returns without the preference moving at all.
      script.name,
    ].join('|');

    if (key == _blocksKey) return;

    final config = buildMarkdownConfig(
      palette: palette,
      wrapCode: widget.settings.wrapCode,
      onLinkTap: _openLink,
      script: script,
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

  /// The Reader's current top visible block, as a [ReadingPosition], or
  /// `null` if the list has not reported any positions yet.
  ///
  /// Shared by [_onPositionsChanged] and the close anchor capture, so both
  /// agree on what "the current position" means.
  ReadingPosition? _topVisiblePosition() {
    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) return null;

    // The top-most block that is still at least partly on screen.
    ItemPosition? top;
    for (final position in positions) {
      if (position.itemTrailingEdge <= 0) continue;
      if (top == null || position.index < top.index) top = position;
    }
    if (top == null) return null;

    return ReadingPosition(
      documentId: widget.document.id,
      blockIndex: top.index,
      // itemLeadingEdge is <= 0 once scrolled into a block; stored positive as
      // "how far into this block we are", in viewport heights.
      fraction: -top.itemLeadingEdge,
      headingText: _headingBefore(top.index),
      savedAt: DateTime.now(),
    );
  }

  void _onPositionsChanged() {
    final position = _topVisiblePosition();
    if (position == null) return;
    _latest = position;

    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), _flushPosition);
  }

  void _flushPosition() {
    final position = _latest;
    if (position == null) return;
    _latest = null;
    // Always reported; stored only if the retention gate allows it.
    widget.onPositionChanged(position);
    unawaited(store.savePosition(position));
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

  // --- Search ---------------------------------------------------------------

  void _notifySearch(VoidCallback update) {
    if (!mounted) return;
    setState(update);
    _searchRevision.value++;
  }

  Future<void> _openOrFocusSearch() async {
    if (!_searchOpen) {
      _notifySearch(() => _searchOpen = true);
      unawaited(_ensureSearchIndex());
    }

    final pane =
        _usesSearchPane ??
        usesPersistentSearchPane(MediaQuery.sizeOf(context).width);
    if (pane) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _searchFieldFocusNode.requestFocus(),
      );
    } else if (_searchSheetOpen) {
      _searchFieldFocusNode.requestFocus();
    } else {
      unawaited(_showSearchSheet(opener: _menuFocusNode));
    }
  }

  Future<void> _ensureSearchIndex() async {
    if (_searchIndex != null || _searchPreparing) return;
    _notifySearch(() => _searchPreparing = true);

    // The preparing state must paint before synchronous parsing begins.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_searchOpen || _searchIndex != null) return;

    final index = DocumentSearchIndex.build(widget.document.source);
    final result = index.search(
      _searchController.text,
      renderedBlockCount: _blocks.length,
    );
    _notifySearch(() {
      _searchIndex = index;
      _searchResult = result;
      _searchPreparing = false;
    });
    widget.onSearchIndexBuilt?.call();
  }

  void _queryChanged(String value) {
    _searchDebounce?.cancel();
    if (value.trim().isEmpty) {
      _runSearch(value);
      return;
    }
    _searchDebounce = Timer(
      const Duration(milliseconds: 150),
      () => _runSearch(value),
    );
  }

  void _runSearch(String value) {
    final index = _searchIndex;
    if (index == null) {
      unawaited(_ensureSearchIndex());
      return;
    }
    final result = index.search(value, renderedBlockCount: _blocks.length);
    _notifySearch(() {
      _searchResult = result;
      _activeSearchMatchIndex = null;
    });
  }

  void _submitSearch(String value) {
    _searchDebounce?.cancel();
    if (_searchResult?.query != value.trim()) _runSearch(value);
    if (HardwareKeyboard.instance.isShiftPressed) {
      unawaited(_stepSearch(-1));
    } else {
      unawaited(_stepSearch(1));
    }
  }

  Future<void> _stepSearch(int delta) async {
    final result = _searchResult;
    if (result == null ||
        !result.isAvailable ||
        result.isOverflow ||
        result.matches.isEmpty) {
      return;
    }
    final current = _activeSearchMatchIndex;
    final next = current == null
        ? (delta < 0 ? result.matches.length - 1 : 0)
        : (current + delta) % result.matches.length;
    await _activateSearchMatch(next);
  }

  Future<void> _activateSearchMatch(
    int index, {
    BuildContext? dismissSheetContext,
  }) async {
    final result = _searchResult;
    if (result == null ||
        !result.isAvailable ||
        result.isOverflow ||
        index < 0 ||
        index >= result.matches.length) {
      return;
    }

    if (dismissSheetContext != null && _searchSheetOpen) {
      _searchSheetSelectionInProgress = true;
      await Navigator.of(dismissSheetContext).maybePop();
      if (!mounted) return;
      await _waitForSearchSheetDisposal();
      if (!mounted) return;
    }

    final match = result.matches[index];
    _notifySearch(() => _activeSearchMatchIndex = index);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_scrollController.isAttached) return;
    await _scrollController.scrollTo(
      index: match.blockIndex,
      alignment: 0.12,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _searchFieldFocusNode.unfocus();
    FocusScope.of(context).requestFocus(_searchLocatorFocusNode);
  }

  Future<void> _showSearchSheet({
    required FocusNode opener,
    _SearchFocusRole? initialFocusRole,
  }) async {
    if (!mounted || _searchSheetOpen || !_searchOpen) return;
    final routeKey = GlobalKey();
    final restoresTransitionRole =
        initialFocusRole == _SearchFocusRole.locator ||
        initialFocusRole == _SearchFocusRole.previous ||
        initialFocusRole == _SearchFocusRole.next;
    _notifySearch(() {
      _searchSheetOpen = true;
      _searchSheetRouteKey = routeKey;
      _searchSheetRestoreRole = restoresTransitionRole
          ? initialFocusRole
          : null;
    });
    final route = showModalBottomSheet<void>(
      context: context,
      backgroundColor: ReaderPalette.of(context).background,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => KeyedSubtree(
        key: routeKey,
        child: FractionallySizedBox(
          heightFactor: 0.92,
          widthFactor: MediaQuery.sizeOf(sheetContext).width < 600 ? 1 : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: AnimatedBuilder(
              animation: _searchRevision,
              builder: (context, _) => _buildSearchSurface(
                SearchSurfaceMode.sheet,
                onClose: () => Navigator.pop(sheetContext),
                onSelect: (index) => unawaited(
                  _activateSearchMatch(
                    index,
                    dismissSheetContext: sheetContext,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final focusRole = restoresTransitionRole
        ? (_activeSearchMatchIndex == null
              ? _SearchFocusRole.field
              : _SearchFocusRole.result)
        : initialFocusRole ??
              (identical(opener, _searchReopenFocusNode) &&
                      _activeSearchMatchIndex != null
                  ? _SearchFocusRole.result
                  : _SearchFocusRole.field);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _restoreMappedSearchFocus(focusRole),
      );
    });
    await route;
    if (!mounted) return;
    await _waitForSearchSheetDisposal();
    if (!mounted) return;
    final selected = _searchSheetSelectionInProgress;
    final restoreRole = _searchSheetRestoreRole;
    _searchSheetSelectionInProgress = false;
    _notifySearch(() {
      _searchSheetOpen = false;
      if (identical(_searchSheetRouteKey, routeKey)) {
        _searchSheetRouteKey = null;
      }
      _searchSheetRestoreRole = null;
    });
    if (!selected && _searchOpen && !(_usesSearchPane ?? false)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (restoreRole != null) {
          _restoreMappedSearchFocus(restoreRole);
        } else if (opener.canRequestFocus) {
          opener.requestFocus();
        }
      });
    }
  }

  Future<void> _waitForSearchSheetDisposal() async {
    final routeKey = _searchSheetRouteKey;
    while (mounted && routeKey?.currentContext != null) {
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  Widget _buildSearchSurface(
    SearchSurfaceMode mode, {
    required VoidCallback onClose,
    required ValueChanged<int> onSelect,
  }) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        textScaler: TextScaler.linear(widget.settings.fontScale),
      ),
      child: SearchSurface(
        mode: mode,
        palette: ReaderPalette.of(context),
        controller: _searchController,
        fieldFocusNode: _searchFieldFocusNode,
        resultFocusNode: _searchResultFocusNode,
        resultListFocusNode: _searchResultListFocusNode,
        previousFocusNode: _searchPreviousFocusNode,
        nextFocusNode: _searchNextFocusNode,
        closeFocusNode: _searchCloseFocusNode,
        isPreparing: _searchPreparing,
        result: _searchResult,
        activeMatchIndex: _activeSearchMatchIndex,
        onQueryChanged: _queryChanged,
        onSubmitted: _submitSearch,
        onSelect: onSelect,
        onPrevious: () => unawaited(_stepSearch(-1)),
        onNext: () => unawaited(_stepSearch(1)),
        onClose: onClose,
      ),
    );
  }

  void _closeSearchSession() {
    _searchDebounce?.cancel();
    // Capture where reading actually is right now, before the state change
    // below remounts the list (see `_closeAnchor`). Left untouched if the
    // list has not reported a position yet.
    final current = _topVisiblePosition();
    if (current != null) _closeAnchor = current;
    if (_searchSheetOpen) Navigator.of(context).maybePop();
    _notifySearch(() {
      _searchOpen = false;
      _searchPreparing = false;
      _searchSheetOpen = false;
      _searchSheetSelectionInProgress = false;
      _searchSheetRestoreRole = null;
      _searchController.clear();
      _searchResult = null;
      _activeSearchMatchIndex = null;
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _menuFocusNode.requestFocus(),
    );
  }

  void _discardSearchSession() {
    _searchDebounce?.cancel();
    _searchOpen = false;
    _searchPreparing = false;
    _searchSheetOpen = false;
    _searchSheetSelectionInProgress = false;
    _searchSheetRestoreRole = null;
    _searchController.clear();
    _searchIndex = null;
    _searchResult = null;
    _activeSearchMatchIndex = null;
    _searchRevision.value++;
  }

  void _observeSearchMode(bool usesPane) {
    final previous = _usesSearchPane;
    final focusRole = previous == null || previous == usesPane
        ? null
        : _currentSearchFocusRole();
    _usesSearchPane = usesPane;
    if (previous == null || previous == usesPane || !_searchOpen) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_searchOpen) return;
      if (usesPane) {
        unawaited(_moveSearchSheetToPane(focusRole ?? _SearchFocusRole.field));
      } else if (!_searchSheetOpen) {
        unawaited(
          _showSearchSheet(
            opener: _searchReopenFocusNode,
            initialFocusRole: focusRole,
          ),
        );
      }
    });
  }

  Future<void> _moveSearchSheetToPane(_SearchFocusRole focusRole) async {
    final restoreRole = _searchSheetRestoreRole ?? focusRole;
    if (_searchSheetOpen) await Navigator.of(context).maybePop();
    if (!mounted) return;
    await _waitForSearchSheetDisposal();
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _restoreMappedSearchFocus(restoreRole);
  }

  _SearchFocusRole _currentSearchFocusRole() {
    if (_searchFieldFocusNode.hasFocus) return _SearchFocusRole.field;
    if (_searchResultFocusNode.hasFocus ||
        _searchResultListFocusNode.hasFocus) {
      return _SearchFocusRole.result;
    }
    if (_searchPreviousFocusNode.hasFocus) return _SearchFocusRole.previous;
    if (_searchNextFocusNode.hasFocus) return _SearchFocusRole.next;
    if (_searchCloseFocusNode.hasFocus) return _SearchFocusRole.close;
    if (_searchLocatorFocusNode.hasFocus) return _SearchFocusRole.locator;
    if (_searchReopenFocusNode.hasFocus) return _SearchFocusRole.reopen;
    return _activeSearchMatchIndex == null
        ? _SearchFocusRole.field
        : _SearchFocusRole.result;
  }

  void _restoreMappedSearchFocus(_SearchFocusRole role) {
    var target = switch (role) {
      _SearchFocusRole.field => _searchFieldFocusNode,
      _SearchFocusRole.result =>
        _searchResultFocusNode.context == null
            ? _searchResultListFocusNode
            : _searchResultFocusNode,
      _SearchFocusRole.previous => _searchPreviousFocusNode,
      _SearchFocusRole.next => _searchNextFocusNode,
      _SearchFocusRole.close => _searchCloseFocusNode,
      _SearchFocusRole.locator => _searchLocatorFocusNode,
      _SearchFocusRole.reopen => _searchReopenFocusNode,
    };
    if (target.context == null || !target.canRequestFocus) {
      target = _searchFieldFocusNode;
    }
    if (target.context != null && target.canRequestFocus) target.requestFocus();
  }

  Widget _searchBlock(int index, ReaderPalette palette) {
    final result = _searchResult;
    final active = _activeSearchMatchIndex;
    if (!_searchOpen ||
        result == null ||
        !result.isAvailable ||
        result.isOverflow ||
        active == null ||
        result.matches[active].blockIndex != index) {
      return _blocks[index];
    }

    final match = result.matches[active];
    final heading = match.heading;
    final label = heading == null
        ? 'Search result ${active + 1} of ${result.total}'
        : 'Search result ${active + 1} of ${result.total}, $heading';
    return Focus(
      focusNode: _searchLocatorFocusNode,
      child: Semantics(
        key: const ValueKey('active-search-locator'),
        selected: true,
        focusable: true,
        label: label,
        child: Container(
          decoration: BoxDecoration(
            color: palette.link.withValues(alpha: 0.08),
            border: Border(left: BorderSide(color: palette.link, width: 4)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.location_searching, size: 16, color: palette.link),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      color: palette.link,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              _blocks[index],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openMenu() async {
    final palette = ReaderPalette.of(context);
    final action = await showModalBottomSheet<_MenuAction>(
      context: context,
      backgroundColor: palette.background,
      isScrollControlled: true,
      builder: (context) => _ReaderMenu(
        document: widget.document,
        palette: palette,
        hasToc: _toc.isNotEmpty,
        // Only when the document draws on the shipped Han repertoires at all.
        // Otherwise the menu looks exactly as it did before DF-031, and a stored
        // preference - if one somehow exists - is inert, because no character is
        // ever looked up in either pack (plan.md §5.6.4).
        hasHan: sourceUsesShippedHan(widget.document.source),
        languageSubtitle: scriptPreferenceSubtitle(
          widget.document.scriptPreference,
          _detectedScript,
        ),
      ),
    );
    if (!mounted || action == null) return;

    switch (action) {
      case _MenuAction.contents:
        final target = await showTocSheet(context, _toc);
        if (target != null) _jumpTo(target);
      case _MenuAction.search:
        await _openOrFocusSearch();
      case _MenuAction.appearance:
        await showSettingsSheet(
          context,
          settings: widget.settings,
          onChanged: widget.onSettingsChanged,
        );
      case _MenuAction.language:
        await showScriptRenderingSheet(
          context,
          preference: widget.document.scriptPreference,
          resolved: _detectedScript,
          onChanged: widget.onScriptPreferenceChanged,
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
    final anchor = _closeAnchor;
    // The one-shot close anchor takes priority over the mount-time restore,
    // so a list that is about to be remounted by this build starts from the
    // current position rather than from where the page was first mounted.
    final startPosition = anchor ?? _restore;
    final initialIndex = startPosition == null
        ? 0
        : startPosition.blockIndex
              .clamp(0, math.max(0, _blocks.length - 1))
              .toInt();
    if (anchor != null) {
      // Consumed once: cleared after this frame so a later remount (a
      // responsive crossing, for example) still starts from `_restore`.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _closeAnchor = null;
      });
    }

    final bindings = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
          unawaited(_openOrFocusSearch()),
      const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () =>
          unawaited(_openOrFocusSearch()),
      if (_searchOpen && (_usesSearchPane ?? false))
        const SingleActivator(LogicalKeyboardKey.escape): _closeSearchSession,
    };

    return CallbackShortcuts(
      bindings: bindings,
      child: Scaffold(
        backgroundColor: palette.background,
        body: LayoutBuilder(
          builder: (context, constraints) {
            final usesPane = usesPersistentSearchPane(constraints.maxWidth);
            _observeSearchMode(usesPane);
            final readerWidth = _searchOpen && usesPane
                ? constraints.maxWidth -
                      kSearchPaneWidth -
                      kSearchPaneDividerWidth
                : constraints.maxWidth;
            final reader = _buildReaderRegion(
              palette: palette,
              media: media,
              readerWidth: readerWidth,
              initialIndex: initialIndex,
              initialAlignment: startPosition == null
                  ? 0
                  : -startPosition.fraction,
              usesPane: usesPane,
            );

            if (!_searchOpen || !usesPane) return reader;
            return Row(
              children: [
                SizedBox(
                  width: kSearchPaneWidth,
                  child: _buildSearchSurface(
                    SearchSurfaceMode.pane,
                    onClose: _closeSearchSession,
                    onSelect: (index) => unawaited(_activateSearchMatch(index)),
                  ),
                ),
                VerticalDivider(
                  width: kSearchPaneDividerWidth,
                  color: palette.rule,
                ),
                Expanded(child: reader),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildReaderRegion({
    required ReaderPalette palette,
    required MediaQueryData media,
    required double readerWidth,
    required int initialIndex,
    required double initialAlignment,
    required bool usesPane,
  }) {
    final horizontal = readerHorizontalPadding(readerWidth);
    return ExcludeFocus(
      excluding: _searchSheetOpen,
      child: MediaQuery(
        key: const ValueKey('reader-region'),
        // Search panes reduce the Reader region itself; Markdown and padding
        // see that region rather than the full window. While a modal search
        // route exists, the underlying Reader and compact navigator are not
        // physically focusable. The user font scale remains applied exactly as
        // before.
        data: media.copyWith(
          size: Size(readerWidth, media.size.height),
          textScaler: TextScaler.linear(widget.settings.fontScale),
        ),
        child: Stack(
          children: [
            NotificationListener<UserScrollNotification>(
              onNotification: _onUserScroll,
              child: SelectionArea(
                child: ScrollablePositionedList.builder(
                  itemCount: _blocks.length,
                  itemBuilder: (context, index) => _searchBlock(index, palette),
                  itemScrollController: _scrollController,
                  itemPositionsListener: _positionsListener,
                  initialScrollIndex: initialIndex,
                  initialAlignment: initialAlignment,
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
              focusNode: _menuFocusNode,
              onTap: _openMenu,
            ),
            if (_searchOpen && !usesPane && !_searchSheetOpen)
              Positioned(
                right: 16,
                bottom: media.padding.bottom + 82,
                child: CompactSearchNavigator(
                  palette: palette,
                  result: _searchResult,
                  activeMatchIndex: _activeSearchMatchIndex,
                  reopenFocusNode: _searchReopenFocusNode,
                  previousFocusNode: _searchPreviousFocusNode,
                  nextFocusNode: _searchNextFocusNode,
                  onShowResults: () => unawaited(
                    _showSearchSheet(opener: _searchReopenFocusNode),
                  ),
                  onPrevious: () => unawaited(_stepSearch(-1)),
                  onNext: () => unawaited(_stepSearch(1)),
                  onClose: _closeSearchSession,
                ),
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

enum _MenuAction {
  contents,
  search,
  appearance,
  edit,
  loadFile,
  language,
  home,
}

class _ReaderMenu extends StatelessWidget {
  const _ReaderMenu({
    required this.document,
    required this.palette,
    required this.hasToc,
    required this.hasHan,
    required this.languageSubtitle,
  });

  final MarkdownDocument document;
  final ReaderPalette palette;
  final bool hasToc;

  /// Whether the document uses the shipped Han repertoires at all. Follows the
  /// established local precedent of [hasToc], which is already conditional.
  final bool hasHan;

  /// The effective state, shown under the tile.
  final String languageSubtitle;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      // Scrollable because a modal sheet is capped at a fraction of the
      // viewport height: on a short viewport (a phone in landscape) the header
      // plus up to six tiles is taller than the sheet is allowed to be, and a
      // plain Column overflows instead of scrolling. DF-031's `Language` tile is
      // the sixth, and is exactly the case this wrapper was written for.
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
              icon: Icons.search_rounded,
              label: 'Search document',
              palette: palette,
              onTap: () => Navigator.pop(context, _MenuAction.search),
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
            // Between `Load from file` and `Return to main`, and that placement
            // is a product constraint rather than a cosmetic choice (plan.md
            // §5.6.2, §1.7 UX-3): every existing tile keeps its current index,
            // the high-frequency `Load from file` is not pushed down, and
            // `Return to main` stays last, which is the property that matters to
            // a terminal navigation action. Reordering this regresses UX-3.
            if (hasHan)
              _MenuTile(
                // `Language`, not `Script rendering`: the latter reads as
                // implementation vocabulary. The internal model deliberately
                // keeps the generic name, and plan.md §5.6.2 records the
                // divergence as a decision rather than an inconsistency.
                icon: Icons.translate_rounded,
                label: 'Language',
                subtitle: languageSubtitle,
                palette: palette,
                onTap: () => Navigator.pop(context, _MenuAction.language),
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
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final ReaderPalette palette;
  final VoidCallback onTap;

  /// Optional second line. `ListTile` already supports one; only the tile that
  /// has to show an effective state passes it.
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minTileHeight: 48,
      visualDensity: VisualDensity.compact,
      leading: Icon(icon, color: palette.muted),
      title: Text(label, style: TextStyle(fontSize: 16, color: palette.text)),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: TextStyle(fontSize: 12.5, color: palette.muted),
            ),
      onTap: onTap,
    );
  }
}

class _MenuButton extends StatelessWidget {
  const _MenuButton({
    required this.visible,
    required this.palette,
    required this.onTap,
    required this.focusNode,
  });

  final bool visible;
  final ReaderPalette palette;
  final VoidCallback onTap;
  final FocusNode focusNode;

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
              focusNode: focusNode,
              autofocus: true,
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
