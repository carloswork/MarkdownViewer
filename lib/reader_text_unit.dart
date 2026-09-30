import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:markdown_widget/markdown_widget.dart';

import 'blocks.dart';
import 'markdown_theme.dart';

/// DF-052 CP1 — shared, render-sourced Reader/Search text-unit model.
///
/// This file introduces the shared unit model that succeeds DF-041 D-004's
/// independently reparsed Search-text projection. The text a unit carries is the
/// *rendered* text of a single leaf text owner (one contiguous
/// `RenderParagraph`/rich-text run), captured from the exact span object the
/// renderer draws during the single `MarkdownGenerator.buildWidgets` pass. No
/// second truth-producing parse exists.
///
/// CP1 scope is capture + identity + index feed only. Occurrence painting,
/// all/active visuals and range scrolling are CP2/CP3 and are deliberately not
/// implemented here (plan.md §15). The tag span introduced below
/// ([OccurrenceTaggedSpan]) is a transparent wrapper that carries owner identity
/// through to mount time without altering layout, selection or semantics; the
/// CP1 make-or-break fidelity gate proves that transparency
/// (`test/search_occurrence_fidelity_test.dart`).

/// The kind of leaf text owner a [ReaderTextUnit] was captured from.
enum UnitKind { prose, heading, blockquote, listItem, tableCell, code, image }

/// A structural occurrence-owner identity (plan.md §4.1).
///
/// The id is a structural path: the top-level block ordinal followed by a
/// descent of child ordinals through the owning `ElementNode.children`. It never
/// depends on text content, callback timing or widget-child order, so equal
/// visible occurrences (e.g. duplicate table cells) still receive distinct ids,
/// and the same document revision always yields the same ids.
@immutable
class OccurrenceOwnerId {
  const OccurrenceOwnerId(this.path);

  /// `[blockOrdinal, childOrdinal, …]`. The first element is the top-level
  /// block index used for coarse scroll (plan.md §9); the tail is the descent.
  final List<int> path;

  int get blockIndex => path.first;

