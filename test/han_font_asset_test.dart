import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/han_script.dart';
import 'package:markdown_viewer/print_fonts.dart';

import 'support/opentype.dart';

/// DF-031 CP-A — the successor to the DF-024 guardrail
/// **`no new font binary is introduced`**.
///
/// That rule asserted the `.ttf` files in `fonts/` were exactly the five
/// baseline paths, stating "DF-024 adds, removes, subsets and regenerates
/// nothing". It was correct for DF-024 and **any** DF-031 implementation breaks
/// it, because DF-031 ships two derived Han subsets. Human Authority authorized
/// **replacing** it, never merely deleting it (`plan.md` §1.5 H8, §10).
///
/// This group is that replacement, and it is strictly stronger on every axis
/// (`plan.md` §10.1). Where the retired rule globbed one extension and counted
/// to five, this asserts the whole `fonts/` listing, the pinned upstream inputs,
/// the shipped digests and byte lengths, the realised repertoire of each
/// derivative read from every Unicode `cmap` subtable, the drop set that
/// explains requested-minus-realised, disjointness from the baseline union
/// computed from the same binaries it pins, the licence and notice identity,
/// the derivative `name` records, and the Reserved Font Name state.
///
/// Two things are deliberate and worth stating so they are not read as gaps:
///
/// * **The digest assertions live here, not only in the generation tool**
///   (`plan.md` §10.2). The tool runs when someone regenerates the fonts, which
///   is exactly the occasion on which the bytes are *expected* to change, so it
///   can never catch the case these properties exist to catch — a shipped
///   binary drifting from its pinned identity between regenerations.
/// * **CP-A ships no Viewer or print declarations yet.** Property 11 of §10.1 —
///   inventory consistency across `pubspec.yaml`, the Viewer family
///   configuration and the two print inventories — is therefore asserted here
///   only over the declarations that actually exist at this checkpoint. CP-B
///   and CP-C extend it when their real declarations land. No placeholder
///   declaration is invented to make a future check look satisfied.

// ---------------------------------------------------------------------------
// The approved CP-A `fonts/` inventory. Property 1 asserts the *entire*
// directory listing equals this set - not an extension-filtered glob. The
// retired rule globbed `.ttf` only and would not have caught a stray `.otf`;
// enumerating `.ttf` and `.otf` would merely have moved the hole to `.woff2`,
// so the whole listing is asserted and the class is closed.
// ---------------------------------------------------------------------------
const List<String> kApprovedFontsDirectory = <String>[
  'CascadiaMono-LICENSE.txt',
  'CascadiaMono.ttf',
  'Roboto-Bold.ttf',
  'Roboto-Italic.ttf',
  'Roboto-LICENSE.txt',
  'Roboto-Regular.ttf',
  'SaudoHans-LICENSE.txt',
  'SaudoHans-NOTICE.txt',
  'SaudoHans-Regular.otf',
  'SaudoHant-LICENSE.txt',
  'SaudoHant-NOTICE.txt',
  'SaudoHant-Regular.otf',
  'TwemojiMozilla-LICENSE.txt',
  'TwemojiMozilla.ttf',
];

/// The five baseline faces. The disjointness property computes their union from
/// these exact binaries rather than trusting a hard-coded total.
const List<String> kBaselineFaces = <String>[
  'fonts/Roboto-Regular.ttf',
  'fonts/Roboto-Italic.ttf',
  'fonts/Roboto-Bold.ttf',
  'fonts/CascadiaMono.ttf',
  'fonts/TwemojiMozilla.ttf',
];

/// `plan.md` §3.5 - re-derived from the five real Source binaries.
const int kBaselineUnionSize = 3048;

/// DF-024's ordering-risk set, retained exactly (§10.1 property 10). The Han
/// families must not touch any of these.
const List<int> kOrderingRiskCodePoints = <int>[
  0x2194, 0x2195, 0x25AA, 0x25AB, 0x25B6, 0x25C0, 0x25FB, 0x25FC, 0x25FD,
  0x25FE, 0x263A, 0x2640, 0x2642, 0x2660, 0x2663, 0x2665, 0x2666, 0x2B1B,
  0x2B1C,
];

