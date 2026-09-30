import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/blocks.dart';
import 'package:markdown_viewer/markdown_theme.dart';
import 'package:markdown_viewer/reader_screen.dart';
import 'package:markdown_viewer/reader_text_unit.dart';

/// DF-052 CP2 unit coverage for the corrected occurrence-indication mechanism:
/// the painter (all/active overlays that preserve text/recognizers/semantics),
/// the placeholder-inclusive offset mapping used by the range reveal, the
/// per-query model grouping, and the duplicate-tolerant render-candidate
/// registry with a single centrally promoted locator (plan.md §§6, D-1, D-2).
void main() {
  final style = OccurrenceIndicationStyle.of(ReaderPalette.light);

  String plain(InlineSpan span) => span.toPlainText(
    includeSemanticsLabels: false,
    includePlaceholders: false,
  );

  List<TextSpan> leaves(InlineSpan span) {
    final out = <TextSpan>[];
    void walk(InlineSpan s) {
      if (s is TextSpan) {
        if (s.text != null && s.text!.isNotEmpty) out.add(s);
        for (final c in s.children ?? const <InlineSpan>[]) {
          walk(c);
        }
      }
    }

    walk(span);
    return out;
  }

  group('paintOccurrences', () {
    test('preserves the exact text under all/active overlays', () {
      const source = TextSpan(text: 'alpha needle beta needle');
      final painted = paintOccurrences(
        source,
        const OwnerMatchState(
          [OccurrenceRange(6, 12), OccurrenceRange(18, 24)],
          OccurrenceRange(6, 12),
        ),
        style,
      );
      expect(plain(painted), 'alpha needle beta needle');
    });

    test('marks the active piece non-colour-only (weight + underline)', () {
      const source = TextSpan(text: 'a needle b');
      final painted = paintOccurrences(
        source,
        const OwnerMatchState(
          [OccurrenceRange(2, 8)],
          OccurrenceRange(2, 8),
        ),
        style,
      );
      final active = leaves(painted).firstWhere((s) => s.text == 'needle');
      expect(active.style?.fontWeight, FontWeight.w700);
      expect(active.style?.decoration, TextDecoration.underline);
      // A non-active match gets a background but no weight/underline.
      final painted2 = paintOccurrences(
        source,
        const OwnerMatchState([OccurrenceRange(2, 8)], null),
        style,
      );
      final allOnly = leaves(painted2).firstWhere((s) => s.text == 'needle');
      expect(allOnly.style?.fontWeight, isNot(FontWeight.w700));
      expect(allOnly.style?.backgroundColor, isNotNull);
    });

    test('re-attaches the recognizer to every split piece', () {
      final recognizer = TapGestureRecognizer();
      addTearDown(recognizer.dispose);
      final source = TextSpan(
        children: [
          TextSpan(text: 'see needle here', recognizer: recognizer),
        ],
      );
      final painted = paintOccurrences(
        source,
        const OwnerMatchState(
          [OccurrenceRange(4, 10)],
          OccurrenceRange(4, 10),
        ),
        style,
      );
      // Every emitted text piece keeps the original recognizer, so a link's hit
      // range is unchanged by splitting (plan.md §6.1).
      for (final leaf in leaves(painted)) {
        expect(leaf.recognizer, same(recognizer));
      }
    });

    test('keeps an exact emoji ZWJ sequence intact when highlighted', () {
      const family = '\u{1F468}‍\u{1F469}‍\u{1F467}‍\u{1F466}';
      final source = TextSpan(text: 'x${family}y');
      final painted = paintOccurrences(
        source,
        OwnerMatchState(
          [OccurrenceRange(1, 1 + family.length)],
          OccurrenceRange(1, 1 + family.length),
        ),
        style,
      );
      expect(plain(painted), 'x${family}y');
      final active = leaves(painted).firstWhere((s) => s.text == family);
      expect(active.style?.fontWeight, FontWeight.w700);
    });
  });

  group('offsetIncludingPlaceholders', () {
    test('is the identity when there are no placeholders', () {
      const span = TextSpan(text: 'hello world');
      expect(offsetIncludingPlaceholders(span, 6, isStart: true), 6);
      expect(offsetIncludingPlaceholders(span, 11, isStart: false), 11);
    });

    test('advances past a leading placeholder (WidgetSpan counts as one)', () {
      final span = TextSpan(
        children: const [
          WidgetSpan(child: SizedBox.shrink()),
          TextSpan(text: 'abcde'),
        ],
      );
      // Text offset 0 ('a') maps to geometry offset 1 (after the placeholder).
      expect(offsetIncludingPlaceholders(span, 0, isStart: true), 1);
      expect(offsetIncludingPlaceholders(span, 5, isStart: false), 6);
    });
  });

  group('ReaderSearchModel', () {
    test('groups by owner and exposes only the active owner range', () {
      const a = OccurrenceOwnerId([0]);
      const b = OccurrenceOwnerId([1]);
      // OccurrenceOwnerId overrides ==/hashCode, so the byOwner map cannot be a
      // const map literal; build the model at runtime instead.
      final model = ReaderSearchModel(
        byOwner: {
          a: const [OccurrenceRange(0, 3), OccurrenceRange(7, 10)],
          b: const [OccurrenceRange(0, 3)],
        },
        activeOwner: b,
        activeRange: const OccurrenceRange(0, 3),
        activeLabel: 'Search result 3 of 3, H',
      );
      expect(model.matchStateFor(a)!.all.length, 2);
      expect(model.matchStateFor(a)!.active, isNull);
      expect(model.matchStateFor(b)!.active, const OccurrenceRange(0, 3));
      expect(model.matchStateFor(const OccurrenceOwnerId([2])), isNull);
    });
  });

  group('ActiveLocatorRegistry', () {
    final revision = DocumentRevision.fromDocument(
      id: 'doc',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      source: 'body',
    );
    const owner = OccurrenceOwnerId([0]);

    test('promotes exactly one candidate and never two', () {
      final registry = ActiveLocatorRegistry(revision);
      final a = _FakeCandidate(owner);
      final b = _FakeCandidate(owner);
      registry
        ..register(a)
        ..register(b);
      expect(registry.candidatesFor(owner).length, 2);
      expect(registry.promotedFocusNode, isNull);

      registry.promote(a, 1);
      expect(registry.isPromoted(a), isTrue);
      expect(registry.isPromoted(b), isFalse);

      // Promoting the other copy demotes the first — one at a time.
      registry.promote(b, 2);
      expect(registry.isPromoted(a), isFalse);
      expect(registry.isPromoted(b), isTrue);

      registry.clearPromotion();
      expect(registry.isPromoted(b), isFalse);
      expect(registry.promotedFocusNode, isNull);
      for (final c in [a, b]) {
        c.dispose();
      }
      registry.dispose();
    });

    test('deregistering the promoted copy silently clears the promotion', () {
      final registry = ActiveLocatorRegistry(revision);
      final a = _FakeCandidate(owner);
      registry
        ..register(a)
        ..promote(a, 1);
      var notified = 0;
      registry.addListener(() => notified++);
      registry.deregister(a, ownerId: owner, revision: revision);
      expect(registry.isPromoted(a), isFalse);
      expect(registry.promotedFocusNode, isNull);
      // Deregister is dispose-safe: it must not notify listeners.
      expect(notified, 0);
      a.dispose();
      registry.dispose();
    });

    test('ignores a deregister carrying a value-unequal revision', () {
      final registry = ActiveLocatorRegistry(revision);
      final a = _FakeCandidate(owner);
      registry.register(a);
      final stale = DocumentRevision.fromDocument(
        id: 'doc',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1),
        source: 'body',
      );
      registry.deregister(a, ownerId: owner, revision: stale);
      expect(registry.candidatesFor(owner).length, 1);
      a.dispose();
      registry.dispose();
    });
  });

  group('RemoteImagePlaceholder displayed runs (decision.md D-004)', () {
    test('exposes label, status, and the full URL as three searchable runs', () {
      const url = 'https://example.com/needle-path.png';
      final runs =
          RemoteImagePlaceholder.displayedTextLines(url: url, alt: 'diagram alt');
      // Three distinct displayed runs, each its own occurrence owner: the
      // alt/fallback label, the generated status sentence, and the displayed URL.
      expect(runs, <String>[
        'diagram alt',
        RemoteImagePlaceholder.remoteStatus,
        url,
      ]);
      // The full URL is present verbatim — not ellipsized — so no searchable
      // literal is concealed; a 'needle' query matches inside the URL path.
      expect(runs.last, url);
      expect(runs.last.contains('needle'), isTrue);
      // The generated status sentence is itself searchable (Human chose all
      // displayed placeholder text, decision.md D-004).
      expect(runs[1].toLowerCase().contains('remote image'), isTrue);
    });

    test('a missing alt falls back to a label and a non-remote URL drops the '
        'URL run', () {
      final remote = RemoteImagePlaceholder.displayedTextLines(
        url: 'https://host/x.png',
        alt: '',
      );
      expect(remote, <String>[
        'Image',
        RemoteImagePlaceholder.remoteStatus,
        'https://host/x.png',
      ]);
      final local = RemoteImagePlaceholder.displayedTextLines(
        url: 'assets/local.png',
        alt: 'local alt',
      );
      // A non-remote image presents no URL and a different status; only the label
      // and status runs are searchable.
      expect(local, <String>['local alt', RemoteImagePlaceholder.localStatus]);
    });
  });
}

/// A minimal [ActiveOwnerCandidate] for pure-logic registry tests; the geometry
/// members are unused by register/promote/deregister.
class _FakeCandidate implements ActiveOwnerCandidate {
  _FakeCandidate(this._ownerId);

  final OccurrenceOwnerId _ownerId;
  final FocusNode _node = FocusNode();

  @override
  OccurrenceOwnerId get ownerId => _ownerId;

  @override
  FocusNode get focusNode => _node;

  @override
  bool get isCandidateMounted => true;

  @override
  BuildContext get candidateContext => throw UnimplementedError();

  @override
  RenderParagraph? resolveParagraph() => null;

  void dispose() => _node.dispose();
}
