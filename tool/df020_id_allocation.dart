// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

// DF-020 V-1w: document-ID allocation in a compiled web build.
//
// Verification support, not product code. Built with
// `flutter build web --release -t tool/df020_id_allocation.dart` and driven by
// test/browser/df020_id_allocation.mjs, which reads the result this publishes on
// `document.body.dataset.df020IdAllocation`.
//
// It exercises the production `DocumentIdAllocator` and
// `MarkdownDocument.fromSource` exactly as the app links them, because the
// failure it guards against - equal IDs from a millisecond web clock - exists
// only in compiled JavaScript, not on the Dart VM.

import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:markdown_viewer/document_session.dart';
import 'package:markdown_viewer/models.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _Status('Allocating document IDs…'));
  await WidgetsBinding.instance.endOfFrame;

  final result = _run();
  html.document.body?.dataset['df020IdAllocation'] = jsonEncode(result);
  runApp(_Status(result['passed'] == true ? 'PASS' : 'FAIL'));
}

Map<String, Object?> _run() {
  // One allocator for (a) and (b), as one page lifetime has one.
  final allocator = DocumentIdAllocator();

  // (a) 10,000 back-to-back allocations, each excluding everything issued so
  // far, the way an open set grows.
  final issued = <String>{};
  final aClocks = <String>{};
  var aDuplicates = 0;
  final aWatch = Stopwatch()..start();
  for (var i = 0; i < 10000; i++) {
    final id = allocator.allocate(issued);
    if (!issued.add(id)) aDuplicates++;
    aClocks.add(_clockPart(id));
  }
  aWatch.stop();

  // (b) 100 batches of 25 through `allocateBatch`, the helper intake uses, each
  // turned into a document through `fromSource`'s `id` parameter.
  var bDuplicates = 0;
  var bIdNotCarried = 0;
  var bCount = 0;
  final bClocks = <String>{};
  for (var batch = 0; batch < 100; batch++) {
    final ids = allocator.allocateBatch(25, issued);
    for (var i = 0; i < ids.length; i++) {
      final document = MarkdownDocument.fromSource(
        '# Batch $batch file $i',
        id: ids[i],
        sourceName: 'batch-$batch-$i.md',
      );
      if (document.id != ids[i]) bIdNotCarried++;
      if (!issued.add(document.id)) bDuplicates++;
      bClocks.add(_clockPart(document.id));
      bCount++;
    }
  }

  // (c1) A fresh allocator over a seeded reserved set on the real clock: legacy
  // numeric IDs of the kind earlier releases stored, and IDs in this release's
  // own shape for the current clock reading, which is exactly what the new
  // allocator's first candidates look like when it is created in the same tick.
  // Legacy IDs are plain microsecond numbers, the form `fromSource` produced
  // and earlier releases stored; a thousand distinct ones just behind now.
  final now = DateTime.now().microsecondsSinceEpoch;
  final legacy = <String>{for (var i = 0; i < 1000; i++) '${now - i}'};
  final shaped = <String>{for (var i = 0; i < 1000; i++) '$now-$i'};
  final reserved = {...legacy, ...shaped};
  final c1Allocator = DocumentIdAllocator()..reserve(reserved);
  final c1Ids = c1Allocator.allocateBatch(1000);
  final c1ReservedHits = c1Ids.where(reserved.contains).length;
  final c1Distinct = c1Ids.toSet().length;
  final c1FirstSequence = int.parse(c1Ids.first.split('-').last);

  // (c2) The same rejection made certain: a fixed clock, so every candidate is
  // known in advance, with its first hundred candidates and the legacy form of
  // the same instant reserved. The first ID issued must be the 101st candidate.
  const fixed = 1700000000000000;
  final c2Reserved = {'$fixed', for (var i = 0; i < 100; i++) '$fixed-$i'};
  final c2Allocator = DocumentIdAllocator(clock: () => fixed)
    ..reserve(c2Reserved);
  final c2Ids = c2Allocator.allocateBatch(50, {'$fixed-100'});
  final c2ReservedHits = c2Ids.where(c2Reserved.contains).length;
  final c2Expected = [for (var i = 101; i < 151; i++) '$fixed-$i'];
  final c2Exact = _listEquals(c2Ids, c2Expected);

  // (d) Control: un-allocated `fromSource` IDs created in a tight loop. This is
  // the behaviour the allocator replaces. It is reported, not passed or failed.
  final dIds = [
    for (var i = 0; i < 10000; i++) MarkdownDocument.fromSource('control').id,
  ];
  final dDistinct = dIds.toSet().length;

  final passed =
      aDuplicates == 0 &&
      issued.length == 10000 + bCount &&
      bDuplicates == 0 &&
      bIdNotCarried == 0 &&
      bCount == 2500 &&
      c1ReservedHits == 0 &&
      c1Distinct == 1000 &&
      c2ReservedHits == 0 &&
      c2Exact;

  return {
    'harness': 'df020_id_allocation',
    'userAgent': html.window.navigator.userAgent,
    'a_backToBack': {
      'allocations': 10000,
      'duplicates': aDuplicates,
      'distinctClockReadings': aClocks.length,
      'allClockReadingsWholeMilliseconds': aClocks.every(_wholeMillisecond),
      'elapsedMicroseconds': aWatch.elapsedMicroseconds,
      'first': issued.first,
    },
    'b_batches': {
      'batches': 100,
      'perBatch': 25,
      'documents': bCount,
      'duplicates': bDuplicates,
      'idNotCarriedByFromSource': bIdNotCarried,
      'distinctClockReadings': bClocks.length,
    },
    'c1_reservedRealClock': {
      'reservedLegacy': legacy.length,
      'reservedShaped': shaped.length,
      'allocations': c1Ids.length,
      'reservedHits': c1ReservedHits,
      'distinct': c1Distinct,
      'firstIssued': c1Ids.first,
      'firstSequence': c1FirstSequence,
      'note':
          'firstSequence >= 1000 means the allocator started in the seeded '
          'tick and skipped every reserved candidate',
    },
    'c2_reservedFixedClock': {
      'reserved': c2Reserved.length,
      'inUse': '$fixed-100',
      'allocations': c2Ids.length,
      'reservedHits': c2ReservedHits,
      'firstIssued': c2Ids.first,
      'exactExpectedSequence': c2Exact,
    },
    'd_controlFromSource': {
      'created': dIds.length,
      'distinct': dDistinct,
      'duplicates': dIds.length - dDistinct,
      'reportedOnly': true,
    },
    'passed': passed,
  };
}

String _clockPart(String id) => id.split('-').first;

bool _wholeMillisecond(String clock) => int.parse(clock) % 1000 == 0;

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _Status extends StatelessWidget {
  const _Status(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(body: Center(child: Text(message))),
  );
}
