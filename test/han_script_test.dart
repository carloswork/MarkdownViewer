import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/han_script.dart';
import 'package:markdown_viewer/han_script_tables.dart';
import 'package:markdown_viewer/markdown_theme.dart';
import 'package:markdown_viewer/models.dart';

/// DF-031 CP-B — the resolver, the ambiguity corpus and the chain shapes.
///
/// Cases 3-7 assert **declared, deterministic behaviour under ambiguity**, not
/// classification accuracy. No set of test cases can turn an
/// information-theoretically ambiguous document into a reliable classification,
/// and `plan.md` §5.4.2 says so plainly rather than implying otherwise. What is
/// asserted is that the declared behaviour is the behaviour.
///
/// The corpus below is **self-validating**: `corpus integrity` proves every
/// sample character really sits in the set the case name claims, read from the
/// generated tables. Without it a regenerated repertoire could silently turn a
/// discriminating character into a shared one and leave every case passing for
/// the wrong reason.

// --- The corpus -------------------------------------------------------------

/// Traditional-exclusive. These are the twelve characters `plan.md` §3.6
/// measured as missing from the Simplified subset, which is what makes them
/// exclusive to the Traditional repertoire.
const String kTraditionalExclusiveSample = '說編輯設與錯誤處請閱讀單';

/// Simplified-exclusive: the Simplified counterparts of the twelve above.
const String kSimplifiedExclusiveSample = '说编辑设与错误处请阅读单';

/// Shared Han only. Every character is in the 3,715-code-point overlap, so the
/// document contains **zero** evidence in either direction.
const String kSharedHanSample = '中文的一二三人大山水日月天地不上下';

/// Big5 Level 2 characters that sit in the **Simplified-exclusive** set.
///
/// Ordinary in Traditional writing, and in that set only because the
/// Traditional repertoire was drawn at Big5 Level 1 (plan.md §3.4.1, §5.4.2).
/// This is the R10 evidence base, and it votes the wrong way by construction.
const List<int> kBig5Level2InSimplifiedExclusive = <int>[
  0x4E07, 0x4E0E, 0x4E47, 0x4E5C, 0x4E8D,
  0x4E93, 0x4EC9, 0x4EDD, 0x4EE1, 0x4EE8,
];

/// Big5 Level 2 characters in **neither** shipped pack. These tofu; the
/// preference cannot fix them, and R15 records that consequence.
const List<int> kBig5Level2OutsideUnion = <int>[
  0x4E0F, 0x4E2E, 0x4E31, 0x4E33, 0x4E3C,
  0x4E42, 0x4E7F, 0x4E83, 0x4E84, 0x4EB6,
];

String _string(List<int> codePoints) => String.fromCharCodes(codePoints);

MarkdownDocument _document(
  String source, {
  DocumentScriptPreference preference = DocumentScriptPreference.auto,
}) {
  return MarkdownDocument.fromSource(
    source,
  ).copyWith(scriptPreference: preference);
}

