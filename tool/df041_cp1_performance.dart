// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:markdown_viewer/document_search.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _BenchmarkStatus('Preparing search…'));

  // Proves the progress state reached a frame before any retained measurement.
  await WidgetsBinding.instance.endOfFrame;
  final current = await html.HttpRequest.getString('df026-long.md');
  final stress = _stressFixture();

  final warmCurrent = DocumentSearchIndex.build(current);
  warmCurrent.search('section', renderedBlockCount: warmCurrent.blocks.length);
  final warmStress = DocumentSearchIndex.build(stress);
  warmStress.search('needle', renderedBlockCount: warmStress.blocks.length);

  final currentSamples = <int>[];
  for (var run = 0; run < 20; run++) {
    final watch = Stopwatch()..start();
    final index = DocumentSearchIndex.build(current);
    index.search('section', renderedBlockCount: index.blocks.length);
    watch.stop();
    currentSamples.add(watch.elapsedMicroseconds);
  }

  final stressIndexSamples = <int>[];
  final stressQuerySamples = <int>[];
  DocumentSearchIndex? lastIndex;
  DocumentSearchResult? lastStressResult;
  for (var run = 0; run < 10; run++) {
    final indexWatch = Stopwatch()..start();
    final index = DocumentSearchIndex.build(stress);
    indexWatch.stop();
    stressIndexSamples.add(indexWatch.elapsedMicroseconds);

    final queryWatch = Stopwatch()..start();
    final result = index.search(
      'needle',
      renderedBlockCount: index.blocks.length,
    );
    queryWatch.stop();
    stressQuerySamples.add(queryWatch.elapsedMicroseconds);
    lastIndex = index;
    lastStressResult = result;
  }

  final index = lastIndex!;
  final stressResult = lastStressResult!;
  final currentIndex = DocumentSearchIndex.build(current);
  final currentResult = currentIndex.search(
    'section',
    renderedBlockCount: currentIndex.blocks.length,
  );
  final evidence = <String, Object>{
    'progress_frame_before_measurement': true,
    'fixture_current_utf8_bytes': utf8.encode(current).length,
    'fixture_current_code_units': current.length,
    'fixture_stress_utf8_bytes': utf8.encode(stress).length,
    'fixture_stress_code_units': stress.length,
    'fixture_stress_expected_blocks': 10000,
    'fixture_stress_actual_blocks': index.blocks.length,
    'current_search_blocks': currentIndex.blocks.length,
    'current_logical_runs': currentIndex.logicalRunCount,
    'current_retained_text_code_units': currentIndex.retainedTextCodeUnits,
    'current_total_matches': currentResult.total,
    'current_retained_anchors': currentResult.matches.length,
    'current_repetitions': currentSamples.length,
    'current_samples_us': currentSamples,
    'current_p50_us': _percentile(currentSamples, 0.50),
    'current_p95_us': _percentile(currentSamples, 0.95),
    'stress_repetitions': stressIndexSamples.length,
    'stress_index_samples_us': stressIndexSamples,
    'stress_index_p50_us': _percentile(stressIndexSamples, 0.50),
    'stress_index_p95_us': _percentile(stressIndexSamples, 0.95),
    'stress_query_samples_us': stressQuerySamples,
    'stress_query_p50_us': _percentile(stressQuerySamples, 0.50),
    'stress_query_p95_us': _percentile(stressQuerySamples, 0.95),
    'stress_logical_runs': index.logicalRunCount,
    'stress_retained_text_code_units': index.retainedTextCodeUnits,
    'stress_total_matches': stressResult.total,
    'stress_retained_anchors': stressResult.matches.length,
  };

  final failures = <String>[];
  if (index.blocks.length != 10000) {
    failures.add('stress fixture did not parse to exactly 10,000 blocks');
  }
  if (utf8.encode(stress).length < 1024 * 1024) {
    failures.add('stress fixture is smaller than 1 MiB');
  }
  if (_percentile(currentSamples, 0.95) > 100000) {
    failures.add('current fixture p95 exceeds 100 ms');
  }
  if (_percentile(stressIndexSamples, 0.95) > 500000) {
    failures.add('stress index p95 exceeds 500 ms');
  }
  if (_percentile(stressQuerySamples, 0.95) > 150000) {
    failures.add('stress query p95 exceeds 150 ms');
  }
  evidence['failures'] = failures;
  evidence['passed'] = failures.isEmpty;

  final encoded = jsonEncode(evidence);
  html.document.body?.dataset['df041Cp1Performance'] = encoded;
  runApp(_BenchmarkStatus(failures.isEmpty ? 'PASS' : 'FAIL'));
}

class _BenchmarkStatus extends StatelessWidget {
  const _BenchmarkStatus(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(body: Center(child: Text(message))),
  );
}

String _stressFixture() {
  final buffer = StringBuffer();
  for (var index = 0; index < 10000; index++) {
    final ordinal = index.toString().padLeft(5, '0');
    switch (index % 6) {
      case 0:
        buffer.writeln(
          '## Needle heading $ordinal with deterministic long filler for the mixed-surface one-MiB performance fixture and stable top-level mapping identity',
        );
      case 1:
        buffer.writeln(
          'Needle paragraph $ordinal contains **strong text**, `inline code`, a [link label](https://example.test/$ordinal), emoji 🚀, combining cafe\u0301, and deterministic filler for stable size.',
        );
      case 2:
        buffer.writeln(
          '> Needle blockquote $ordinal contains deterministic quoted prose, **emphasis**, `code`, and enough stable filler to exercise renderer-aligned projection.',
        );
      case 3:
        buffer.writeln(
          '- Needle list item $ordinal contains deterministic list prose, a [label](https://example.test/$ordinal), and stable filler without indexing generated bullet chrome.',
        );
      case 4:
        buffer
          ..writeln(
            '| Needle $ordinal | Deterministic table filler for renderer-aligned cell boundaries and stable performance evidence |',
          )
          ..writeln('| --- | --- |');
      case 5:
        buffer
          ..writeln('```text')
          ..writeln(
            'Needle code $ordinal keeps literal whitespace and deterministic code filler for the mixed-surface fixture mapping proof.',
          )
          ..writeln('```');
    }
    buffer.writeln();
  }
  return buffer.toString();
}

int _percentile(List<int> values, double fraction) {
  final sorted = [...values]..sort();
  return sorted[((sorted.length - 1) * fraction).ceil()];
}