// ---------------------------------------------------------------------------
// Pinned provenance (`plan.md` §9.2.1). One source identity supplies the
// binaries and the governing licence; `google/fonts` is a different
// distribution identity and is explicitly outside this chain (§9.2.3).
// ---------------------------------------------------------------------------
const String kUpstreamProject = 'notofonts/noto-cjk';
const String kUpstreamTag = 'Sans2.004';
const String kUpstreamCommit = '523d033d6cb47f4a80c58a35753646f5c3608a78';
const String kGoverningLicencePath = 'LICENSE';
const String kGoverningLicenceSha256 =
    '6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2';
const int kGoverningLicenceBytes = 4301;
const String kLicenceIdentity = 'SIL Open Font License 1.1';

/// `plan.md` §9.1 step 5, established at CP-A against the exact pinned licence.
///
/// The governing file declares no copyright statement and therefore declares no
/// Reserved Font Name. This is recorded literally, as the plan requires: an
/// absent RFN is a valid outcome and must not be replaced by an assumed,
/// inherited or reconstructed one. The phrase "Reserved Font Name" does occur
/// in that file, but only in the OFL's own *definition* clause, which is not a
/// declared RFN.
const String kDeclaredRfnState = 'none declared';

/// The RFN declared by the upstream *lineage* (Adobe Source Han Sans). Whether
/// it reaches downstream derivatives of the Noto build is legally unresolved and
/// is deliberately left unresolved (`plan.md` §9.2.4). The check is retained as
/// a conservative technical invariant, not as a legal conclusion (§9.2.5): it
/// costs nothing, already passes, and converts an open question into an asserted
/// repository property.
const String kLineageReservedName = 'Source';

/// `name` IDs rewritten to the derivative identity, and those retained from
/// upstream (`plan.md` §5.3, §10.1 property 12).
const List<int> kRewrittenNameIds = <int>[1, 3, 4, 6];
const List<int> kRetainedNameIds = <int>[0, 2, 5, 7, 8, 9, 10, 11, 12, 13, 14];

class HanFont {
  const HanFont({
    required this.family,
    required this.postScriptName,
    required this.uniqueId,
    required this.asset,
    required this.licence,
    required this.notice,
    required this.bytes,
    required this.sha256,
    required this.upstreamPath,
    required this.upstreamSha256,
    required this.upstreamBytes,
    required this.realisedRepertoire,
    required this.dropCount,
    required this.standardSet,
    required this.standardSize,
  });

  final String family;
  final String postScriptName;
  final String uniqueId;
  final String asset;
  final String licence;
  final String notice;
  final int bytes;
  final String sha256;
  final String upstreamPath;
  final String upstreamSha256;
  final int upstreamBytes;
  final int realisedRepertoire;
  final int dropCount;
  final String standardSet;
  final int standardSize;

  String get repertoireManifest => 'tool/fonts/manifests/$family-repertoire.txt';
  String get dropManifest => 'tool/fonts/manifests/$family-drops.txt';
}

