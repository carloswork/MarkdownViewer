// The StorageBackend contract, C1-C8 (DF-020 plan §5.10), as executable checks.
//
// Pure Dart with no test-framework dependency, so the same checks run on the VM
// against the fake (V-8c) and compiled into the web harness against the
// production IndexedDB backend in three engines (V-22). A check throws
// [ContractViolation] on failure.

import 'dart:async';

import 'package:markdown_viewer/storage/storage_backend.dart';

class ContractViolation implements Exception {
  ContractViolation(this.message);
  final String message;
  @override
  String toString() => 'ContractViolation: $message';
}

void _check(bool condition, String message) {
  if (!condition) throw ContractViolation(message);
}

/// Ways to provoke the outcomes the contract defines, supplied per backend.
class ContractHooks {
  const ContractHooks({
    required this.reopen,
    required this.failNextWrite,
    required this.failNextDelete,
    required this.nextWriteIndeterminateButApplied,
    this.unavailable,
  });

  /// A new backend over the same durable storage: what a later app start sees.
  final Future<StorageBackend> Function() reopen;

  /// Makes the next write of [key] fail without taking effect.
  final FutureOr<void> Function(String key) failNextWrite;

  /// Makes the next delete of [key] fail without taking effect.
  final FutureOr<void> Function(String key) failNextDelete;

  /// Makes the next write of [key] report indeterminate although it takes
  /// effect - a timed-out write that commits late.
  final FutureOr<void> Function(String key) nextWriteIndeterminateButApplied;

  /// A backend for storage that cannot be reached, if the platform has one.
  final StorageBackend Function()? unavailable;
}

class ContractCheck {
  const ContractCheck(this.id, this.name, this.run);
  final String id;
  final String name;
  final Future<void> Function() run;
}

/// The C1-C8 checks against [backend], using keys under [prefix] only.
List<ContractCheck> storageContractChecks(
  StorageBackend backend,
  ContractHooks hooks, {
  String prefix = 'df020-contract',
}) {
  String key(String name) => '$prefix-$name';

  Future<StorageRead> readBack(String k) => backend.read(k);

  return [
    ContractCheck(
      'C1',
      'a committed write is observed by a later start',
      () async {
        final k = key('c1');
        _check(
          await backend.write(k, 'one') == StorageOutcome.committed,
          'write not committed',
        );
        final later = await hooks.reopen();
        final read = await later.read(k);
        _check(
          read.kind == StorageReadKind.value && read.value == 'one',
          'a later start read $read',
        );
      },
    ),
    ContractCheck('C1', 'a failed write did not happen', () async {
      final k = key('c1-failed');
      _check(
        await backend.write(k, 'before') == StorageOutcome.committed,
        'seed write not committed',
      );
      await hooks.failNextWrite(k);
      final outcome = await backend.write(k, 'after');
      _check(outcome == StorageOutcome.failed, 'outcome was $outcome');
      final read = await readBack(k);
      _check(read.value == 'before', 'read after a failed write: $read');
    }),
    ContractCheck('C2', 'reads observe every returned outcome', () async {
      final k = key('c2');
      await backend.write(k, 'x');
      _check((await readBack(k)).value == 'x', 'write not observed');
      _check(
        await backend.delete(k) == StorageOutcome.committed,
        'delete not committed',
      );
      _check(
        (await readBack(k)).kind == StorageReadKind.absent,
        'delete not observed',
      );
    }),
    ContractCheck('C3', 'delete is unconditional and idempotent', () async {
      final k = key('c3');
      _check(
        await backend.delete(k) == StorageOutcome.committed,
        'deleting an absent key is not committed',
      );
      await backend.write(k, 'x');
      await hooks.failNextDelete(k);
      _check(
        await backend.delete(k) == StorageOutcome.failed,
        'an injected delete failure was not reported',
      );
      _check((await readBack(k)).value == 'x', 'a failed delete took effect');
      // The Retry: a real deletion is issued again, whatever came before.
      _check(
        await backend.delete(k) == StorageOutcome.committed,
        'the retried delete was not committed',
      );
      _check(
        (await readBack(k)).kind == StorageReadKind.absent,
        'the retried delete did not remove the key',
      );
      _check(
        await backend.delete(k) == StorageOutcome.committed,
        'a second delete of the absent key was not committed',
      );
    }),
    ContractCheck('C4', 'a write replaces one value whole', () async {
      final k = key('c4');
      final other = key('c4-other');
      await backend.write(other, 'untouched');
      await backend.write(k, 'a long first value ' * 50);
      await backend.write(k, 'short');
      _check((await readBack(k)).value == 'short', 'value not replaced whole');
      _check(
        (await readBack(other)).value == 'untouched',
        'another key changed',
      );
    }),
    ContractCheck('C5', 'sequential use stays consistent', () async {
      final k = key('c5');
      for (var i = 0; i < 20; i++) {
        _check(
          await backend.write(k, 'v$i') == StorageOutcome.committed,
          'write $i not committed',
        );
        _check((await readBack(k)).value == 'v$i', 'read $i inconsistent');
      }
    }),
    ContractCheck('C6', 'values are opaque strings', () async {
      final k = key('c6');
      for (final value in [
        '',
        '{"id":"looks like a document"}',
        '["saudo-document-set",2,{}]',
        'ünïcödé — 漢字 — 🚀',
        'line\nbreaks\r\nand\ttabs',
      ]) {
        await backend.write(k, value);
        final read = await readBack(k);
        _check(
          read.kind == StorageReadKind.value && read.value == value,
          'value not returned exactly: ${read.kind}',
        );
      }
    }),
    ContractCheck('C6', 'a 5 MiB value round trips', () async {
      final k = key('c6-large');
      final value = List.filled(
        5 * 1024 * 1024 ~/ 16,
        'abcdefghijklmnop',
      ).join();
      _check(
        await backend.write(k, value) == StorageOutcome.committed,
        'large write not committed',
      );
      final read = await readBack(k);
      _check(
        read.value?.length == value.length && read.value == value,
        'large value not returned exactly',
      );
      await backend.delete(k);
    }),
    ContractCheck('C7', 'a failure never blocks later calls', () async {
      final k = key('c7');
      await hooks.failNextWrite(k);
      await backend.write(k, 'failed');
      _check(
        await backend.write(k, 'next') == StorageOutcome.committed,
        'the call after a failure did not complete',
      );
      _check((await readBack(k)).value == 'next', 'later call not applied');
      final unavailable = hooks.unavailable?.call();
      if (unavailable != null) {
        _check(!await unavailable.open(), 'unreachable storage opened');
        _check(
          await unavailable.write(k, 'x') == StorageOutcome.unavailable,
          'an unreachable write was not reported unavailable',
        );
        _check(
          (await unavailable.read(k)).kind == StorageReadKind.unavailable,
          'an unreachable read was not reported unavailable',
        );
      }
    }),
    ContractCheck(
      'C8',
      'an indeterminate write never lands after a later one',
      () async {
        final k = key('c8');
        await backend.write(k, 'seed');
        await hooks.nextWriteIndeterminateButApplied(k);
        final first = await backend.write(k, 'earlier');
        _check(
          first == StorageOutcome.indeterminate,
          'the provoked write reported $first',
        );
        _check(
          await backend.write(k, 'later') == StorageOutcome.committed,
          'the later write was not committed',
        );
        _check(
          (await readBack(k)).value == 'later',
          'the earlier write overtook the later one',
        );
        final later = await hooks.reopen();
        _check(
          (await later.read(k)).value == 'later',
          'a later start sees the earlier write',
        );
      },
    ),
  ];
}