void main() {
  // ---------------------------------------------------------------------------
  // Corpus integrity. Everything below rests on these memberships.
  // ---------------------------------------------------------------------------
  group('corpus integrity', () {
    void expectAllIn(String label, String sample, List<int> table) {
      for (final codePoint in sample.runes) {
        expect(
          hanScriptTableContains(table, codePoint),
          isTrue,
          reason:
              '$label: U+${codePoint.toRadixString(16).toUpperCase()} is not in '
              'the table this case depends on - the corpus has drifted from the '
              'shipped repertoires and every case using it is now vacuous',
        );
      }
    }

    test('the Traditional sample is Traditional-exclusive throughout', () {
      expectAllIn(
        'traditional sample',
        kTraditionalExclusiveSample,
        kHantExclusiveRanges,
      );
      for (final codePoint in kTraditionalExclusiveSample.runes) {
        expect(
          hanScriptTableContains(kHansExclusiveRanges, codePoint),
          isFalse,
          reason: 'a character cannot be exclusive to both packs',
        );
      }
      expect(kTraditionalExclusiveSample.runes.length, 12);
    });

    test('the Simplified sample is Simplified-exclusive throughout', () {
      expectAllIn(
        'simplified sample',
        kSimplifiedExclusiveSample,
        kHansExclusiveRanges,
      );
      for (final codePoint in kSimplifiedExclusiveSample.runes) {
        expect(
          hanScriptTableContains(kHantExclusiveRanges, codePoint),
          isFalse,
        );
      }
      expect(kSimplifiedExclusiveSample.runes.length, 12);
    });

    test('the shared sample carries no exclusive character at all', () {
      for (final codePoint in kSharedHanSample.runes) {
        expect(hanScriptTableContains(kHansExclusiveRanges, codePoint), isFalse);
        expect(hanScriptTableContains(kHantExclusiveRanges, codePoint), isFalse);
        expect(
          hanScriptTableContains(kHanUnionRanges, codePoint),
          isTrue,
          reason: 'shared Han is in both packs, so it is in the union',
        );
      }
    });

    test('the Big5 Level 2 sample really is Simplified-exclusive', () {
      // This is the R10 fact stated as a test rather than as prose. If these
      // ever stop being Simplified-exclusive, case 7 below is measuring nothing.
      for (final codePoint in kBig5Level2InSimplifiedExclusive) {
        expect(
          hanScriptTableContains(kHansExclusiveRanges, codePoint),
          isTrue,
          reason:
              'U+${codePoint.toRadixString(16).toUpperCase()} is ordinary '
              'Traditional vocabulary that sits in the SIMPLIFIED-exclusive set',
        );
        expect(
          hanScriptTableContains(kHantExclusiveRanges, codePoint),
          isFalse,
        );
      }
    });

    test('the outside-union sample is covered by neither pack', () {
      for (final codePoint in kBig5Level2OutsideUnion) {
        expect(
          hanScriptTableContains(kHanUnionRanges, codePoint),
          isFalse,
          reason: 'these are the characters that tofu whichever pack leads',
        );
      }
    });
  });

  // ---------------------------------------------------------------------------
  // The generated tables themselves.
  // ---------------------------------------------------------------------------
  group('generated detection tables', () {
    test('the tables carry the pinned §3.6 figures', () {
      expect(kHansExclusiveCount, 3379);
      expect(kHantExclusiveCount, 2105);
      expect(kHanUnionCount, 9199);
    });

    int sizeOf(List<int> table) {
      var total = 0;
      for (var i = 0; i < table.length; i += 2) {
        total += table[i + 1] - table[i] + 1;
      }
      return total;
    }

    test('each table expands to exactly the code points it claims', () {
      expect(sizeOf(kHansExclusiveRanges), kHansExclusiveCount);
      expect(sizeOf(kHantExclusiveRanges), kHantExclusiveCount);
      expect(sizeOf(kHanUnionRanges), kHanUnionCount);
    });

    test('each table is well formed: pairs, ascending, non-overlapping', () {
      for (final table in <List<int>>[
        kHansExclusiveRanges,
        kHantExclusiveRanges,
        kHanUnionRanges,
      ]) {
        expect(
          table.length.isEven,
          isTrue,
          reason: 'a range table is a flat list of [lo, hi] pairs',
        );
        for (var i = 0; i < table.length; i += 2) {
          expect(table[i], lessThanOrEqualTo(table[i + 1]));
          if (i > 0) {
            expect(
              table[i - 1] + 1,
              lessThan(table[i]),
              reason:
                  'ranges must be ascending and separated by at least one gap, '
                  'or the generator failed to coalesce them - binary search '
                  'depends on it',
            );
          }
        }
      }
    });

    test('no code point is exclusive to both packs', () {
      for (var i = 0; i < kHantExclusiveRanges.length; i += 2) {
        for (var cp = kHantExclusiveRanges[i];
            cp <= kHantExclusiveRanges[i + 1];
            cp++) {
          expect(
            hanScriptTableContains(kHansExclusiveRanges, cp),
            isFalse,
            reason: 'U+${cp.toRadixString(16)} cannot be exclusive to both',
          );
          expect(hanScriptTableContains(kHanUnionRanges, cp), isTrue);
        }
      }
    });

    test('every Simplified-exclusive code point is in the union', () {
      for (var i = 0; i < kHansExclusiveRanges.length; i += 2) {
        for (var cp = kHansExclusiveRanges[i];
            cp <= kHansExclusiveRanges[i + 1];
            cp++) {
          expect(hanScriptTableContains(kHanUnionRanges, cp), isTrue);
        }
      }
    });

    test('the tables agree with the committed repertoire manifests', () {
      // The manifests are the realised cmaps CP-A committed. The tables are
      // derived from the same cmaps by the same tool run, so they must agree
      // exactly - this is what "cannot drift from what is shipped" means.
      Set<int> manifest(String family) => File(
        'tool/fonts/manifests/$family-repertoire.txt',
      )
          .readAsLinesSync()
          .where((line) => line.startsWith('U+'))
          .map((line) => int.parse(line.substring(2), radix: 16))
          .toSet();

      final hans = manifest('SaudoHans');
      final hant = manifest('SaudoHant');

      expect(hans.union(hant).length, kHanUnionCount);
      for (final cp in hans.union(hant)) {
        expect(
          hanScriptTableContains(kHanUnionRanges, cp),
          isTrue,
          reason: 'U+${cp.toRadixString(16)} is shipped but not in the union table',
        );
      }

      bool isHan(int c) =>
          (c >= 0x4E00 && c <= 0x9FFF) ||
          (c >= 0x3400 && c <= 0x4DBF) ||
          (c >= 0xF900 && c <= 0xFAFF);

      final hansExclusive = hans.difference(hant).where(isHan).toSet();
      final hantExclusive = hant.difference(hans).where(isHan).toSet();
      expect(hansExclusive, hasLength(kHansExclusiveCount));
      expect(hantExclusive, hasLength(kHantExclusiveCount));
      for (final cp in hansExclusive) {
        expect(hanScriptTableContains(kHansExclusiveRanges, cp), isTrue);
      }
      for (final cp in hantExclusive) {
        expect(hanScriptTableContains(kHantExclusiveRanges, cp), isTrue);
      }
    });

    test('the generated file declares itself generated', () {
      final source = File('lib/han_script_tables.dart').readAsStringSync();
      expect(source, startsWith('// GENERATED FILE - DO NOT EDIT BY HAND.'));
      expect(source, contains('build_han_subsets.py'));
    });

    test('lib/ contains no hand-curated Han character list', () {
      // plan.md §5.4.2: the detection sets are generated, never hand-written.
      // The only file in lib/ allowed to carry bulk code-point data is the
      // generated one.
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.endsWith('han_script_tables.dart')) continue;
        final source = entity.readAsStringSync();
        final hexLiterals = RegExp(r'0x[0-9A-Fa-f]{4}\b').allMatches(source);
        expect(
          hexLiterals.length,
          lessThan(20),
          reason:
              '${entity.path} looks like it carries a code-point list; the '
              'detection data must come from the generated table only',
        );
      }
    });
  });

  // ---------------------------------------------------------------------------
  // The §12 ambiguity corpus, cases 1-17.
  // ---------------------------------------------------------------------------
  group('detection corpus', () {
    test('case 1: a clear Traditional document resolves to hant', () {
      // The twelve-character sample on its own, matching plan.md §3.6's
      // measured result: 12 Traditional-exclusive against 0 the other way.
      final sample = HanScriptEvidence.of(kTraditionalExclusiveSample);
      expect(sample.hantVotes, 12);
      expect(sample.hansVotes, 0);

      // And as a whole document, heading included.
      final source = '# 報告\n\n$kTraditionalExclusiveSample';
      final evidence = HanScriptEvidence.of(source);

      expect(evidence.hantVotes, greaterThanOrEqualTo(12));
      expect(evidence.hansVotes, 0);
      expect(evidence.hantVotes, greaterThan(evidence.hansVotes));
      expect(resolveHanScript(source), HanScript.hant);
    });

    test('case 2: a clear Simplified document resolves to hans', () {
      final sample = HanScriptEvidence.of(kSimplifiedExclusiveSample);
      expect(sample.hansVotes, 12);
      expect(sample.hantVotes, 0);

      final source = '# 报告\n\n$kSimplifiedExclusiveSample';
      final evidence = HanScriptEvidence.of(source);

      expect(evidence.hansVotes, greaterThanOrEqualTo(12));
      expect(evidence.hantVotes, 0);
      expect(evidence.hansVotes, greaterThan(evidence.hantVotes));
      expect(resolveHanScript(source), HanScript.hans);
    });

    test('case 3: a shared-Han-only document takes the declared default, '
        'deterministically, and every character renders', () {
      final evidence = HanScriptEvidence.of(kSharedHanSample);

      expect(
        evidence.isSilent,
        isTrue,
        reason: 'the overlap carries zero evidence either way, by construction',
      );
      expect(resolveHanScript(kSharedHanSample), kDefaultHanScript);
      expect(kDefaultHanScript, HanScript.hans);

      // Deterministic: the same input gives the same answer every time, which
      // is the property §5.4.3 actually promises.
      for (var i = 0; i < 5; i++) {
        expect(resolveHanScript(kSharedHanSample), kDefaultHanScript);
      }

      // And every character renders whichever pack leads, because both packs
      // sit in every chain. The failure mode is regional form, never coverage.
      for (final codePoint in kSharedHanSample.runes) {
        expect(hanScriptTableContains(kHanUnionRanges, codePoint), isTrue);
      }
      for (final lead in HanScript.values) {
        expect(bodyFontFallbackFor(lead), containsAll(kHanFamilyNames));
        expect(codeFontFallbackFor(lead), containsAll(kHanFamilyNames));
      }
    });

    test('case 4: an exact tie takes the declared default, deterministically', () {
      // Six of each: the counts are equal, so nothing wins strictly.
      final source =
          '${kTraditionalExclusiveSample.substring(0, 6)}'
          '${kSimplifiedExclusiveSample.substring(0, 6)}';
      final evidence = HanScriptEvidence.of(source);

      expect(evidence.hansVotes, 6);
      expect(evidence.hantVotes, 6);
      expect(evidence.isTied, isTrue);
      expect(evidence.isSilent, isFalse);
      expect(resolveHanScript(source), kDefaultHanScript);
      for (var i = 0; i < 5; i++) {
        expect(resolveHanScript(source), kDefaultHanScript);
      }
    });

    test('case 5: mostly Latin with a Chinese fragment carrying no exclusive '
        'character takes the default, and Latin is unaffected', () {
      final source =
          'The build pipeline is documented below, including the retry policy '
          'and the failure modes it is expected to cover. See 中文 for the '
          'localised note, then continue with the English text.';
      final evidence = HanScriptEvidence.of(source);

      expect(evidence.isSilent, isTrue);
      expect(resolveHanScript(source), kDefaultHanScript);

      // Latin is unaffected: Roboto stays the primary proportional family and
      // the Han families are appended behind the existing prefix, which they
      // cannot displace because they are disjoint from it.
      final theme = buildAppTheme(
        ReaderPalette.light,
        script: resolveHanScript(source),
      );
      expect(theme.textTheme.bodyMedium!.fontFamily, kBodyFont);
      expect(
        theme.textTheme.bodyMedium!.fontFamilyFallback!.take(2).toList(),
        kBodyFontFallback,
        reason: 'the DF-023/DF-024 prefix is untouched and still leads',
      );
    });

    test('case 6: mixed Traditional and Simplified - the majority wins, and '
        'one convention is applied to the whole document', () {
      // Seven Traditional against five Simplified.
      final source =
          '${kTraditionalExclusiveSample.substring(0, 7)}'
          '${kSimplifiedExclusiveSample.substring(0, 5)}';
      final evidence = HanScriptEvidence.of(source);

      expect(evidence.hantVotes, 7);
      expect(evidence.hansVotes, 5);
      expect(resolveHanScript(source), HanScript.hant);

      // A one-character margin flips the whole document. Asserted rather than
      // assumed, because it is the limitation §7.1 states.
      final flipped = '$source${kSimplifiedExclusiveSample.substring(5, 8)}';
      expect(HanScriptEvidence.of(flipped).hansVotes, 8);
      expect(resolveHanScript(flipped), HanScript.hans);

      // The §7.1 limitation itself: ONE document-level convention, applied
      // throughout. There is no per-span resolution and nothing in the resolved
      // chain varies by position in the document.
      final chain = bodyFontFallbackFor(resolveHanScript(source));
      expect(chain, bodyFontFallbackFor(HanScript.hant));
      expect(
        chain.where((f) => kHanFamilyNames.contains(f)).length,
        2,
        reason:
            'both packs are present so the minority convention still renders - '
            'it is the regional FORM that is wrong, not the coverage',
      );
    });

    test('case 7: a Big5 Level 2-heavy Traditional document votes toward hans '
        '- the R10 bias is active, not absent', () {
      final source = _string(kBig5Level2InSimplifiedExclusive);
      final evidence = HanScriptEvidence.of(source);

      // The Cycle 1 error was to expect "no vote either way". These characters
      // are ordinary Traditional vocabulary and they vote for SIMPLIFIED,
      // against the document's own convention.
      expect(
        evidence.isSilent,
        isFalse,
        reason:
            'asserting "no vote either way" here would encode the Cycle 1 '
            'error - the evidence base is asymmetric by construction',
      );
      expect(evidence.hansVotes, kBig5Level2InSimplifiedExclusive.length);
      expect(evidence.hantVotes, 0);
      expect(
        resolveHanScript(source),
        HanScript.hans,
        reason: 'hans-ward voting from the Level 2 characters (R10)',
      );

      // These render, in Simplified forms, from the SC pack.
      for (final codePoint in kBig5Level2InSimplifiedExclusive) {
        expect(hanScriptTableContains(kHanUnionRanges, codePoint), isTrue);
      }

      // And the residual tofu is real: the Level 2 characters in neither pack
      // are not rescued by any preference, which is why this is recorded as a
      // limitation rather than fixed.
      final tofu = _string(kBig5Level2OutsideUnion);
      for (final codePoint in tofu.runes) {
        expect(hanScriptTableContains(kHanUnionRanges, codePoint), isFalse);
      }
      expect(
        HanScriptEvidence.of(tofu).isSilent,
        isTrue,
        reason: 'characters in neither pack vote neither way',
      );
      expect(
        sourceUsesShippedHan(tofu),
        isFalse,
        reason:
            'R15: a document whose only Han lies outside both repertoires '
            'shows no control, because the preference could not fix the tofu',
      );
    });

    test('case 8: a document with no Chinese takes the default, consults no '
        'pack, and leaves the existing chains unchanged', () {
      const source = '# Release notes\n\nAll checks passed. ✅ 100% → done.';
      final evidence = HanScriptEvidence.of(source);

      expect(evidence.isSilent, isTrue);
      expect(evidence.hansVotes, 0);
      expect(evidence.hantVotes, 0);
      expect(resolveHanScript(source), kDefaultHanScript);
      expect(
        sourceUsesShippedHan(source),
        isFalse,
        reason: 'no character is ever looked up in either pack',
      );

      // The existing prefix is byte-for-byte what it was before DF-031.
      expect(kBodyFontFallback, <String>[kEmojiFont, kCodeFont]);
      expect(kCodeFontFallback, <String>[kEmojiFont]);
      final theme = buildAppTheme(ReaderPalette.light);
      expect(theme.textTheme.bodyMedium!.fontFamily, kBodyFont);
      expect(
        theme.textTheme.bodyMedium!.fontFamilyFallback!.take(2).toList(),
        kBodyFontFallback,
      );
    });

    test('case 9: an empty document, and the no-document path, take the '
        'default without crashing', () {
      expect(resolveHanScript(''), kDefaultHanScript);
      expect(HanScriptEvidence.of('').isSilent, isTrue);
      expect(sourceUsesShippedHan(''), isFalse);

      // The home screen has no document at all. buildAppTheme still runs there
      // (main.dart calls it above the home: builder), so this path must resolve
      // rather than throw - plan.md §5.5 fact 1.
      expect(resolveHanScriptForDocument(null), kDefaultHanScript);
      expect(
        () => buildAppTheme(
          ReaderPalette.light,
          script: resolveHanScriptForDocument(null),
        ),
        returnsNormally,
      );
      expect(
        resolveHanScriptForDocument(_document('')),
        kDefaultHanScript,
      );
    });

    test('case 10: an explicit Traditional preference wins and the detector is '
        'not consulted', () {
      // A document detection would unambiguously call Simplified.
      final source = kSimplifiedExclusiveSample;
      expect(resolveHanScript(source), HanScript.hans);

      expect(
        resolveHanScript(
          source,
          preference: DocumentScriptPreference.traditionalChinese,
        ),
        HanScript.hant,
      );

      // "Not consulted" is asserted, not assumed: the same explicit preference
      // returns hant for sources whose evidence points every possible way.
      for (final other in <String>[
        kSimplifiedExclusiveSample,
        kTraditionalExclusiveSample,
        kSharedHanSample,
        '',
        'plain English',
      ]) {
        expect(
          resolveHanScript(
            other,
            preference: DocumentScriptPreference.traditionalChinese,
          ),
          HanScript.hant,
          reason: 'the source cannot influence an explicit preference at all',
        );
      }
    });

    test('case 11: an explicit Simplified preference wins and the detector is '
        'not consulted', () {
      final source = kTraditionalExclusiveSample;
      expect(resolveHanScript(source), HanScript.hant);

      for (final other in <String>[
        kTraditionalExclusiveSample,
        kSimplifiedExclusiveSample,
        kSharedHanSample,
        '',
        'plain English',
      ]) {
        expect(
          resolveHanScript(
            other,
            preference: DocumentScriptPreference.simplifiedChinese,
          ),
          HanScript.hans,
        );
      }
    });

    test('case 12: resetting to Auto resumes detection and retains nothing of '
        'the override', () {
      final source = kTraditionalExclusiveSample;
      final overridden = _document(
        source,
        preference: DocumentScriptPreference.simplifiedChinese,
      );
      expect(resolveHanScriptForDocument(overridden), HanScript.hans);

      final reset = overridden.copyWith(
        scriptPreference: DocumentScriptPreference.auto,
      );
      expect(reset.scriptPreference, DocumentScriptPreference.auto);
      expect(
        resolveHanScriptForDocument(reset),
        HanScript.hant,
        reason: 'detection resumes immediately against the current source',
      );

      // Nothing of the override is retained: a fresh auto document with the
      // same source resolves identically.
      expect(
        resolveHanScriptForDocument(reset),
        resolveHanScriptForDocument(_document(source)),
      );
    });

    test('case 14: a replacement document resets to auto and does not inherit '
        'the previous explicit preference', () {
      final previous = _document(
        kSharedHanSample,
        preference: DocumentScriptPreference.traditionalChinese,
      );
      expect(previous.scriptPreference,
          DocumentScriptPreference.traditionalChinese);

      // _openDocument stores a fromSource document, which is always auto.
      final replacement = MarkdownDocument.fromSource(kSharedHanSample);
      expect(replacement.scriptPreference, DocumentScriptPreference.auto);
      expect(resolveHanScriptForDocument(replacement), kDefaultHanScript);
    });

    test('case 15: editing while auto re-runs detection and the resolved lead '
        'changes', () {
      final original = _document(kTraditionalExclusiveSample);
      expect(resolveHanScriptForDocument(original), HanScript.hant);

      // Exactly the shape of _editDocument's copyWith.
      final edited = original.copyWith(
        title: MarkdownDocument.deriveTitle(kSimplifiedExclusiveSample),
        source: kSimplifiedExclusiveSample,
        updatedAt: DateTime.now(),
      );

      expect(edited.scriptPreference, DocumentScriptPreference.auto);
      expect(
        resolveHanScriptForDocument(edited),
        HanScript.hans,
        reason: 'an edit can change the evidence, so auto must re-evaluate it',
      );
    });

    test('case 16: editing while an explicit preference is set preserves it, '
        'and the edited source does not override it', () {
      final original = _document(
        kSimplifiedExclusiveSample,
        preference: DocumentScriptPreference.traditionalChinese,
      );

      final edited = original.copyWith(
        title: MarkdownDocument.deriveTitle(kSimplifiedExclusiveSample),
        source: '$kSimplifiedExclusiveSample$kSimplifiedExclusiveSample',
        updatedAt: DateTime.now(),
      );

      expect(
        edited.scriptPreference,
        DocumentScriptPreference.traditionalChinese,
        reason: '"the source changed, so re-detect" is the obvious rule and it '
            'is wrong here',
      );
      expect(resolveHanScriptForDocument(edited), HanScript.hant);
      expect(
        HanScriptEvidence.of(edited.source).hansVotes,
        24,
        reason: 'the evidence overwhelmingly says hans, and is still ignored',
      );
    });

    test('case 17: a paste commit runs detection once, at the committed '
        'source, with no path reachable from the controller listener', () {
      // The editor has exactly one commit boundary: showMarkdownEditor returns
      // a value only from _submit, and cancelling returns null. Detection sits
      // on that boundary, and the resolved value is derived from the committed
      // source rather than stored.
      const committed = '# 报告\n\n$kSimplifiedExclusiveSample';
      final document = MarkdownDocument.fromSource(committed);

      expect(document.scriptPreference, DocumentScriptPreference.auto);
      expect(resolveHanScriptForDocument(document), HanScript.hans);

      // Detection is a pure function, so "once" is observable as: the same
      // committed source always yields the same answer, and intermediate
      // keystrokes never reach it.
      expect(
        resolveHanScript(committed),
        resolveHanScriptForDocument(document),
      );

      // No onChanged-driven detection path exists. The editor's controller
      // listener toggles a button's enabled state and propagates no text; this
      // asserts the prohibition in plan.md §5.6.5 structurally, because a later
      // edit could add one and no behavioural test would notice.
      final pasteSheet = File('lib/paste_sheet.dart').readAsStringSync();
      for (final symbol in <String>[
        'resolveHanScript',
        'HanScriptEvidence',
        'sourceUsesShippedHan',
        'scriptPreference',
      ]) {
        expect(
          pasteSheet.contains(symbol),
          isFalse,
          reason:
              'the editor must not reach detection: it has one commit '
              'boundary and detection belongs on it, never on a keystroke',
        );
      }
      expect(
        pasteSheet.contains('onChanged'),
        isFalse,
        reason: 'no onChanged path is added to the editor',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Precedence, stated once and directly.
  // ---------------------------------------------------------------------------
  group('precedence', () {
    test('explicit preference outranks automatic detection, for every source', () {
      const sources = <String>[
        kTraditionalExclusiveSample,
        kSimplifiedExclusiveSample,
        kSharedHanSample,
        '',
      ];
      for (final source in sources) {
        expect(
          resolveHanScript(
            source,
            preference: DocumentScriptPreference.traditionalChinese,
          ),
          HanScript.hant,
        );
        expect(
          resolveHanScript(
            source,
            preference: DocumentScriptPreference.simplifiedChinese,
          ),
          HanScript.hans,
        );
        expect(
          resolveHanScript(source, preference: DocumentScriptPreference.auto),
          HanScriptEvidence.of(source).verdict,
        );
      }
    });

    test('auto is the default argument, so an unspecified call detects', () {
      expect(
        resolveHanScript(kTraditionalExclusiveSample),
        resolveHanScript(
          kTraditionalExclusiveSample,
          preference: DocumentScriptPreference.auto,
        ),
      );
    });

    test('the declared default is hans and only a strict majority beats it', () {
      expect(kDefaultHanScript, HanScript.hans);
      expect(
        const HanScriptEvidence(hansVotes: 0, hantVotes: 0).verdict,
        HanScript.hans,
      );
      expect(
        const HanScriptEvidence(hansVotes: 7, hantVotes: 7).verdict,
        HanScript.hans,
      );
      expect(
        const HanScriptEvidence(hansVotes: 7, hantVotes: 8).verdict,
        HanScript.hant,
      );
      expect(
        const HanScriptEvidence(hansVotes: 8, hantVotes: 7).verdict,
        HanScript.hans,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Chain shape.
  // ---------------------------------------------------------------------------
  group('chain shape', () {
    test('the pack table is consistent and covers both scripts once each', () {
      expect(kHanScriptPacks, hasLength(2));
      expect(
        kHanScriptPacks.map((p) => p.script).toSet(),
        HanScript.values.toSet(),
      );
      expect(kHanScriptPacks.map((p) => p.family).toSet(), hasLength(2));
      expect(kHanScriptPacks.map((p) => p.printFamily).toSet(), hasLength(2));
      expect(hanScriptPackFor(HanScript.hans).family, 'SaudoHans');
      expect(hanScriptPackFor(HanScript.hant).family, 'SaudoHant');
    });

    for (final lead in HanScript.values) {
      test('${lead.name}: the proportional chain keeps Roboto primary, emoji '
          'ahead of code, and the Han families last', () {
        final chain = bodyFontFallbackFor(lead);

        expect(chain.take(2).toList(), kBodyFontFallback);
        expect(chain.indexOf(kEmojiFont), 0);
        expect(chain.indexOf(kEmojiFont), lessThan(chain.indexOf(kCodeFont)));
        expect(chain.sublist(2), kHanFamilyNamesLeadFirst(lead));
        for (final family in <String>[kEmojiFont, kCodeFont, ...kHanFamilyNames]) {
          expect(
            chain.where((f) => f == family).length,
            1,
            reason: '$family must appear exactly once in the chain',
          );
        }
        expect(chain, isNot(contains(kBodyFont)));
      });

      test('${lead.name}: the code chain keeps the emoji family first and the '
          'Han families last', () {
        final chain = codeFontFallbackFor(lead);

        expect(chain.first, kEmojiFont);
        expect(chain, isNot(contains(kCodeFont)));
        expect(chain.sublist(1), kHanFamilyNamesLeadFirst(lead));
        for (final family in <String>[kEmojiFont, ...kHanFamilyNames]) {
          expect(chain.where((f) => f == family).length, 1);
        }
      });

      test('${lead.name}: both packs are present, so which one leads changes '
          'form and never coverage', () {
        expect(bodyFontFallbackFor(lead), containsAll(kHanFamilyNames));
        expect(codeFontFallbackFor(lead), containsAll(kHanFamilyNames));
        expect(
          bodyFontFallbackFor(lead).last,
          isNot(bodyFontFallbackFor(lead)[2]),
        );
      });
    }

    test('the resolved lead really leads', () {
      expect(bodyFontFallbackFor(HanScript.hans)[2], 'SaudoHans');
      expect(bodyFontFallbackFor(HanScript.hant)[2], 'SaudoHant');
      expect(codeFontFallbackFor(HanScript.hans)[1], 'SaudoHans');
      expect(codeFontFallbackFor(HanScript.hant)[1], 'SaudoHant');
    });

    test('the const prefixes are retained unchanged', () {
      // §5.5 keeps these as consts precisely so the DF-023/DF-024 ordering
      // tests keep protecting exactly what they protected before DF-031.
      expect(kBodyFontFallback, const <String>['TwemojiMozilla', 'CascadiaMono']);
      expect(kCodeFontFallback, const <String>['TwemojiMozilla']);
    });
  });

  // ---------------------------------------------------------------------------
  // Tile visibility (§5.6.4).
  // ---------------------------------------------------------------------------
  group('shipped-Han detection for tile visibility', () {
    test('true for a document using either pack, exclusive or shared', () {
      expect(sourceUsesShippedHan(kTraditionalExclusiveSample), isTrue);
      expect(sourceUsesShippedHan(kSimplifiedExclusiveSample), isTrue);
      expect(sourceUsesShippedHan(kSharedHanSample), isTrue);
      expect(
        sourceUsesShippedHan('Latin text with one 中 character'),
        isTrue,
        reason: 'one code point in the union is enough',
      );
    });

    test('false for English-only, empty and outside-union documents', () {
      expect(sourceUsesShippedHan(''), isFalse);
      expect(sourceUsesShippedHan('# Plain English\n\nNo Han here. 🚀 → ok'),
          isFalse);
      expect(sourceUsesShippedHan(_string(kBig5Level2OutsideUnion)), isFalse);
    });

    test('keyed on the union, not the overlap', () {
      // A document that is unambiguously Chinese but uses only pack-exclusive
      // characters must still show the control; an overlap-keyed rule would
      // hide it, which reads as a bug (§5.6.4).
      expect(sourceUsesShippedHan(kTraditionalExclusiveSample), isTrue);
      for (final codePoint in kTraditionalExclusiveSample.runes) {
        expect(
          hanScriptTableContains(kHansExclusiveRanges, codePoint),
          isFalse,
          reason: 'these are outside the overlap by construction',
        );
      }
    });
  });
}

/// Both Han family names, unordered.
final Set<String> kHanFamilyNames =
    kHanScriptPacks.map((pack) => pack.family).toSet();

/// Both Han family names with [lead] first, which is the order the chain uses.
List<String> kHanFamilyNamesLeadFirst(HanScript lead) => <String>[
  hanScriptPackFor(lead).family,
  for (final pack in kHanScriptPacks)
    if (pack.script != lead) pack.family,
];