/// The shipped identities, measured at CP-A.
///
/// These are **not** the Planning-measured digests. The §5.3 identity rewrite of
/// `name` IDs 1/3/4/6 changes the bytes by design, so the Planning figures
/// (1,764,540 B and 1,589,440 B) are not the shipped ones. `plan.md` §12 CP-A
/// evidence item 3 states this in advance so a digest difference is not later
/// mistaken for a defect.
const List<HanFont> kHanFonts = <HanFont>[
  HanFont(
    family: 'SaudoHans',
    postScriptName: 'SaudoHans-Regular',
    uniqueId: '2.004;DF031;SaudoHans-Regular;src-faa6c9df652116dd',
    asset: 'fonts/SaudoHans-Regular.otf',
    licence: 'fonts/SaudoHans-LICENSE.txt',
    notice: 'fonts/SaudoHans-NOTICE.txt',
    bytes: 1764560,
    sha256: '9d2fcb44a083b4c2dfa5de7a1607e87f293798f65b6034f8e7ad027dc6bf18cb',
    upstreamPath: 'Sans/SubsetOTF/SC/NotoSansSC-Regular.otf',
    upstreamSha256:
        'faa6c9df652116dde789d351359f3d7e5d2285a2b2a1f04a2d7244df706d5ea9',
    upstreamBytes: 8331336,
    realisedRepertoire: 7094,
    dropCount: 16,
    standardSet: 'GB 2312 Level 1 + Level 2',
    standardSize: 6763,
  ),
  HanFont(
    family: 'SaudoHant',
    postScriptName: 'SaudoHant-Regular',
    uniqueId: '2.004;DF031;SaudoHant-Regular;src-5bab0cb3c1cf89dd',
    asset: 'fonts/SaudoHant-Regular.otf',
    licence: 'fonts/SaudoHant-LICENSE.txt',
    notice: 'fonts/SaudoHant-NOTICE.txt',
    bytes: 1589456,
    sha256: 'e49f1a8794c86369187fef2277c2a9b0543e19097501e37282656fce8a344af9',
    upstreamPath: 'Sans/SubsetOTF/TC/NotoSansTC-Regular.otf',
    upstreamSha256:
        '5bab0cb3c1cf89dde07c4a95a4054b195afbcfe784d69d75c340780712237537',
    upstreamBytes: 5683368,
    realisedRepertoire: 5820,
    dropCount: 19,
    standardSet: 'Big5 Level 1',
    standardSize: 5401,
  ),
];

/// Cross-face figures, re-derived from the shipped binaries (`plan.md` §3.6).
const int kUnionSize = 9199;
const int kOverlapSize = 3715;

String _sha256Of(String path) => sha256.convert(File(path).readAsBytesSync()).toString();

OpenTypeFont _load(String path) =>
    OpenTypeFont.parse(File(path).readAsBytesSync());

Set<int> _manifestCodePoints(String path) => File(path)
    .readAsLinesSync()
    .where((line) => line.startsWith('U+'))
    .map((line) => int.parse(line.substring(2), radix: 16))
    .toSet();

Map<int, String> _dropSet(String path) {
  final drops = <int, String>{};
  for (final line in File(path).readAsLinesSync()) {
    if (!line.startsWith('U+')) continue;
    final parts = line.split('\t');
    drops[int.parse(parts[0].substring(2), radix: 16)] = parts[1];
  }
  return drops;
}

Set<int> _baselineUnion() {
  final union = <int>{};
  for (final path in kBaselineFaces) {
    union.addAll(_load(path).cmapCoverage.codePoints);
  }
  return union;
}

