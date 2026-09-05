// DF-031 CP-D1 fixture probe.
//
// Verification support, not product code. Runs the *shipping* resolver over the
// CP-D browser fixtures so the runtime evidence is anchored to what the app
// actually computes rather than to the author's assumption about which
// characters are exclusive to which pack.
//
//   dart run test/browser/df031_fixture_probe.dart
import 'dart:convert';
import 'dart:io';

import 'package:markdown_viewer/han_script.dart';
import 'package:markdown_viewer/han_script_tables.dart';
import 'package:markdown_viewer/models.dart';

void main() {
  const names = <String>[
    'traditional',
    'simplified',
    'english',
    'paste_traditional',
    'paste_simplified',
    'paste_english',
  ];
  final report = <String, Object?>{};
  for (final name in names) {
    final source = File(
      'test/browser/df031_fixtures/$name.md',
    ).readAsStringSync();
    final evidence = HanScriptEvidence.of(source);
    report[name] = <String, Object?>{
      'hansVotes': evidence.hansVotes,
      'hantVotes': evidence.hantVotes,
      'isSilent': evidence.isSilent,
      'isTied': evidence.isTied,
      'autoVerdict': resolveHanScript(source).name,
      'underHantPreference': resolveHanScript(
        source,
        preference: DocumentScriptPreference.traditionalChinese,
      ).name,
      'underHansPreference': resolveHanScript(
        source,
        preference: DocumentScriptPreference.simplifiedChinese,
      ).name,
      'sourceUsesShippedHan': sourceUsesShippedHan(source),
    };
  }
  // The regional-form comparison line must live in BOTH repertoires, otherwise
  // an override could change coverage rather than only regional form.
  const regional = '骨直者令次海每敏起花化具真值曾增黑';
  report['regionalFormLine'] = <String, Object?>{
    'text': regional,
    'inUnion': <String, bool>{
      for (final rune in regional.runes)
        String.fromCharCode(rune): hanScriptTableContains(
          kHanUnionRanges,
          rune,
        ),
    },
    'hansExclusive': <String>[
      for (final rune in regional.runes)
        if (hanScriptTableContains(kHansExclusiveRanges, rune))
          String.fromCharCode(rune),
    ],
    'hantExclusive': <String>[
      for (final rune in regional.runes)
        if (hanScriptTableContains(kHantExclusiveRanges, rune))
          String.fromCharCode(rune),
    ],
  };
  report['printProbes'] = <String, String>{
    for (final entry in kHanPrintProbesForReport.entries)
      entry.key: entry.value,
  };
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
}

const Map<String, String> kHanPrintProbesForReport = <String, String>{
  'hans': '汉',
  'hant': '漢',
};
