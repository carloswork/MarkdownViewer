import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

import 'blocks.dart';

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
    // tagged span. Painting the token leaves is CP2.
    if (_registers) _capture._record(_ownerId!, content.trimRight());
    return super.build();
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
    return super.build();
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