void main() {
  group('DF-031 bundled Han font assets', () {
    // -----------------------------------------------------------------------
    // Property 1 - approved asset set.
    // -----------------------------------------------------------------------
    test('the fonts/ directory listing is exactly the approved set', () {
      final onDisk =
          Directory('fonts').listSync().map((e) => e.uri.pathSegments.last).toList()
            ..sort();
      expect(
        onDisk,
        kApprovedFontsDirectory,
        reason:
            'the whole fonts/ listing is asserted, not an extension-filtered '
            'glob - a stray binary of any extension is a failure',
      );
    });

    // -----------------------------------------------------------------------
    // Property 3 - shipped output identity: digest AND byte length.
    // -----------------------------------------------------------------------
    for (final font in kHanFonts) {
      test('${font.family} matches its pinned digest and byte length', () {
        final file = File(font.asset);
        expect(file.existsSync(), isTrue, reason: '${font.asset} must exist');
        expect(
          file.lengthSync(),
          font.bytes,
          reason: '${font.asset} byte length is pinned',
        );
        expect(
          _sha256Of(font.asset),
          font.sha256,
          reason:
              '${font.asset} must match its pinned SHA-256. A font cannot be '
              'silently swapped, re-subsetted, re-ordered or corrupted; '
              'regenerating deliberately means updating this pin in the same '
              'change (plan.md §10.2 - this is not downgradable to byte length '
              'plus a repertoire manifest)',
        );
      });
    }

    // -----------------------------------------------------------------------
    // Property 2 - pinned upstream input identity, agreeing with the NOTICE.
    // -----------------------------------------------------------------------
    for (final font in kHanFonts) {
      test('${font.family} NOTICE records the pinned upstream input', () {
        final notice = File(font.notice).readAsStringSync();
        for (final fact in <String>[
          kUpstreamProject,
          kUpstreamTag,
          kUpstreamCommit,
          font.upstreamPath,
          font.upstreamSha256,
          '${font.upstreamBytes}',
          kGoverningLicenceSha256,
          kLicenceIdentity,
          'RFN: $kDeclaredRfnState',
          font.sha256,
          font.family,
          font.postScriptName,
        ]) {
          expect(
            notice,
            contains(fact),
            reason: '${font.notice} must record the provenance fact "$fact"',
          );
        }
      });
    }

    // -----------------------------------------------------------------------
    // Property 8 - licence and notice identity and presence.
    // -----------------------------------------------------------------------
    test('every bundled font ships its licence file', () {
      for (final path in <String>[
        'fonts/Roboto-LICENSE.txt',
        'fonts/CascadiaMono-LICENSE.txt',
        'fonts/TwemojiMozilla-LICENSE.txt',
        'fonts/SaudoHans-LICENSE.txt',
        'fonts/SaudoHant-LICENSE.txt',
      ]) {
        expect(File(path).existsSync(), isTrue, reason: '$path must exist');
      }
    });

    for (final font in kHanFonts) {
      test('${font.family} licence copy is byte-identical to the pinned '
          'governing $kGoverningLicencePath', () {
        final file = File(font.licence);
        expect(file.existsSync(), isTrue);
        expect(
          file.lengthSync(),
          kGoverningLicenceBytes,
          reason: '${font.licence} must be the exact pinned governing licence',
        );
        expect(
          _sha256Of(font.licence),
          kGoverningLicenceSha256,
          reason:
              '${font.licence} must be a byte-identical copy of the governing '
              'licence of the selected provenance chain - $kUpstreamProject @ '
              '$kUpstreamTag ($kUpstreamCommit) root $kGoverningLicencePath. '
              'This is an identity invariant, not a presence test. No '
              'differently-provenanced OFL text may be substituted: the '
              'google/fonts ofl/notosanssc/OFL.txt is a different distribution '
              'identity and is outside this chain (plan.md §9.1 step 1, §9.2.3)',
        );
        expect(File(font.notice).existsSync(), isTrue,
            reason: '${font.notice} must accompany the derived font');
      });
    }

    test('the derivation notice is a separate file from the licence text', () {
      // Kept apart deliberately, so the OFL text is never presented as
      // reconstructed or annotated (plan.md §9, Independent Review F3).
      for (final font in kHanFonts) {
        final licence = File(font.licence).readAsStringSync();
        expect(licence, contains('SIL OPEN FONT LICENSE Version 1.1'));
        expect(
          licence.contains(kUpstreamCommit),
          isFalse,
          reason: 'provenance belongs in ${font.notice}, not in the licence text',
        );
      }
    });

    // -----------------------------------------------------------------------
    // Properties 12, 13, 14, 15 - derivative name-table identity and RFN state.
    // -----------------------------------------------------------------------
    for (final font in kHanFonts) {
      test('${font.family} carries the approved derivative name identity', () {
        final records = _load(font.asset).nameRecords;
        expect(records, isNotEmpty);

        String only(int id) {
          final values =
              records.where((r) => r.nameId == id).map((r) => r.value).toSet();
          expect(values, hasLength(1),
              reason: 'name ID $id must be one consistent value across every '
                  'platform and language record, so a localized upstream family '
                  'name cannot survive the rewrite');
          return values.single;
        }

        expect(only(1), font.family, reason: 'name ID 1 - family');
        expect(only(3), font.uniqueId, reason: 'name ID 3 - unique identifier');
        expect(only(4), font.family, reason: 'name ID 4 - full name');
        expect(only(6), font.postScriptName, reason: 'name ID 6 - PostScript');

        // The rewritten records must carry no upstream family string.
        for (final id in kRewrittenNameIds) {
          for (final record in records.where((r) => r.nameId == id)) {
            expect(record.value.contains('Noto'), isFalse,
                reason: 'the derivative identity must not carry the upstream '
                    'family name: $record');
          }
        }

        // Retained records. IDs 0, 13 and 14 carry the Adobe copyright, the OFL
        // grant and the OFL URL, which the OFL requires to travel with the Font
        // Software. ID 7 keeps the upstream trademark notice because it is a
        // true statement about what this is derived from. IDs 2, 5, 8-12 keep
        // crediting Adobe and its designers and keep recording the upstream
        // build version and vendor URL - deliberate for a derivative, not an
        // oversight (plan.md §5.3).
        final present = records.map((r) => r.nameId).toSet();
        for (final id in kRetainedNameIds) {
          expect(present, contains(id), reason: 'name ID $id must be retained');
        }
        expect(only(0), contains('Adobe'));
        expect(only(13), contains('SIL Open Font License'));
        expect(only(14), 'http://scripts.sil.org/OFL');
        expect(only(5), contains('2.004'),
            reason: 'ID 5 continues to record the upstream build version');
      });

      test('${font.family} whole name table satisfies the RFN state', () {
        final values = _load(font.asset).nameRecords.map((r) => r.value).toList();
        expect(values, isNotEmpty);

        // Property 13 - the actual RFN state, asserted with a defined subject
        // rather than failing or vacuously passing for want of one.
        expect(kDeclaredRfnState, 'none declared',
            reason:
                'the governing licence pinned by this suite declares no '
                'Reserved Font Name. If a future pin declares one, update this '
                'constant and the conditional enforcement below takes effect');

        // Property 14 - conditional enforcement. With no declared RFN the
        // whole-table prohibition is `not applicable`: it is neither silently
        // skipped nor reported as a pass.
        if (kDeclaredRfnState != 'none declared') {
          for (final value in values) {
            expect(value.contains(kDeclaredRfnState), isFalse,
                reason: 'the declared RFN "$kDeclaredRfnState" must appear '
                    'nowhere in the name table');
          }
        }

        // Property 15 - the conservative lineage invariant, run in both cases.
        final hits =
            values.where((v) => v.contains(kLineageReservedName)).toList();
        expect(
          hits,
          isEmpty,
          reason:
              'the string "$kLineageReservedName" - the RFN declared by the '
              'upstream Adobe Source Han Sans lineage - must appear zero times '
              'in the complete name table. Whether that lineage RFN reaches '
              'this derivative is legally unresolved and deliberately left so; '
              'this assertion is containment, not a legal conclusion '
              '(plan.md §9.2.4, §9.2.5)',
        );
      });
    }

    // -----------------------------------------------------------------------
    // Properties 4, 5, 7 - realised repertoire, drop set, all cmap formats.
    // -----------------------------------------------------------------------
    for (final font in kHanFonts) {
      test('${font.family} cmap equals its committed realised manifest', () {
        final coverage = _load(font.asset).cmapCoverage;
        final manifest = _manifestCodePoints(font.repertoireManifest);

        expect(coverage.codePoints, hasLength(font.realisedRepertoire));
        expect(manifest, hasLength(font.realisedRepertoire));
        expect(
          coverage.codePoints,
          manifest,
          reason:
              'the committed manifest is the *realised* cmap; the requested '
              'repertoire differs and the difference is explained by '
              '${font.dropManifest}',
        );
      });

      test('${font.family} repertoire is read from every Unicode cmap subtable',
          () {
        final coverage = _load(font.asset).cmapCoverage;
        expect(coverage.formats, isNotEmpty,
            reason: 'at least one Unicode cmap subtable must be present');

        // The measured subsets have no format-14 subtable. That is asserted as
        // a fact to be checked, not assumed, so a future regeneration that
        // introduces UVS coverage cannot slip past a disjointness check that
        // never looked (plan.md §10.1 property 7).
        expect(
          coverage.formats.contains(14),
          isFalse,
          reason: 'no format-14 (UVS) subtable is expected in ${font.asset}; '
              'if one appears, the disjointness assertions below must be '
              're-derived to account for its coverage',
        );
        expect(coverage.variationSequences, 0);
      });

      test('${font.family} drop set explains requested minus realised', () {
        final drops = _dropSet(font.dropManifest);
        expect(drops, hasLength(font.dropCount));

        // Each entry carries a reason. Without this the "cmap equals manifest"
        // assertion would fail on its first run for a reason nothing in the
        // repository explains (plan.md §5.2, §10.1 property 5).
        const allowedReasons = <String>{
          'unassigned in Unicode',
          'dropped by the subsetter',
        };
        final upstreamAbsent = 'absent from ${font.upstreamPath.split('/').last}';
        for (final entry in drops.entries) {
          expect(
            allowedReasons.contains(entry.value) || entry.value == upstreamAbsent,
            isTrue,
            reason: 'U+${entry.key.toRadixString(16).toUpperCase()} has an '
                'unrecognised drop reason "${entry.value}"',
          );
        }

        // A dropped code point must genuinely be absent from the shipped font.
        final coverage = _load(font.asset).cmapCoverage;
        for (final cp in drops.keys) {
          expect(coverage.codePoints.contains(cp), isFalse);
        }
      });
    }

    // -----------------------------------------------------------------------
    // Property 6 - disjointness from the identity-pinned baseline union.
    // -----------------------------------------------------------------------
    test('the baseline union is re-derived from the five pinned faces', () {
      final union = _baselineUnion();
      expect(
        union,
        hasLength(kBaselineUnionSize),
        reason:
            'the union is computed from the same binaries the digest property '
            'pins, never from a hard-coded number',
      );
    });

    for (final font in kHanFonts) {
      test('${font.family} is disjoint from the bundled baseline union', () {
        final union = _baselineUnion();
        final overlap = _load(font.asset).cmapCoverage.codePoints.intersection(union);
        expect(
          overlap,
          isEmpty,
          reason:
              'this is the §3.5 property that makes the Han families unable to '
              'displace Roboto, Twemoji or Cascadia *from any position* in the '
              'fallback chain. Ordering becomes defence in depth rather than '
              'the sole guarantee; losing it silently regresses DF-023/DF-024',
        );
      });

      // Property 10 - the 19 ordering-risk assertions, retained exactly.
      test('${font.family} touches none of the 19 ordering-risk code points',
          () {
        expect(kOrderingRiskCodePoints, hasLength(19));
        final overlap = _load(font.asset)
            .cmapCoverage
            .codePoints
            .intersection(kOrderingRiskCodePoints.toSet());
        expect(
          overlap,
          isEmpty,
          reason:
              'the 19 code points reachable from both TwemojiMozilla and '
              'Cascadia Mono must stay reachable from exactly those two, in '
              'that order. A full Noto CJK face would have covered 12 of them '
              'and silently regressed DF-024; the subsets cover none',
        );
      });
    }

    test('the two Han repertoires meet the pinned cross-face figures', () {
      final hans = _load(kHanFonts[0].asset).cmapCoverage.codePoints;
      final hant = _load(kHanFonts[1].asset).cmapCoverage.codePoints;
      expect(hans.union(hant), hasLength(kUnionSize));
      expect(hans.intersection(hant), hasLength(kOverlapSize));
    });

    // -----------------------------------------------------------------------
    // Property 11 - inventory consistency, over the declarations that exist.
    // -----------------------------------------------------------------------
    // REPLACED AT CP-B, as the test it replaces said it would be.
    //
    // The CP-A test here asserted that no Han family was declared *anywhere* -
    // not in pubspec.yaml and not in lib/ - because at CP-A the assets were
    // bundled and unwired, and inventing placeholder declarations to satisfy a
    // cross-inventory check would have been dishonest. Its own comment named
    // CP-B and CP-C as the checkpoints that "replace this test with the positive
    // cross-inventory assertion", and CP-B cannot both wire the fonts and leave
    // it standing. This is that replacement, and it is strictly stronger: the
    // negative form would pass a build that declared nothing at all.
    //
    // Three of the five inventories property 11 names are in CP-B scope: the
    // approved asset set, the `pubspec.yaml` `fonts:` block, and
    // `kHanScriptPacks`. The print `@font-face` rules and `_loadPrintFonts`'
    // load/probe inventory are CP-C, and are asserted absent here for the same
    // reason CP-A asserted all five absent - so this property stays truthful at
    // this checkpoint rather than anticipating work that has not happened.
    test('the Viewer inventories agree: assets, pubspec and kHanScriptPacks', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();

      expect(
        kHanScriptPacks.map((pack) => pack.family).toSet(),
        kHanFonts.map((font) => font.family).toSet(),
        reason:
            'the pack table and the approved asset set must name the same two '
            'families - a pack with no asset, or an asset with no pack, is the '
            'drift this property exists to catch',
      );

      for (final pack in kHanScriptPacks) {
        final font = kHanFonts.firstWhere((f) => f.family == pack.family);

        expect(
          pack.asset,
          font.asset,
          reason: '${pack.family} must point at the pinned asset path',
        );
        expect(
          File(pack.asset).existsSync(),
          isTrue,
          reason: '${pack.asset} must exist at the path the pack declares',
        );
        expect(
          pubspec.contains('family: ${pack.family}'),
          isTrue,
          reason: '${pack.family} must be declared in the pubspec fonts: block',
        );
        expect(
          pubspec.contains('asset: ${pack.asset}'),
          isTrue,
          reason:
              '${pack.asset} must be the asset pubspec registers for '
              '${pack.family} - the pack table and the manifest must not drift',
        );
      }
    });

    // REPLACED AT CP-C, as the test it replaces said it would be.
    //
    // The CP-B test asserted the print `@font-face` inventory was *absent*,
    // because print parity was CP-C and inventing declarations to satisfy a
    // cross-inventory check would have been dishonest. Its own comment named
    // CP-C as the checkpoint that "replaces this with the print half of the
    // cross-inventory assertion". This is that replacement, and it is strictly
    // stronger: the negative form now passes vacuously, since the declarations
    // live in `lib/print_fonts.dart` rather than in the surface it read.
    test('the print inventories agree: kPrintFontFaces, kHanScriptPacks and '
        'the shipped assets', () {
      for (final pack in kHanScriptPacks) {
        final face = kPrintFontFaces.singleWhere(
          (face) => face.family == pack.printFamily,
          orElse: () => fail(
            '${pack.printFamily} must have exactly one print @font-face',
          ),
        );
        expect(
          face.assetUrl,
          '/assets/${pack.asset}',
          reason: 'the print rule must serve the asset the pack declares',
        );
        expect(File(pack.asset).existsSync(), isTrue);
        expect(
          buildPrintCss(kDefaultHanScript),
          contains('src: url("${face.assetUrl}") format("opentype");'),
          reason:
              'the two derivatives carry CFF outlines, so the format hint is '
              'opentype rather than the truetype the five DF-026 rules use',
        );
      }
      expect(
        kPrintFontFaces.map((face) => face.family).toSet(),
        containsAll(kHanScriptPacks.map((pack) => pack.printFamily)),
      );
    });

    test('the print surface declares no font inventory of its own', () {
      // One inventory, not two lists that can drift: the surface consumes
      // `kPrintFontFaces` and neither restates a family nor counts faces.
      final printSurface = File(
        'lib/print_surface_web.dart',
      ).readAsStringSync();

      expect(printSurface, contains('kPrintFontFaces'));
      expect(printSurface, contains('printFontsAreReady'));
      for (final pack in kHanScriptPacks) {
        expect(
          printSurface.contains(pack.printFamily),
          isFalse,
          reason:
              '${pack.printFamily} must be declared once, in the inventory, '
              'not restated in the surface',
        );
        expect(
          printSurface.contains(pack.family),
          isFalse,
          reason: 'the Viewer family ${pack.family} is not a print declaration',
        );
      }
      expect(
        RegExp(r'loadedFaces\.length != \d').hasMatch(printSurface),
        isFalse,
        reason:
            'the hard-coded face count was named as a fail-closed hazard and '
            'is replaced by a count derived from the declared inventory',
      );
    });

    test('each Han print probe is carried only by the face it proves', () {
      // What stops a `FontFaceSet.check` passing against the wrong face. Read
      // from the shipped binaries themselves rather than from the generated
      // tables, so this holds even if the tables and the fonts ever disagree.
      final coverage = <HanScript, Set<int>>{
        for (final pack in kHanScriptPacks)
          pack.script: _load(pack.asset).cmapCoverage.codePoints,
      };
      final baseline = _baselineUnion();

      for (final pack in kHanScriptPacks) {
        final probe = kHanPrintProbes[pack.script]!;
        final codePoint = probe.runes.single;

        expect(
          coverage[pack.script]!.contains(codePoint),
          isTrue,
          reason:
              '$probe must be in ${pack.family}\'s realised cmap, or the probe '
              'could never pass',
        );
        for (final other in kHanScriptPacks) {
          if (other.script == pack.script) continue;
          expect(
            coverage[other.script]!.contains(codePoint),
            isFalse,
            reason:
                'a probe both faces carried would report ready for a face '
                'that never arrived',
          );
        }
        expect(
          baseline.contains(codePoint),
          isFalse,
          reason:
              'no baseline face carries it either, so a passing check names '
              'exactly this face',
        );
      }
    });

    // -----------------------------------------------------------------------
    // The generation tooling is a regeneration step, not a build or runtime one.
    // -----------------------------------------------------------------------
    test('the generation tool is committed and stays out of the build', () {
      expect(File('tool/fonts/build_han_subsets.py').existsSync(), isTrue);
      expect(File('tool/fonts/requirements.txt').existsSync(), isTrue,
          reason: 'the fontTools version is pinned alongside the tool');
      for (final path in <String>[
        'tool/fonts/cldr/cldr-zh.xml',
        'tool/fonts/cldr/cldr-zh-Hant.xml',
      ]) {
        expect(File(path).existsSync(), isTrue,
            reason: '$path is a pinned repertoire input and must be committed');
      }
      expect(
        File('tool/build_web.ps1').readAsStringSync().contains('build_han_subsets'),
        isFalse,
        reason:
            'font generation is a regeneration step, deliberately not wired '
            'into the build (plan.md §9)',
      );
    });

    test('the committed identity record agrees with the shipped fonts', () {
      final identity = jsonDecode(
        File('tool/fonts/manifests/font-identity.json').readAsStringSync(),
      ) as Map<String, dynamic>;

      final upstream = identity['upstream'] as Map<String, dynamic>;
      expect(upstream['project'], kUpstreamProject);
      expect(upstream['tag'], kUpstreamTag);
      expect(upstream['commit'], kUpstreamCommit);
      expect(upstream['licence_path'], kGoverningLicencePath);
      expect(upstream['licence_sha256'], kGoverningLicenceSha256);
      expect(upstream['licence_identity'], kLicenceIdentity);
      expect(upstream['rfn_state'], kDeclaredRfnState);
      expect(identity['baseline_union'], kBaselineUnionSize);
      expect(identity['union'], kUnionSize);
      expect(identity['overlap'], kOverlapSize);

      final faces = identity['faces'] as Map<String, dynamic>;
      for (final font in kHanFonts) {
        final face = faces.values.firstWhere(
          (f) => (f as Map<String, dynamic>)['family'] == font.family,
        ) as Map<String, dynamic>;
        expect(face['sha256'], font.sha256);
        expect(face['bytes'], font.bytes);
        expect(face['realised'], font.realisedRepertoire);
        expect(face['dropped'], font.dropCount);
        expect(face['upstream_sha256'], font.upstreamSha256);
        expect(face['standard_set'], font.standardSet);
        expect(face['standard_covered'], font.standardSize,
            reason: '${font.family} claims 100% of ${font.standardSet}');
        expect(face['standard_size'], font.standardSize);
        expect(face['baseline_intersection'], 0);
        expect(face['uvs_subtable_present'], isFalse);
      }
    });
  });
}