  /// Document-order comparison over the structural path.
  int compareTo(OccurrenceOwnerId other) {
    final a = path;
    final b = other.path;
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      final c = a[i].compareTo(b[i]);
      if (c != 0) return c;
    }
    return a.length.compareTo(b.length);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! OccurrenceOwnerId) return false;
    if (path.length != other.path.length) return false;
    for (var i = 0; i < path.length; i++) {
      if (path[i] != other.path[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(path);

  @override
  String toString() => path.join('/');
}

/// A memory-only document revision identity (plan.md §4.2).
///
/// Derived from the inputs that already drive session discard: `document.id`,
/// `document.updatedAt`, and `source`. Theme/wrap/script changes must not change
/// it. A match set is invalidated when this value changes.
@immutable
class DocumentRevision {
  const DocumentRevision({
    required this.documentId,
    required this.updatedAtMicroseconds,
    required this.source,
  });

  factory DocumentRevision.fromDocument({
    required String id,
    required DateTime updatedAt,
    required String source,
  }) => DocumentRevision(
    documentId: id,
    updatedAtMicroseconds: updatedAt.microsecondsSinceEpoch,
    source: source,
  );

  final String documentId;
  final int updatedAtMicroseconds;
  final String source;

  @override
  bool operator ==(Object other) =>
      other is DocumentRevision &&
      other.documentId == documentId &&
      other.updatedAtMicroseconds == updatedAtMicroseconds &&
      other.source == source;

  @override
  int get hashCode => Object.hash(documentId, updatedAtMicroseconds, source);
}

/// One leaf text owner: exactly the rendered text of one `RenderParagraph`.
@immutable
class ReaderTextUnit {
  const ReaderTextUnit({
    required this.id,
    required this.text,
    required this.blockIndex,
    required this.heading,
    required this.kind,
  });

  /// Structural occurrence owner id (plan.md §4).
  final OccurrenceOwnerId id;

  /// Exact rendered text of this owner — Search truth (plan.md §3.1).
  final String text;

  /// Top-level ordinal for coarse scroll (plan.md §9).
  final int blockIndex;

  /// Nearest heading context for result rows/labels.
  final String? heading;

  final UnitKind kind;
}

/// The result of one capture pass.
@immutable
class ReaderTextUnitCaptureResult {
  const ReaderTextUnitCaptureResult({
    required this.units,
    required this.isComplete,
  });

  /// Units in document order.
  final List<ReaderTextUnit> units;

  /// False if any expected owner produced no captured unit (fail-closed,
  /// plan.md §5.2 step 4). A future pinned-renderer shape change that breaks the
  /// list-item adapter surfaces here rather than as a silent wrong result.
  final bool isComplete;
}

/// A transparent [TextSpan] wrapper carrying an [OccurrenceOwnerId].
///
/// It has no text and no style of its own and wraps exactly one child span, so
/// it contributes nothing to `toPlainText`, layout, selection or semantics; it
/// only threads owner identity to mount time (delivery/painting are CP2). The
/// CP1 fidelity gate proves this transparency against the default render.
class OccurrenceTaggedSpan extends TextSpan {
  OccurrenceTaggedSpan(InlineSpan child, this.ownerId)
    : super(children: <InlineSpan>[child]);

  final OccurrenceOwnerId ownerId;
}

// ---------------------------------------------------------------------------
// DF-052 CP2 — occurrence indication, delivery, and the active-locator lifecycle.
//
// The capture side above is CP1 and unchanged. The section below adds: the
// per-query occurrence model, the painter that adds all/active overlays without
// touching text/recognizers/semantics, the lazy delivery widget, and — per the
// corrected Cycle 2 architecture (plan.md §§C, D-1, D-3..D-6) — a
// duplicate-tolerant render-candidate registry with a single centrally promoted
// public locator. There is deliberately NO `GlobalKey` and NO singleton
// `FocusNode` mounted inside the two-list `ScrollablePositionedList` items; the
// failed CP2 Cycle 1 mechanism (a single mutable `GlobalKey` + a singleton
// `Focus`) crashed on SPL's transitioning two-list render and is not restored.
// ---------------------------------------------------------------------------

/// A half-open UTF-16 range `[start, end)` into an owner's rendered `text`.
///
/// The range is the CP1 structural identity (owner id + UTF-16 offsets), never
/// derived from layout geometry (plan.md §4, §9). It indexes the exact same
/// flattened text a unit was captured from, so it maps onto the drawing span.
@immutable
class OccurrenceRange {
  const OccurrenceRange(this.start, this.end);

  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      other is OccurrenceRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// The match state for one owner: every matched range, and the active one if the
/// active occurrence belongs to this owner.
@immutable
class OwnerMatchState {
  const OwnerMatchState(this.all, this.active);

  /// All matched ranges in this owner, in document order.
  final List<OccurrenceRange> all;

  /// The active range when the active occurrence is in this owner, else null.
  final OccurrenceRange? active;
}

/// The per-query occurrence model published to materialized owners.
///
/// Rebuilt once per query/active/revision change and grouped by owner so paint
/// time is an O(1) lookup (plan.md §5.6, §7). A plain object compared by
/// identity: the reader recomputes it only when search state actually changes,
/// so unrelated rebuilds reuse the same instance and dependents do not repaint.
@immutable
class ReaderSearchModel {
  const ReaderSearchModel({
    required this.byOwner,
    required this.activeOwner,
    required this.activeRange,
    required this.activeLabel,
  });

  static const ReaderSearchModel empty = ReaderSearchModel(
    byOwner: <OccurrenceOwnerId, List<OccurrenceRange>>{},
    activeOwner: null,
    activeRange: null,
    activeLabel: null,
  );

  final Map<OccurrenceOwnerId, List<OccurrenceRange>> byOwner;
  final OccurrenceOwnerId? activeOwner;
  final OccurrenceRange? activeRange;

  /// The active occurrence's locator label — `Search result n of total[, heading]`
  /// (plan.md §6.2), carried on the model so the promoted candidate reproduces the
  /// exact DF-041 wording. Null when there is no active occurrence.
  final String? activeLabel;

  bool get isEmpty => byOwner.isEmpty;

  /// The match state for [id], or null when this owner has no current match.
  OwnerMatchState? matchStateFor(OccurrenceOwnerId id) {
    final all = byOwner[id];
    if (all == null || all.isEmpty) return null;
    return OwnerMatchState(all, activeOwner == id ? activeRange : null);
  }
}

/// One duplicate-tolerant render candidate for the active owner (plan.md §C.2).
///
/// A candidate exposes render-object resolution and its own focus node, but only
/// exposes the public locator (`Focus` + `Semantics(selected/focusable/label)` +
/// `ValueKey('active-search-locator')`) when the registry has centrally promoted
/// it. Unpromoted copies keep their ordinary spoken text — they never wrap the
/// child in `ExcludeSemantics`.
abstract class ActiveOwnerCandidate {
  OccurrenceOwnerId get ownerId;

  /// The candidate's own `BuildContext` — used to reach the outer vertical
  /// `Scrollable` for the pixel reveal (plan.md §D-2).
  BuildContext get candidateContext;

  /// The per-copy focus node the promoted candidate exposes (plan.md §D-1).
  FocusNode get focusNode;

  /// Whether this candidate is still mounted.
  bool get isCandidateMounted;

  /// Descends past any wrapping `RenderMouseRegion`/annotation to the leaf
  /// `RenderParagraph` this owner draws (plan.md §D-1; fixes the B-2 type guard).
  RenderParagraph? resolveParagraph();
}

/// App-owned, revision-scoped registry separating the 0–2 duplicate render
/// candidates from the one centrally promoted public locator (plan.md §D-1).
///
/// Its lifetime is bound to the Reader's existing immutable [DocumentRevision]
/// value: a fresh registry is installed exactly when the revision changes, and it
/// survives every query/active transition within a revision. Only [promote]/
/// [clearPromotion] notify listeners; register/deregister mutate silently during
/// widget lifecycle so no `setState`-during-dispose can occur.
class ActiveLocatorRegistry extends ChangeNotifier {
  ActiveLocatorRegistry(this.revision);

  final DocumentRevision revision;

  final Map<OccurrenceOwnerId, Set<ActiveOwnerCandidate>> _candidates =
      <OccurrenceOwnerId, Set<ActiveOwnerCandidate>>{};

  ({OccurrenceOwnerId owner, ActiveOwnerCandidate copy, int gen})? _promoted;

  void register(ActiveOwnerCandidate candidate) {
    (_candidates[candidate.ownerId] ??= <ActiveOwnerCandidate>{}).add(candidate);
  }

  /// Removes [candidate]. A deregister carrying a value-unequal revision is
  /// ignored, so an out-of-order dispose from a superseded revision cannot remove
  /// a current entry (plan.md §D-1). Silent: never notifies (dispose-safe).
  void deregister(
    ActiveOwnerCandidate candidate, {
    required OccurrenceOwnerId ownerId,
    required DocumentRevision revision,
  }) {
    if (revision != this.revision) return;
    final set = _candidates[ownerId];
    if (set != null) {
      set.remove(candidate);
      if (set.isEmpty) _candidates.remove(ownerId);
    }
    if (identical(_promoted?.copy, candidate)) _promoted = null;
  }

  Iterable<ActiveOwnerCandidate> candidatesFor(OccurrenceOwnerId id) =>
      _candidates[id] ?? const <ActiveOwnerCandidate>[];

  /// Promote exactly one settled copy. The only writer of `_promoted`, called
  /// centrally by the reveal controller (plan.md §D-1/§D-4), never by widgets.
  void promote(ActiveOwnerCandidate candidate, int gen) {
    _promoted = (owner: candidate.ownerId, copy: candidate, gen: gen);
    notifyListeners();
  }

  /// Release the prior public locator (plan.md §D-4 step 2). The transient
  /// zero-locator interval during transport.
  void clearPromotion() {
    if (_promoted == null) return;
    _promoted = null;
    notifyListeners();
  }

  bool isPromoted(ActiveOwnerCandidate candidate) =>
      identical(_promoted?.copy, candidate);

  /// The promoted copy's own focus node, or null during the transient (§D-6).
  FocusNode? get promotedFocusNode => _promoted?.copy.focusNode;

  bool get promotedNodeHasFocus =>
      _promoted?.copy.focusNode.hasFocus ?? false;

  /// The promoted copy itself, for the reveal controller's range measurement.
  ActiveOwnerCandidate? get promotedCandidate => _promoted?.copy;
}

/// Publishes the current [ReaderSearchModel] and the revision-scoped
/// [ActiveLocatorRegistry] to the materialized owners below the list.
///
/// Placed above the `ScrollablePositionedList`, so only the on-screen owners
/// depend on it and repaint per query; off-screen owners repaint on
/// materialization using their retained id (plan.md §5.6).
class ReaderSearchScope extends InheritedWidget {
  const ReaderSearchScope({
    super.key,
    required this.model,
    required this.registry,
    required this.revision,
    required super.child,
  });

  final ReaderSearchModel model;
  final ActiveLocatorRegistry registry;
  final DocumentRevision revision;

  static ReaderSearchScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ReaderSearchScope>();

  @override
  bool updateShouldNotify(ReaderSearchScope oldWidget) =>
      !identical(model, oldWidget.model) ||
      !identical(registry, oldWidget.registry) ||
      revision != oldWidget.revision;
}

/// Visual overlay style for occurrence indication (plan.md §6.1).
///
/// All matches get a background tint; the active match adds a **non-colour-only**
/// treatment (stronger tint plus bold weight and underline), satisfying the
/// inherited DF-041 D-005 constraint. Overlays are style-only: text, recognizers
/// and semantics ranges are untouched.
@immutable
class OccurrenceIndicationStyle {
  const OccurrenceIndicationStyle({
    required this.allBackground,
    required this.activeBackground,
    required this.activeUnderline,
  });

  factory OccurrenceIndicationStyle.of(ReaderPalette palette) =>
      OccurrenceIndicationStyle(
        allBackground: palette.link.withValues(alpha: 0.18),
        activeBackground: palette.link.withValues(alpha: 0.40),
        activeUnderline: palette.link,
      );

  final Color allBackground;
  final Color activeBackground;
  final Color activeUnderline;

  TextStyle get allDelta => TextStyle(backgroundColor: allBackground);

  TextStyle get activeDelta => TextStyle(
    backgroundColor: activeBackground,
    fontWeight: FontWeight.w700,
    decoration: TextDecoration.underline,
    decorationColor: activeUnderline,
    decorationThickness: 2,
  );
}

/// Returns a copy of [source] with the [state] occurrence overlays applied and
/// nothing else changed (plan.md §6.1).
///
/// The tree is walked in `toPlainText(includePlaceholders:false)` order: a
/// [TextSpan] contributes its own `text` (if any) before its children;
/// [WidgetSpan]s contribute no offset and are returned untouched. A span whose
/// own text overlaps a matched range is rebuilt with that text moved into child
/// pieces split at the exact UTF-16 boundaries, each piece re-attaching the
/// original `recognizer`, gesture callbacks, locale and spellOut so selection,
/// copy and link hit ranges are preserved; the highlight is added purely as a
/// style delta (background, and for the active piece bold + underline). Spans
/// with no overlapping match are returned verbatim.
InlineSpan paintOccurrences(
  InlineSpan source,
  OwnerMatchState state,
  OccurrenceIndicationStyle style,
) {
  final all = state.all;
  final active = state.active;
  var cursor = 0;

  bool inAll(int pos) {
    for (final r in all) {
      if (pos >= r.start && pos < r.end) return true;
    }
    return false;
  }

  /// Splits [text] at [base] into styled pieces, or null when it holds no match.
  List<InlineSpan>? splitOwnText(TextSpan span, String text, int base) {
    final len = text.length;
    final end = base + len;
    bool overlaps(OccurrenceRange r) => r.end > base && r.start < end;
    final relevant = all.where(overlaps).toList();
    final activeRel = active != null && overlaps(active) ? active : null;
    if (relevant.isEmpty && activeRel == null) return null;

    final cuts = <int>{0, len};
    void addCut(OccurrenceRange r) {
      cuts.add((r.start - base).clamp(0, len));
      cuts.add((r.end - base).clamp(0, len));
    }

    for (final r in relevant) {
      addCut(r);
    }
    if (activeRel != null) addCut(activeRel);
    final points = cuts.toList()..sort();

    // A semanticsLabel replaces the span's own text for accessibility, so when
    // we split the span we must keep the spoken content identical: put the full
    // label on the first emitted piece and an empty label ('') on the rest.
    // Adjacent pieces concatenate to the original label (the empty labels
    // contribute nothing), the reading order is preserved, and the visible text
    // is unchanged. When the span is not split there is a single piece and it
    // carries the full label unchanged.
    final label = span.semanticsLabel;
    var labelAssigned = false;

    final pieces = <InlineSpan>[];
    for (var i = 0; i + 1 < points.length; i++) {
      final s = points[i];
      final e = points[i + 1];
      if (s == e) continue;
      final absPos = base + s;
      final isActive =
          activeRel != null && absPos >= activeRel.start && absPos < activeRel.end;
      final isAll = isActive || inAll(absPos);
      final delta = isActive
          ? style.activeDelta
          : isAll
          ? style.allDelta
          : null;
      String? pieceLabel;
      if (label != null) {
        pieceLabel = labelAssigned ? '' : label;
        labelAssigned = true;
      }
      pieces.add(
        TextSpan(
          text: text.substring(s, e),
          style: delta,
          recognizer: span.recognizer,
          mouseCursor: span.mouseCursor,
          onEnter: span.onEnter,
          onExit: span.onExit,
          semanticsLabel: pieceLabel,
          locale: span.locale,
          spellOut: span.spellOut,
        ),
      );
    }
    return pieces;
  }

  InlineSpan visit(InlineSpan span) {
    if (span is TextSpan) {
      final text = span.text;
      List<InlineSpan>? ownPieces;
      if (text != null && text.isNotEmpty) {
        ownPieces = splitOwnText(span, text, cursor);
        cursor += text.length;
      }
      final children = span.children;
      List<InlineSpan>? newChildren;
      var childrenChanged = false;
      if (children != null) {
        newChildren = <InlineSpan>[];
        for (final child in children) {
          final visited = visit(child);
          if (!identical(visited, child)) childrenChanged = true;
          newChildren.add(visited);
        }
      }
      if (ownPieces == null && !childrenChanged) return span;
      if (ownPieces == null) {
        // Only nested children changed; keep this span's own text/props.
        return TextSpan(
          text: text,
          children: newChildren,
          style: span.style,
          recognizer: span.recognizer,
          mouseCursor: span.mouseCursor,
          onEnter: span.onEnter,
          onExit: span.onExit,
          semanticsLabel: span.semanticsLabel,
          locale: span.locale,
          spellOut: span.spellOut,
        );
      }
      // Own text was split into pieces: move them into children (text before
      // children, matching draw order) and drop the own-text-only properties,
      // which now live on the pieces. The style stays so pieces inherit it.
      return TextSpan(
        children: <InlineSpan>[...ownPieces, ...?newChildren],
        style: span.style,
        locale: span.locale,
        spellOut: span.spellOut,
      );
    }
    // WidgetSpan and other spans contribute no plain-text offset; keep as-is.
    return span;
  }

  return visit(source);
}

/// The `ValueKey` the single promoted candidate exposes on its locator
/// `Semantics` — the exact key DF-041 used on the block box (plan.md §6.2).
const ValueKey<String> kActiveSearchLocatorKey = ValueKey<String>(
  'active-search-locator',
);

/// Wraps the active owner's painted content so it can act as one duplicate-safe
/// render candidate, exposing the public locator only when centrally promoted
/// (plan.md §D-1, §D-5). Used by [OccurrenceText] and the app-owned `CodeBlock`/
/// `RemoteImagePlaceholder` painters. Non-active owners never wrap this, so the
/// registry only ever holds the 0–2 copies of the single active owner.
class ActiveOccurrenceLocator extends StatefulWidget {
  const ActiveOccurrenceLocator({
    super.key,
    required this.ownerId,
    required this.registry,
    required this.revision,
    required this.label,
    required this.child,
  });

  final OccurrenceOwnerId ownerId;
  final ActiveLocatorRegistry registry;
  final DocumentRevision revision;
  final String label;
  final Widget child;

  @override
  State<ActiveOccurrenceLocator> createState() =>
      _ActiveOccurrenceLocatorState();
}

class _ActiveOccurrenceLocatorState extends State<ActiveOccurrenceLocator>
    implements ActiveOwnerCandidate {
  final FocusNode _node = FocusNode(debugLabel: 'Active search result');

  @override
  OccurrenceOwnerId get ownerId => widget.ownerId;

  @override
  BuildContext get candidateContext => context;

  @override
  FocusNode get focusNode => _node;

  @override
  bool get isCandidateMounted => mounted;

  @override
  void initState() {
    super.initState();
    widget.registry.register(this);
    widget.registry.addListener(_onRegistryChanged);
  }

  @override
  void didUpdateWidget(covariant ActiveOccurrenceLocator oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A mounted candidate can be handed a new owner (rare) or, on a document
    // revision change, a new registry instance. Move the registration so no
    // stale entry survives (plan.md §D-1).
    if (oldWidget.ownerId != widget.ownerId ||
        !identical(oldWidget.registry, widget.registry)) {
      oldWidget.registry.removeListener(_onRegistryChanged);
      oldWidget.registry.deregister(
        this,
        ownerId: oldWidget.ownerId,
        revision: oldWidget.revision,
      );
      widget.registry.register(this);
      widget.registry.addListener(_onRegistryChanged);
    }
  }

  @override
  void dispose() {
    widget.registry.removeListener(_onRegistryChanged);
    widget.registry.deregister(
      this,
      ownerId: widget.ownerId,
      revision: widget.revision,
    );
    _node.dispose();
    super.dispose();
  }

  void _onRegistryChanged() {
    if (mounted) setState(() {});
  }

  @override
  RenderParagraph? resolveParagraph() {
    if (!mounted) return null;
    final ro = context.findRenderObject();
    if (ro == null) return null;
    return _firstRenderParagraph(ro);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.registry.isPromoted(this)) {
      // Additive locator annotation: `excludeSemantics` defaults to false, so the
      // paragraph's own text semantics stay as descendants and remain spoken
      // (plan.md §C.3, §D-5). Only the one promoted copy renders this.
      return Focus(
        focusNode: _node,
        child: Semantics(
          key: kActiveSearchLocatorKey,
          selected: true,
          focusable: true,
          label: widget.label,
          child: widget.child,
        ),
      );
    }
    // Unpromoted (including the two-list transient and any demoted copy): the
    // bare child with its ordinary spoken text fully intact — no `Focus`, no
    // locator `Semantics`, no key, and never `ExcludeSemantics`.
    return widget.child;
  }
}

/// Descends [node] to the first `RenderParagraph`, skipping the wrapping
/// `RenderMouseRegion`/annotation layers `SelectionArea` and hover spans add
/// (plan.md §D-1; fixes the B-2 type-guard that returned a `RenderMouseRegion`).
RenderParagraph? _firstRenderParagraph(RenderObject node) {
  if (node is RenderParagraph) return node;
  RenderParagraph? found;
  node.visitChildren((child) {
    found ??= _firstRenderParagraph(child);
  });
  return found;
}

/// Delivers per-owner occurrence indication at mount time (plan.md §5.6).
///
/// Returned by the reader's `richTextBuilder`, so it runs for every drawing
/// `ProxyRichText`/top-level span — prose, headings, blockquotes, cells and the
/// inner list-item content span. It recovers the owner id from the
/// [OccurrenceTaggedSpan], looks up the owner's match state, and paints; an
/// untagged span or an owner with no current match renders exactly as the
/// default `Text.rich`, preserving the CP1 transparency.
///
/// The tagged span is **not always the span handed to the builder**. The pinned
/// `MarkdownGenerator.buildWidgets` wraps each top-level block's built span in an
/// enclosing `TextSpan`, then calls `richTextBuilder` on that wrapper. So for
/// prose paragraphs and no-divider headings the [OccurrenceTaggedSpan] arrives
/// nested one level down; divider headings, blockquotes, table cells and list
/// items instead deliver the tagged span directly through their own
/// `ProxyRichText`. This builder therefore resolves the tag *wherever it sits* in
/// the received inline tree so every owner class paints, without changing CP1
/// text/ID truth. Owners never nest, so a resolved owner is not descended again.
///
/// When the resolved owner is the active occurrence, the painted `Text.rich` is
/// wrapped in an [ActiveOccurrenceLocator] render candidate (plan.md §D-1) — not
/// a `GlobalKey`. Non-active owners wrap nothing.
class OccurrenceText extends StatelessWidget {
  const OccurrenceText(this.span, {super.key});

  final InlineSpan span;

  @override
  Widget build(BuildContext context) {
    final scope = ReaderSearchScope.maybeOf(context);
    final model = scope?.model ?? ReaderSearchModel.empty;
    final style = OccurrenceIndicationStyle.of(ReaderPalette.of(context));
    var activeFound = false;

    InlineSpan resolve(InlineSpan node) {
      if (node is OccurrenceTaggedSpan) {
        final content = node.children!.first;
        final state = model.matchStateFor(node.ownerId);
        if (state == null) return content; // Transparent unwrap (CP1 fidelity).
        if (state.active != null) activeFound = true;
        return paintOccurrences(content, state, style);
      }
      if (node is TextSpan) {
        final children = node.children;
        if (children == null) return node;
        var changed = false;
        final resolved = <InlineSpan>[];
        for (final child in children) {
          final r = resolve(child);
          if (!identical(r, child)) changed = true;
          resolved.add(r);
        }
        if (!changed) return node;
        // Rebuild the enclosing wrapper preserving its own text/props; only the
        // resolved child spans differ. The wrapper carries no own text, so the
        // painted content keeps the same UTF-16 offsets the match ranges use.
        return TextSpan(
          text: node.text,
          children: resolved,
          style: node.style,
          recognizer: node.recognizer,
          mouseCursor: node.mouseCursor,
          onEnter: node.onEnter,
          onExit: node.onExit,
          semanticsLabel: node.semanticsLabel,
          locale: node.locale,
          spellOut: node.spellOut,
        );
      }
      // WidgetSpan and other spans carry no matchable owner text of their own
      // (code/image owners paint inside their own widgets); keep them as-is.
      return node;
    }

    final resolved = resolve(span);
    final child = Text.rich(resolved);
    final activeOwner = model.activeOwner;
    if (activeFound && scope != null && activeOwner != null) {
      return ActiveOccurrenceLocator(
        ownerId: activeOwner,
        registry: scope.registry,
        revision: scope.revision,
        label: model.activeLabel ?? '',
        child: child,
      );
    }
    return child;
  }
}

class _OwnerMeta {
  const _OwnerMeta(this.blockIndex, this.kind);
  final int blockIndex;
  final UnitKind kind;
}

/// Coordinates one render-sourced capture pass.
///
/// Usage (plan.md §5.1):
/// ```dart
/// final capture = ReaderTextUnitCapture();
/// final widgets = MarkdownGenerator(
///   generators: capture.generators,
///   onNodeAccepted: capture.onNodeAccepted,
/// ).buildWidgets(source, config: config, onTocList: …);
/// final result = capture.finish();
/// ```
///
/// `onNodeAccepted` assigns each node its structural path from the already
/// attached parent chain (acceptance fires before descendants, plan.md §5.2
/// step 1). Each owner node then captures its unit text from the exact drawn
/// span while `buildWidgets` builds the tree (step 2), so all units are present
/// synchronously by the time `buildWidgets` returns.
class ReaderTextUnitCapture {
  final Map<SpanNode, List<int>> _paths = Map<SpanNode, List<int>>.identity();
  final Map<OccurrenceOwnerId, _OwnerMeta> _expected =
      <OccurrenceOwnerId, _OwnerMeta>{};
  final Map<OccurrenceOwnerId, String> _recorded =
      <OccurrenceOwnerId, String>{};

  /// The custom node generators to hand to `MarkdownGenerator.generators`.
  List<SpanNodeGeneratorWithTag> get generators => <SpanNodeGeneratorWithTag>[
    SpanNodeGeneratorWithTag(
      tag: MarkdownTag.p.name,
      generator: (e, config, visitor) => _OccParagraphNode(config.p, this),
    ),
    for (final tag in const ['h1', 'h2', 'h3', 'h4', 'h5', 'h6'])
      SpanNodeGeneratorWithTag(
        tag: tag,
        generator: (e, config, visitor) =>
            _OccHeadingNode(_headingConfigFor(config, tag), visitor, this),
      ),
    SpanNodeGeneratorWithTag(
      tag: MarkdownTag.blockquote.name,
      generator: (e, config, visitor) =>
          _OccBlockquoteNode(config.blockquote, visitor, this),
    ),
    SpanNodeGeneratorWithTag(
      tag: MarkdownTag.li.name,
      generator: (e, config, visitor) => _OccListNode(config, visitor, this),
    ),
    SpanNodeGeneratorWithTag(
      tag: MarkdownTag.td.name,
      generator: (e, config, visitor) =>
          _OccTdNode(e.attributes, visitor, this),
    ),
    SpanNodeGeneratorWithTag(
      tag: MarkdownTag.th.name,
      generator: (e, config, visitor) => _OccThNode(this),
    ),
    SpanNodeGeneratorWithTag(
      tag: MarkdownTag.pre.name,
      generator: (e, config, visitor) =>
          _OccCodeBlockNode(e, config.pre, visitor, this),
    ),
    SpanNodeGeneratorWithTag(
      tag: MarkdownTag.img.name,
      generator: (e, config, visitor) =>
          _OccImageNode(e.attributes, config, visitor, this),
    ),
  ];

  static HeadingConfig _headingConfigFor(MarkdownConfig config, String tag) {
    switch (tag) {
      case 'h1':
        return config.h1;
      case 'h2':
        return config.h2;
      case 'h3':
        return config.h3;
      case 'h4':
        return config.h4;
      case 'h5':
        return config.h5;
      default:
        return config.h6;
    }
  }

  /// Observe node acceptance to assign the incremental structural path prefix.
  void onNodeAccepted(SpanNode node, int index) {
    final parent = node.parent;
    final parentPath = parent == null ? null : _paths[parent];
    List<int> path;
    if (parentPath == null) {
      // Parent is the untracked top-level wrapper: this is a top-level block.
      path = <int>[index];
    } else {
      // The node was just appended to its parent's children, so its ordinal is
      // the last index. This is taken at accept time and is stable regardless
      // of any build-time child mutation (e.g. task checkbox removal).
      final ordinal = (parent as ElementNode).children.length - 1;
      path = <int>[...parentPath, ordinal];
    }
    _paths[node] = path;
    if (node is _OccurrenceOwnerNode) {
      node.occAssign(path);
    }
  }

  void _expect(OccurrenceOwnerId id, int blockIndex, UnitKind kind) {
    _expected[id] = _OwnerMeta(blockIndex, kind);
  }

  void _record(OccurrenceOwnerId id, String text) {
    _recorded[id] = text;
  }

  /// Finalize the pass: order units, resolve heading context, and report
  /// completeness (every expected owner produced a unit).
  ReaderTextUnitCaptureResult finish() {
    final ids = _expected.keys.toList()..sort((a, b) => a.compareTo(b));
    final complete = _recorded.keys.toSet().containsAll(_expected.keys);
    String? runningHeading;
    final units = <ReaderTextUnit>[];
    for (final id in ids) {
      final meta = _expected[id]!;
      final text = _recorded[id] ?? '';
      if (meta.kind == UnitKind.heading) {
        final h = text.trim();
        if (h.isNotEmpty) runningHeading = h;
      }
      units.add(
        ReaderTextUnit(
          id: id,
          text: text,
          blockIndex: meta.blockIndex,
          heading: runningHeading,
          kind: meta.kind,
        ),
      );
    }
    return ReaderTextUnitCaptureResult(
      units: List<ReaderTextUnit>.unmodifiable(units),
      isComplete: complete,
    );
  }
}

String _plain(InlineSpan span) => span.toPlainText(
  includeSemanticsLabels: false,
  includePlaceholders: false,
);

/// Shared owner behaviour (path assignment, registration policy, capture).
mixin _OccurrenceOwnerNode on SpanNode {
  ReaderTextUnitCapture get _capture;
  UnitKind get _unitKind;

  OccurrenceOwnerId? _ownerId;
  int _blockIndex = 0;
  bool _registers = false;

  /// Whether this owner draws its own `RenderParagraph` that is not absorbed
  /// into an ancestor owner's content span. TextSpan-returning nodes
  /// (paragraph, no-divider heading) only own a paragraph when top-level;
  /// WidgetSpan-returning nodes (blockquote, list item, cell, code, divider
  /// heading) always own one.
  bool _shouldRegister(List<int> path);

  void occAssign(List<int> path) {
    final id = OccurrenceOwnerId(List<int>.unmodifiable(path));
    _ownerId = id;
    _blockIndex = path.first;
    _registers = _shouldRegister(path);
    if (_registers) _capture._expect(id, _blockIndex, _unitKind);
  }

  /// Wrap and capture a text-owner span. Returns the input unchanged when this
  /// node is not a registering owner (its text belongs to an ancestor owner).
  TextSpan _tagText(TextSpan base) {
    if (!_registers) return base;
    final tagged = OccurrenceTaggedSpan(base, _ownerId!);
    _capture._record(_ownerId!, _plain(tagged));
    return tagged;
  }
}

class _OccParagraphNode extends ParagraphNode with _OccurrenceOwnerNode {
  _OccParagraphNode(super.pConfig, this._capture);

  @override
  final ReaderTextUnitCapture _capture;

  @override
  UnitKind get _unitKind => UnitKind.prose;

  // A paragraph only owns its own RenderParagraph when top-level; nested
  // paragraphs are inlined into the enclosing owner's content span.
  @override
  bool _shouldRegister(List<int> path) => path.length == 1;

  @override
  InlineSpan build() {
    final base = super.build();
    if (!_registers || base is! TextSpan) return base;
    return _tagText(base);
  }
}

class _OccHeadingNode extends HeadingNode with _OccurrenceOwnerNode {
  _OccHeadingNode(super.headingConfig, super.visitor, this._capture);

  @override
  final ReaderTextUnitCapture _capture;

  @override
  UnitKind get _unitKind => UnitKind.heading;

  // A divider heading always builds its own ProxyRichText; a no-divider heading
  // returns a TextSpan and only owns a paragraph when top-level.
  @override
  bool _shouldRegister(List<int> path) =>
      headingConfig.divider != null || path.length == 1;

  @override
  TextSpan get childrenSpan => _tagText(super.childrenSpan);
}

class _OccBlockquoteNode extends BlockquoteNode with _OccurrenceOwnerNode {
  _OccBlockquoteNode(super.config, super.visitor, this._capture);

  @override
  final ReaderTextUnitCapture _capture;

  @override
  UnitKind get _unitKind => UnitKind.blockquote;

  @override
  bool _shouldRegister(List<int> path) => true;

  @override
  TextSpan get childrenSpan => _tagText(super.childrenSpan);
}

class _OccTdNode extends TdNode with _OccurrenceOwnerNode {
  _OccTdNode(super.attribute, super.visitor, this._capture);

  @override
  final ReaderTextUnitCapture _capture;

  @override
  UnitKind get _unitKind => UnitKind.tableCell;

  @override
  bool _shouldRegister(List<int> path) => true;

  @override
  TextSpan get childrenSpan => _tagText(super.childrenSpan);
}

class _OccThNode extends ThNode with _OccurrenceOwnerNode {
  _OccThNode(this._capture);

  @override
  final ReaderTextUnitCapture _capture;

  @override
  UnitKind get _unitKind => UnitKind.tableCell;

  @override
  bool _shouldRegister(List<int> path) => true;

  @override
  TextSpan get childrenSpan => _tagText(super.childrenSpan);
}

class _OccCodeBlockNode extends CodeBlockNode with _OccurrenceOwnerNode {
  _OccCodeBlockNode(super.element, super.preConfig, super.visitor, this._capture);

  @override
  final ReaderTextUnitCapture _capture;

  @override
  UnitKind get _unitKind => UnitKind.code;

  @override
  bool _shouldRegister(List<int> path) => true;

  @override
  InlineSpan build() {
    // Code is app-owned (PreConfig.builder → CodeBlock). Its displayed string is
    // `code.trimRight()` (blocks.dart), captured directly rather than via a
    // tagged span. CP2 threads the owner id onto the built CodeBlock so it can
    // read its per-owner match state and paint the highlighted token leaves.
    if (_registers) _capture._record(_ownerId!, content.trimRight());
    final original = super.build();
    if (_registers &&
        original is WidgetSpan &&
        original.child is CodeBlock) {
      final block = original.child as CodeBlock;
      return WidgetSpan(
        alignment: original.alignment,
        baseline: original.baseline,
        style: original.style,
        child: block.withOwner(_ownerId!),
      );
    }
    return original;
  }
}

/// Remote-image placeholder owner(s) (decision.md D-004).
///
/// The image renders through the app-owned `ImgConfig.builder` →
/// [RemoteImagePlaceholder], which draws its alt/fallback label, generated
/// status sentence and (for remote images) the URL in **three separate `Text`
/// widgets — three distinct `RenderParagraph`s**. Per plan §§3.1–3.2 one unit
/// maps to one leaf text owner, so each displayed run is captured as its **own**
/// unit with its own structural owner id (`[…imgPath, runIndex]`) and its own
/// per-paragraph text/ranges. Like code, this app-owned surface is captured by
/// observation from [RemoteImagePlaceholder.displayedTextLines], the single
/// shared source of truth the widget itself renders from, so capture and render
/// cannot drift. The full URL is captured (preserving DF-041 alt+remote-`src`
/// coverage) and the widget now presents the full URL (it wraps rather than
/// ellipsizing), so no searchable literal is concealed (D-004).
class _OccImageNode extends ImageNode with _OccurrenceOwnerNode {
  _OccImageNode(super.attributes, super.config, super.visitor, this._capture);

  @override
  final ReaderTextUnitCapture _capture;

  @override
  UnitKind get _unitKind => UnitKind.image;

  // Registration is handled per displayed run in [occAssign]; this is unused for
  // the image owner but satisfies the mixin contract.
  @override
  bool _shouldRegister(List<int> path) => true;

  List<OccurrenceOwnerId> _runIds = const [];
  List<String> _runs = const [];

  @override
  void occAssign(List<int> path) {
    _blockIndex = path.first;
    _runs = RemoteImagePlaceholder.displayedTextLines(
      url: attributes['src'] ?? '',
      alt: attributes['alt'] ?? '',
    );
    _runIds = <OccurrenceOwnerId>[
      for (var i = 0; i < _runs.length; i++)
        OccurrenceOwnerId(List<int>.unmodifiable(<int>[...path, i])),
    ];
    for (final id in _runIds) {
      _capture._expect(id, _blockIndex, UnitKind.image);
    }
    _registers = _runIds.isNotEmpty;
  }

  @override
  InlineSpan build() {
    for (var i = 0; i < _runIds.length; i++) {
      _capture._record(_runIds[i], _runs[i]);
    }
    final original = super.build();
    if (_registers &&
        original is WidgetSpan &&
        original.child is RemoteImagePlaceholder) {
      final placeholder = original.child as RemoteImagePlaceholder;
      return WidgetSpan(
        alignment: original.alignment,
        baseline: original.baseline,
        style: original.style,
        child: placeholder.withRunOwners(_runIds),
      );
    }
    return original;
  }
}

/// List-item widget-composition adapter (plan.md §5.4).
///
/// The pinned `ListNode.build()` builds its own content `TextSpan` and never
/// reads `childrenSpan`, returning
/// `WidgetSpan → Padding → Row[SizedBox(marker), Flexible(ProxyRichText(content))]`.
/// No getter override can reach the inner content owner, so this adapter calls
/// `super.build()` (reusing all marker/numbering/`SelectionContainer.disabled`/
/// task-checkbox construction verbatim) and rebuilds only the path down to the
/// inner content `ProxyRichText`, replacing its `textSpan` with a tagged span.
/// The leading marker `Row` child is preserved by reference, so ordered/
/// unordered/nested/task markers and the checkbox are untouched.
///
/// If the pinned widget shape ever differs from the above, the adapter records
/// no unit and the pass fails completeness (fail-closed), rather than tagging
/// the wrong owner (plan.md §18 condition 5).
class _OccListNode extends ListNode with _OccurrenceOwnerNode {
  _OccListNode(super.config, super.visitor, this._capture);

  @override
  final ReaderTextUnitCapture _capture;

  @override
  UnitKind get _unitKind => UnitKind.listItem;

  @override
  bool _shouldRegister(List<int> path) => true;

  @override
  InlineSpan build() {
    final original = super.build();
    if (!_registers) return original;

    if (original is! WidgetSpan) return original;
    final padding = original.child;
    if (padding is! Padding) return original;
    final row = padding.child;
    if (row is! Row || row.children.length != 2) return original;
    final flexible = row.children.last;
    if (flexible is! Flexible) return original;
    final proxy = flexible.child;
    if (proxy is! ProxyRichText) return original;

    final tagged = OccurrenceTaggedSpan(proxy.textSpan, _ownerId!);
    _capture._record(_ownerId!, _plain(tagged));

    final newProxy = ProxyRichText(
      tagged,
      key: proxy.key,
      richTextBuilder: proxy.richTextBuilder,
    );
    final newFlexible = Flexible(
      key: flexible.key,
      flex: flexible.flex,
      fit: flexible.fit,
      child: newProxy,
    );
    final newRow = Row(
      key: row.key,
      mainAxisAlignment: row.mainAxisAlignment,
      mainAxisSize: row.mainAxisSize,
      crossAxisAlignment: row.crossAxisAlignment,
      textDirection: row.textDirection,
      verticalDirection: row.verticalDirection,
      textBaseline: row.textBaseline,
      spacing: row.spacing,
      children: <Widget>[row.children.first, newFlexible],
    );
    final newPadding = Padding(
      key: padding.key,
      padding: padding.padding,
      child: newRow,
    );
    return WidgetSpan(
      child: newPadding,
      alignment: original.alignment,
      baseline: original.baseline,
      style: original.style,
    );
  }
}
