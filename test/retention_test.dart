import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_viewer/models.dart';
import 'package:markdown_viewer/retention.dart';
import 'package:markdown_viewer/store.dart';

import 'support/fake_storage.dart';

/// DF-039 Checkpoint 1: the storage and policy contract.
///
/// These drive the real [Store] - the real retention gate, the real operation
/// queue and the real generation fence - through a backend that can be made to
/// fail, to stall and to complete out of order on demand. That combination is
/// the point: the privacy promise rests on what happens when a write fails or
/// arrives late, and those cases cannot be produced by a healthy browser.
///
/// No user-facing claim or route is asserted here. Checkpoint 2 owns those.
void main() {
  /// A storage backend with deterministic failure and timing control.
  ///
  /// `stall` holds an operation open until the test releases it, which is what
  /// lets a test decide whether a later operation is merely queued behind an
  /// earlier one or was requested before the earlier one had started.
  late FakeBackend backend;
  late Store store;
  late RetentionController retention;

  setUp(() async {
    backend = FakeBackend();
    store = Store();
    await store.init(backend: backend);
    retention = RetentionController(store);
  });

  MarkdownDocument doc([String source = '# Doc\n\nbody']) =>
      MarkdownDocument.fromSource(source);

  ReadingPosition posFor(MarkdownDocument d, {int blockIndex = 4}) =>
      ReadingPosition(
        documentId: d.id,
        blockIndex: blockIndex,
        fraction: 0.25,
        savedAt: DateTime.now(),
      );

  /// Puts the store into a confirmed-ON state with content already stored, the
  /// starting point for the removal and transition cases.
  Future<MarkdownDocument> givenRetainedDocument() async {
    backend.data[Store.settingsKey] = jsonEncode(
      const Settings(keepForNextTime: true).toJson(),
    );
    final resolution = await retention.resolveStartup();
    expect(resolution.effectivePolicy, RetentionPolicy.on);
    final d = doc();
    expect(await store.saveDocument(d), WriteOutcome.saved);
    expect(await store.savePosition(posFor(d)), WriteOutcome.saved);
    return d;
  }

  group('default OFF', () {
    test('a fresh profile has no settings record and resolves OFF', () async {
      final resolution = await retention.resolveStartup();

      expect(resolution.settingsLoad.outcome, SettingsReadOutcome.missing);
      expect(resolution.settingsLoad.retentionFieldPresent, isFalse);
      expect(resolution.settingsLoad.settings.keepForNextTime, isFalse);
      expect(resolution.effectivePolicy, RetentionPolicy.off);
      expect(resolution.preferenceUncertain, isFalse);
      expect(resolution.cleanup, isNull, reason: 'nothing to clean up');
      expect(resolution.offPolicyDataUnresolved, isFalse);
    });

    test('a v1.1.0 settings record has no retention field and reads OFF', () {
      // Exactly the JSON v1.1.0 wrote: appearance fields and nothing else.
      backend.data[Store.settingsKey] = jsonEncode({
        'appearance': 'dark',
        'fontScale': 1.2,
        'wrapCode': true,
      });

      final result = store.loadSettingsResult();
      expect(result.outcome, SettingsReadOutcome.loaded);
      expect(result.retentionFieldPresent, isFalse);
      expect(result.settings.keepForNextTime, isFalse);
      expect(result.storedKeepForNextTime, isFalse);
      // The appearance fields beside it are untouched by the new field.
      expect(result.settings.appearance, AppearanceMode.dark);
      expect(result.settings.fontScale, 1.2);
      expect(result.settings.wrapCode, isTrue);
    });

    test('an explicit false is OFF and is distinguishable from absent', () {
      backend.data[Store.settingsKey] = jsonEncode(
        const Settings(keepForNextTime: false).toJson(),
      );

      final result = store.loadSettingsResult();
      expect(result.retentionFieldPresent, isTrue);
      expect(result.settings.keepForNextTime, isFalse);
      expect(result.storedKeepForNextTime, isFalse);
    });

    test('an unreadable settings record fails safe to OFF', () async {
      backend.data[Store.settingsKey] = '{ this is not json';

      final result = store.loadSettingsResult();
      expect(result.outcome, SettingsReadOutcome.unreadable);
      expect(result.preferenceTrustworthy, isFalse);
      expect(result.storedKeepForNextTime, isFalse);

      final resolution = await retention.resolveStartup();
      expect(resolution.effectivePolicy, RetentionPolicy.off);
      expect(
        resolution.preferenceUncertain,
        isTrue,
        reason: 'preference uncertainty is reportable in its own right',
      );
    });

    test('a settings record that decodes to a non-map is unreadable', () {
      backend.data[Store.settingsKey] = '["not", "a", "map"]';
      expect(
        store.loadSettingsResult().outcome,
        SettingsReadOutcome.unreadable,
      );
    });

    test('a non-boolean retention field is unreadable, not a confident OFF', () {
      backend.data[Store.settingsKey] = jsonEncode({
        'appearance': 'system',
        Settings.keepForNextTimeKey: 'yes',
      });

      final result = store.loadSettingsResult();
      // The value assertion alone would pass on either branch, so it cannot
      // distinguish "tolerated and read as false" from "rejected as unreadable".
      // The reason is the point: a record that is not the shape this app writes
      // is evidence the stored preference cannot be trusted.
      expect(result.settings.keepForNextTime, isFalse);
      expect(result.outcome, SettingsReadOutcome.unreadable);
      expect(result.preferenceTrustworthy, isFalse);
      expect(result.storedKeepForNextTime, isFalse);
    });

    test('unavailable storage resolves OFF and reports it as such', () async {
      final unavailable = Store();
      await unavailable.init(backend: UnavailableBackend());

      final result = unavailable.loadSettingsResult();
      expect(result.outcome, SettingsReadOutcome.unavailable);
      expect(result.preferenceTrustworthy, isFalse);
      expect(unavailable.isAvailable, isFalse);
      expect(
        await unavailable.saveSettings(const Settings()),
        WriteOutcome.unavailable,
      );
    });
  });

  group('write suppression while OFF', () {
    test('document and position writes are refused and store nothing', () async {
      await retention.resolveStartup();
      expect(store.effectivePolicy, RetentionPolicy.off);

      final d = doc();
      expect(await store.saveDocument(d), WriteOutcome.suppressedByPolicy);
      expect(await store.savePosition(posFor(d)), WriteOutcome.suppressedByPolicy);

      expect(backend.writes, isEmpty, reason: 'the backend was never asked');
      expect(store.rawContentPresence(), RawKeyPresence.absent);
    });

    test('settings writes are not gated on retention policy', () async {
      await retention.resolveStartup();

      expect(
        await store.saveSettings(const Settings(appearance: AppearanceMode.dark)),
        WriteOutcome.saved,
      );
      expect(store.loadSettings().appearance, AppearanceMode.dark);
    });

    test('every content write path is refused, not just the first', () async {
      await retention.resolveStartup();
      final d = doc();

      // The four shapes of content write the app performs: a fresh document, an
      // edited document, a script-preference change, and a scroll position.
      for (final attempt in <Future<WriteOutcome>>[
        store.saveDocument(d),
        store.saveDocument(d.copyWith(source: '# Edited', updatedAt: DateTime.now())),
        store.saveDocument(
          d.copyWith(scriptPreference: DocumentScriptPreference.simplifiedChinese),
        ),
        store.savePosition(posFor(d)),
      ]) {
        expect(await attempt, WriteOutcome.suppressedByPolicy);
      }
      expect(store.rawContentPresence(), RawKeyPresence.absent);
    });
  });

  group('raw presence', () {
    test('present, absent and indeterminate are distinguished', () async {
      expect(store.rawKeyPresence(Store.documentKey), RawKeyPresence.absent);

      backend.data[Store.documentKey] = 'anything at all';
      expect(store.rawKeyPresence(Store.documentKey), RawKeyPresence.present);
      expect(store.rawContentPresence(), RawKeyPresence.present);

      backend.failReads.add(Store.documentKey);
      expect(
        store.rawKeyPresence(Store.documentKey),
        RawKeyPresence.indeterminate,
      );
      expect(store.rawContentPresence(), RawKeyPresence.indeterminate);
    });

    test('an orphaned position alone counts as retained content', () {
      backend.data[Store.positionKey] = 'orphan';
      expect(store.rawContentPresence(), RawKeyPresence.present);
    });

    test('presence does not depend on the record decoding', () async {
      backend.data[Store.documentKey] = 'not json';
      expect(store.loadDocument(), isNull);
      expect(store.rawKeyPresence(Store.documentKey), RawKeyPresence.present);
    });
  });

  group('verified two-key removal', () {
    test('confirms absence when both keys go', () async {
      await givenRetainedDocument();
      expect(store.rawContentPresence(), RawKeyPresence.present);

      expect(await store.removeRetainedContent(), CleanupOutcome.confirmedAbsent);
      expect(store.rawKeyPresence(Store.documentKey), RawKeyPresence.absent);
      expect(store.rawKeyPresence(Store.positionKey), RawKeyPresence.absent);
    });

    test('reports partial when one key survives', () async {
      await givenRetainedDocument();
      backend.failDeletes.add(Store.positionKey);

      expect(
        await store.removeRetainedContent(),
        CleanupOutcome.partiallyPresent,
      );
      expect(store.rawKeyPresence(Store.documentKey), RawKeyPresence.absent);
      expect(store.rawKeyPresence(Store.positionKey), RawKeyPresence.present);
    });

    test('reports failure when neither key goes', () async {
      await givenRetainedDocument();
      backend.failDeletes.addAll([Store.documentKey, Store.positionKey]);

      expect(await store.removeRetainedContent(), CleanupOutcome.failed);
      expect(store.rawContentPresence(), RawKeyPresence.present);
    });

    test('reports indeterminate when absence cannot be verified', () async {
      await givenRetainedDocument();
      backend.failReads.add(Store.documentKey);

      expect(
        await store.removeRetainedContent(),
        CleanupOutcome.indeterminate,
        reason: 'a delete that cannot be verified is not proof of absence',
      );
    });

    test('a failed document delete does not abandon the position', () async {
      await givenRetainedDocument();
      backend.failDeletes.add(Store.documentKey);

      expect(
        await store.removeRetainedContent(),
        CleanupOutcome.partiallyPresent,
      );
      expect(
        store.rawKeyPresence(Store.positionKey),
        RawKeyPresence.absent,
        reason: 'the second delete must still be attempted',
      );
    });

    test('removal leaves settings untouched', () async {
      await givenRetainedDocument();
      await store.saveSettings(
        const Settings(appearance: AppearanceMode.dark, keepForNextTime: true),
      );

      expect(await store.removeRetainedContent(), CleanupOutcome.confirmedAbsent);

      final settings = store.loadSettings();
      expect(settings.appearance, AppearanceMode.dark);
      expect(settings.keepForNextTime, isTrue);
    });

    test('unavailable storage cannot claim absence', () async {
      final unavailable = Store();
      await unavailable.init(backend: UnavailableBackend());
      expect(
        await unavailable.removeRetainedContent(),
        CleanupOutcome.indeterminate,
      );
    });
  });

  group('prior-operation containment', () {
    test('a queued write issued before a removal is superseded', () async {
      final d = await givenRetainedDocument();

      // Stall the first write so the second is queued behind it and has not yet
      // run its generation check when the removal is requested.
      final firstGate = backend.stall(Store.documentKey);
      final first = store.saveDocument(d.copyWith(source: '# One'));
      await pumpEventQueue();
      final second = store.savePosition(posFor(d, blockIndex: 99));

      final cleanup = store.removeRetainedContent();

      firstGate.complete();

      expect(await first, WriteOutcome.saved, reason: 'it had already started');
      expect(
        await second,
        WriteOutcome.superseded,
        reason: 'issued under the generation the removal invalidated',
      );
      expect(await cleanup, CleanupOutcome.confirmedAbsent);
      expect(store.rawContentPresence(), RawKeyPresence.absent);
    });

    test('an in-flight write is settled before absence is verified', () async {
      final d = await givenRetainedDocument();

      final gate = backend.stall(Store.documentKey);
      final inFlight = store.saveDocument(d.copyWith(source: '# Late'));
      await pumpEventQueue();

      final cleanup = store.removeRetainedContent();
      // Release only after the removal has been requested, so the write lands
      // during the removal's lifetime rather than before it.
      gate.complete();

      expect(await inFlight, WriteOutcome.saved);
      expect(
        await cleanup,
        CleanupOutcome.confirmedAbsent,
        reason: 'verification runs after every earlier operation has settled',
      );
      expect(
        store.rawContentPresence(),
        RawKeyPresence.absent,
        reason: 'the late write must not survive the removal that followed it',
      );
    });

    test('a write already requested when a removal is issued cannot repopulate',
        () async {
      final d = await givenRetainedDocument();

      final gate = backend.stall(Store.documentKey);
      final stale = store.saveDocument(d.copyWith(source: '# Stale'));
      await pumpEventQueue();
      final stalePosition = store.savePosition(posFor(d, blockIndex: 77));

      final cleanup = store.removeRetainedContent();
      gate.complete();

      await Future.wait<Object?>([stale, stalePosition, cleanup]);
      await store.settlePendingOperations();

      expect(await stalePosition, WriteOutcome.superseded);
      expect(
        store.rawContentPresence(),
        RawKeyPresence.absent,
        reason: 'every write here was requested before the removal was issued, '
            'so the fence covers all of them',
      );
    });

    test('the fence does not cover a write requested after the removal',
        () async {
      // The boundary, pinned deliberately rather than left to be discovered.
      // `removeRetainedContent` invalidates writes already requested when it is
      // issued; a write requested afterwards carries the new generation, so it
      // is a fresh request and lands behind the removal.
      //
      // `_openDocument` depends on exactly this - it removes the outgoing
      // document and then saves the replacement - so the behaviour is required,
      // not incidental. Its consequence is that a `confirmedAbsent` from a
      // removal that does not also change policy is true when it is taken and
      // not durable afterwards.
      final d = await givenRetainedDocument();

      final cleanup = store.removeRetainedContent();
      final afterwards = store.savePosition(posFor(d, blockIndex: 88));

      expect(await cleanup, CleanupOutcome.confirmedAbsent);
      expect(await afterwards, WriteOutcome.saved);
      await store.settlePendingOperations();

      expect(
        store.rawContentPresence(),
        RawKeyPresence.present,
        reason: 'absence was verified when the removal ran, and a later write '
            'legitimately followed it',
      );
    });

    test('writes issued under ON are dropped once policy flips to OFF', () async {
      final d = await givenRetainedDocument();

      final gate = backend.stall(Store.documentKey);
      final running = store.saveDocument(d.copyWith(source: '# Running'));
      await pumpEventQueue();
      final queued = store.savePosition(posFor(d, blockIndex: 55));

      // The transition bumps the content generation synchronously.
      store.applyResolvedPolicy(RetentionPolicy.off);
      gate.complete();

      expect(await running, WriteOutcome.saved);
      expect(await queued, WriteOutcome.superseded);
      expect(
        await store.saveDocument(d),
        WriteOutcome.suppressedByPolicy,
        reason: 'anything requested after the flip is refused outright',
      );
    });

    test('an older settings completion cannot overwrite a newer preference',
        () async {
      // The older write is still queued when the newer one is requested.
      final gate = backend.stall(Store.settingsKey);
      final blocker = store.saveSettings(const Settings(fontScale: 1.1));
      await pumpEventQueue();

      final older = store.saveSettings(const Settings(keepForNextTime: false));
      final newer = store.saveSettings(const Settings(keepForNextTime: true));
      gate.complete();

      expect(
        await blocker,
        WriteOutcome.saved,
        reason: 'it had already passed its generation check before the others '
            'were requested, so it lands - and is then overwritten',
      );
      expect(await older, WriteOutcome.superseded);
      expect(await newer, WriteOutcome.saved);
      await store.settlePendingOperations();

      expect(
        store.loadSettingsResult().settings.keepForNextTime,
        isTrue,
        reason: 'the last requested value is the one that survives',
      );
    });

    test('an in-flight settings write is overwritten by the newer value',
        () async {
      // The older write has already started, so it lands - and is then
      // overwritten, rather than landing last.
      final gate = backend.stall(Store.settingsKey);
      final older = store.saveSettings(const Settings(keepForNextTime: false));
      await pumpEventQueue();
      final newer = store.saveSettings(const Settings(keepForNextTime: true));
      gate.complete();

      expect(await older, WriteOutcome.saved);
      expect(await newer, WriteOutcome.saved);
      await store.settlePendingOperations();

      expect(store.loadSettingsResult().settings.keepForNextTime, isTrue);
    });

    test('the settlement barrier waits for everything already requested',
        () async {
      await givenRetainedDocument();
      final gate = backend.stall(Store.documentKey);
      final pending = store.saveDocument(doc('# Pending'));

      var settled = false;
      unawaited(store.settlePendingOperations().then((_) => settled = true));
      await pumpEventQueue();
      expect(settled, isFalse);

      gate.complete();
      await pending;
      await store.settlePendingOperations();
      expect(settled, isTrue);
    });
  });

  group('OFF to ON', () {
    test('confirms only when preference and document both land', () async {
      await retention.resolveStartup();
      final d = doc();

      final result = await retention.enable(
        current: const Settings(),
        document: d,
        position: posFor(d),
      );

      expect(result.preferenceOutcome, WriteOutcome.saved);
      expect(result.documentOutcome, WriteOutcome.saved);
      expect(result.positionOutcome, WriteOutcome.saved);
      expect(result.keptForNextTime, isTrue);
      expect(result.effectivePolicy, RetentionPolicy.on);
      expect(store.loadSettingsResult().settings.keepForNextTime, isTrue);
      expect(store.loadDocument()!.id, d.id);
    });

    test('a failed preference write stores no content at all', () async {
      await retention.resolveStartup();
      backend.failWrites.add(Store.settingsKey);
      final d = doc();

      final result = await retention.enable(current: const Settings(), document: d);

      expect(result.preferenceOutcome, WriteOutcome.failed);
      expect(result.keptForNextTime, isFalse);
      expect(result.effectivePolicy, RetentionPolicy.off);
      expect(
        store.rawContentPresence(),
        RawKeyPresence.absent,
        reason: 'content no confirmed preference governs is not written',
      );
    });

    test('a failed document write leaves ON but claims nothing kept', () async {
      await retention.resolveStartup();
      backend.failWrites.add(Store.documentKey);

      final result = await retention.enable(
        current: const Settings(),
        document: doc(),
      );

      expect(result.preferenceConfirmed, isTrue);
      expect(result.documentOutcome, WriteOutcome.failed);
      expect(
        result.keptForNextTime,
        isFalse,
        reason: 'the preference survives for later loads; this document is not saved',
      );
      expect(result.effectivePolicy, RetentionPolicy.on);
    });

    test('a failed position write does not deny the document was saved',
        () async {
      await retention.resolveStartup();
      backend.failWrites.add(Store.positionKey);
      final d = doc();

      final result = await retention.enable(
        current: const Settings(),
        document: d,
        position: posFor(d),
      );

      expect(result.documentOutcome, WriteOutcome.saved);
      expect(result.positionOutcome, WriteOutcome.failed);
      expect(result.keptForNextTime, isTrue);
    });

    test('a position belonging to another document is not written', () async {
      await retention.resolveStartup();
      final d = doc();
      // An explicit id: `fromSource` derives one from the current microsecond,
      // so two documents built in the same tick would share it and this test
      // would silently stop testing anything.
      final other = MarkdownDocument.fromSource('# Other', id: 'other-document');
      expect(other.id, isNot(d.id));

      final result = await retention.enable(
        current: const Settings(),
        document: d,
        position: posFor(other),
      );

      expect(result.positionOutcome, isNull);
      expect(store.rawKeyPresence(Store.positionKey), RawKeyPresence.absent);
    });
  });

  group('off-policy interlock', () {
    test('unresolved off-policy data blocks enabling ON', () async {
      // A v1.1.0 profile whose content cannot be deleted.
      backend.data[Store.settingsKey] = jsonEncode({'appearance': 'system'});
      backend.data[Store.documentKey] = jsonEncode(doc().toJson());
      backend.failDeletes.add(Store.documentKey);

      final resolution = await retention.resolveStartup();
      expect(resolution.effectivePolicy, RetentionPolicy.off);
      expect(resolution.legacyRecord, isTrue);
      expect(
        resolution.cleanup,
        CleanupOutcome.failed,
        reason: 'the only stored key survived, so nothing was removed',
      );
      expect(resolution.offPolicyDataUnresolved, isTrue);
      expect(retention.offPolicyDataUnresolved, isTrue);

      final result = await retention.enable(
        current: const Settings(),
        document: doc('# New'),
      );

      expect(result.blockedByOffPolicyData, isTrue);
      expect(result.effectivePolicy, RetentionPolicy.off);
      expect(result.preferenceOutcome, WriteOutcome.suppressedByPolicy);
      expect(result.keptForNextTime, isFalse);
      expect(
        store.loadSettingsResult().settings.keepForNextTime,
        isFalse,
        reason: 'no durable ON preference may exist while cleanup is unresolved',
      );
    });

    test('ON becomes available once cleanup is verified', () async {
      backend.data[Store.settingsKey] = jsonEncode({'appearance': 'system'});
      backend.data[Store.documentKey] = jsonEncode(doc().toJson());
      backend.failDeletes.add(Store.documentKey);

      await retention.resolveStartup();
      expect(retention.offPolicyDataUnresolved, isTrue);

      // The user retries after the obstruction clears.
      backend.failDeletes.clear();
      final fresh = doc('# Chosen now');
      final result = await retention.enable(
        current: const Settings(),
        document: fresh,
      );

      expect(result.blockedByOffPolicyData, isFalse);
      expect(result.keptForNextTime, isTrue);
      expect(retention.offPolicyDataUnresolved, isFalse);
      expect(
        store.loadDocument()!.title,
        'Chosen now',
        reason: 'only the current in-memory document may be newly retained',
      );
    });

    test('an interrupted cleanup leaves no durable ON to reclassify data',
        () async {
      backend.data[Store.settingsKey] = jsonEncode({'appearance': 'system'});
      backend.data[Store.documentKey] = jsonEncode(doc('# Legacy').toJson());
      backend.failDeletes.add(Store.documentKey);

      await retention.resolveStartup();
      await retention.enable(current: const Settings(), document: doc('# New'));

      // Simulate the reload: a new controller over the same stored bytes.
      final reloaded = RetentionController(store);
      final again = await reloaded.resolveStartup();

      expect(again.effectivePolicy, RetentionPolicy.off);
      expect(again.offPolicyDataUnresolved, isTrue);
      expect(
        store.loadSettingsResult().settings.keepForNextTime,
        isFalse,
        reason: 'interruption returns to OFF resolution, not to silent consent',
      );
    });

    test('legacy content is removed and reported when cleanup succeeds',
        () async {
      backend.data[Store.settingsKey] = jsonEncode({
        'appearance': 'dark',
        'fontScale': 1.15,
      });
      backend.data[Store.documentKey] = jsonEncode(doc('# Legacy').toJson());
      backend.data[Store.positionKey] = jsonEncode(
        posFor(doc('# Legacy')).toJson(),
      );

      final resolution = await retention.resolveStartup();

      expect(resolution.legacyRecord, isTrue);
      expect(resolution.cleanup, CleanupOutcome.confirmedAbsent);
      expect(resolution.legacyContentRemoved, isTrue);
      expect(resolution.offPolicyDataUnresolved, isFalse);
      expect(resolution.effectivePolicy, RetentionPolicy.off);
      expect(store.rawContentPresence(), RawKeyPresence.absent);
      expect(
        store.loadSettings().appearance,
        AppearanceMode.dark,
        reason: 'appearance settings survive the content cleanup',
      );
    });

    test('an orphaned position alone is cleaned up under OFF', () async {
      backend.data[Store.positionKey] = jsonEncode(posFor(doc()).toJson());

      final resolution = await retention.resolveStartup();
      expect(resolution.cleanup, CleanupOutcome.confirmedAbsent);
      expect(store.rawContentPresence(), RawKeyPresence.absent);
    });

    test('content stored under an unreadable preference is off-policy',
        () async {
      backend.data[Store.settingsKey] = 'corrupt';
      backend.data[Store.documentKey] = jsonEncode(doc().toJson());

      final resolution = await retention.resolveStartup();
      expect(resolution.effectivePolicy, RetentionPolicy.off);
      expect(resolution.preferenceUncertain, isTrue);
      expect(resolution.cleanup, CleanupOutcome.confirmedAbsent);
      expect(
        resolution.legacyRecord,
        isFalse,
        reason: 'an unreadable record is not the same as a v1.1.0 record',
      );
    });

    test('a confirmed ON profile keeps its content untouched', () async {
      final d = await givenRetainedDocument();

      final reloaded = RetentionController(store);
      final resolution = await reloaded.resolveStartup();

      expect(resolution.effectivePolicy, RetentionPolicy.on);
      expect(resolution.cleanup, isNull);
      expect(resolution.offPolicyDataUnresolved, isFalse);
      expect(store.loadDocument()!.id, d.id);
      expect(store.loadPosition(d.id), isNotNull);
    });
  });

  group('ON to OFF', () {
    test('confirms only when the preference and both keys are confirmed',
        () async {
      await givenRetainedDocument();

      final result = await retention.disable(
        current: const Settings(keepForNextTime: true),
      );

      expect(result.effectivePolicy, RetentionPolicy.off);
      expect(result.preferenceOutcome, WriteOutcome.saved);
      expect(result.cleanup, CleanupOutcome.confirmedAbsent);
      expect(result.removedAndWillNotReturn, isTrue);
      expect(store.rawContentPresence(), RawKeyPresence.absent);
      expect(store.loadSettingsResult().settings.keepForNextTime, isFalse);
    });

    test('preference confirmed but data remaining makes no privacy claim',
        () async {
      await givenRetainedDocument();
      backend.failDeletes.add(Store.documentKey);

      final result = await retention.disable(
        current: const Settings(keepForNextTime: true),
      );

      expect(result.preferenceConfirmed, isTrue);
      expect(result.cleanup, CleanupOutcome.partiallyPresent);
      expect(result.contentConfirmedAbsent, isFalse);
      expect(result.removedAndWillNotReturn, isFalse);
      expect(retention.offPolicyDataUnresolved, isTrue);
    });

    test('data absent but preference unconfirmed claims only the removal',
        () async {
      await givenRetainedDocument();
      backend.failWrites.add(Store.settingsKey);

      final result = await retention.disable(
        current: const Settings(keepForNextTime: true),
      );

      expect(result.preferenceOutcome, WriteOutcome.failed);
      expect(result.contentConfirmedAbsent, isTrue);
      expect(
        result.removedAndWillNotReturn,
        isFalse,
        reason: 'the choice may not survive the next visit',
      );
      expect(
        store.rawContentPresence(),
        RawKeyPresence.absent,
        reason: 'deletion is attempted regardless of the preference write',
      );
    });

    test('both unconfirmed yields no success of any kind', () async {
      await givenRetainedDocument();
      backend.failWrites.add(Store.settingsKey);
      backend.failDeletes.addAll([Store.documentKey, Store.positionKey]);

      final result = await retention.disable(
        current: const Settings(keepForNextTime: true),
      );

      expect(result.preferenceConfirmed, isFalse);
      expect(result.cleanup, CleanupOutcome.failed);
      expect(result.removedAndWillNotReturn, isFalse);
      expect(
        result.effectivePolicy,
        RetentionPolicy.off,
        reason: 'session behaviour goes OFF immediately either way',
      );
    });

    test('effective policy goes OFF before anything is written', () async {
      await givenRetainedDocument();
      backend.stall(Store.settingsKey);

      unawaited(
        retention.disable(current: const Settings(keepForNextTime: true)),
      );
      await pumpEventQueue();

      expect(
        store.effectivePolicy,
        RetentionPolicy.off,
        reason: 'suppression must not wait for the preference write to resolve',
      );
      expect(
        await store.saveDocument(doc('# During')),
        WriteOutcome.suppressedByPolicy,
      );
    });
  });

  group('direct removal and recovery', () {
    test('removing the saved document preserves the ON preference', () async {
      await givenRetainedDocument();
      await store.saveSettings(const Settings(keepForNextTime: true));

      expect(await retention.removeSavedDocument(), CleanupOutcome.confirmedAbsent);

      expect(store.rawContentPresence(), RawKeyPresence.absent);
      expect(
        store.loadSettingsResult().settings.keepForNextTime,
        isTrue,
        reason: 'removing one document does not change the future default',
      );
      expect(store.effectivePolicy, RetentionPolicy.on);
    });

    test('a failed direct removal marks the data off-policy for later ON',
        () async {
      await givenRetainedDocument();
      backend.failDeletes.add(Store.documentKey);

      expect(
        await retention.removeSavedDocument(),
        CleanupOutcome.partiallyPresent,
      );
      expect(retention.offPolicyDataUnresolved, isTrue);
    });

    test('unreadable-data recovery removes by key, not by decoded model',
        () async {
      backend.data[Store.documentKey] = 'not decodable';
      backend.data[Store.positionKey] = 'also not decodable';
      await retention.resolveStartup();

      // Startup already cleans this up under OFF; re-seed to exercise the
      // recovery control on its own terms.
      backend.data[Store.documentKey] = 'not decodable';
      expect(store.loadDocument(), isNull);

      expect(
        await retention.removeUnreadableData(),
        CleanupOutcome.confirmedAbsent,
      );
      expect(store.rawContentPresence(), RawKeyPresence.absent);
    });

    test('recovery does not change the retention preference', () async {
      await store.saveSettings(const Settings(keepForNextTime: true));
      backend.data[Store.documentKey] = 'corrupt';

      await retention.removeUnreadableData();

      expect(store.loadSettingsResult().settings.keepForNextTime, isTrue);
    });
  });

  group('policy gate coverage', () {
    // The behavioural tests above prove the gate refuses the writes the app
    // makes today. These prove the structural property behind that: there is
    // exactly one place content can reach storage, and it is gated. A future
    // call site that wrote directly would not necessarily fail any behavioural
    // test, so the invariant is asserted where it actually lives.

    String read(String path) =>
        File(path).readAsStringSync().replaceAll('\r\n', '\n');

    List<File> libFiles() => Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

    /// The body of [name] in [source], bounded to the first line that closes at
    /// member indentation. A looser bound would swallow the rest of the class
    /// and make the negative assertions below meaningless.
    String bodyOf(String source, String name) {
      final start = source.indexOf(name);
      expect(start, greaterThan(-1), reason: '$name must exist');
      final end = source.indexOf('\n  }\n', start);
      expect(end, greaterThan(start), reason: '$name must be bounded');
      return source.substring(start, end + 4);
    }

    test('all persistence funnels through one write and one delete', () {
      final mutations = <String>[];
      for (final file in libFiles()) {
        final source = read(file.path);
        for (final call in const ['backend.write(', 'backend.delete(']) {
          for (
            var i = source.indexOf(call);
            i > -1;
            i = source.indexOf(call, i + 1)
          ) {
            mutations.add('${file.path}: $call');
          }
        }
      }

      expect(
        mutations.length,
        2,
        reason:
            'content must have exactly one way in and one way out: $mutations',
      );
      expect(mutations.every((m) => m.contains('store.dart')), isTrue);
    });

    test('only the store may reach the storage package', () {
      final offenders = libFiles()
          .where((f) => !f.path.endsWith('store.dart'))
          .where((f) => read(f.path).contains('hive'))
          .map((f) => f.path)
          .toList();

      expect(offenders, isEmpty, reason: 'storage stays behind the store');
    });

    test('both content writers go through the gated path', () {
      final source = read('lib/store.dart');

      for (final writer in const [
        'Future<WriteOutcome> saveDocument(',
        'Future<WriteOutcome> savePosition(',
      ]) {
        final body = bodyOf(source, writer);
        expect(
          body,
          contains('_writeContent('),
          reason: '$writer must reach storage only through the gate',
        );
        expect(
          body,
          isNot(contains('_put(')),
          reason: '$writer must not bypass the gate',
        );
      }
    });

    test('the gated path refuses before it writes', () {
      final body = bodyOf(
        read('lib/store.dart'),
        'Future<WriteOutcome> _writeContent(',
      );

      expect(body, contains('RetentionPolicy.off'));
      expect(
        body.indexOf('WriteOutcome.suppressedByPolicy'),
        lessThan(body.indexOf('_put(')),
        reason: 'the refusal must precede the write, not follow it',
      );
      expect(
        body,
        contains('WriteOutcome.superseded'),
        reason: 'the generation fence lives on the same path as the gate',
      );
    });

    test('settings are written on an ungated path, deliberately', () {
      final body = bodyOf(
        read('lib/store.dart'),
        'Future<WriteOutcome> saveSettings(',
      );

      expect(body, contains('_put('));
      expect(
        body,
        isNot(contains('_writeContent(')),
        reason: 'appearance and the retention choice itself survive OFF',
      );
    });

    test('removal bumps the fence before it enqueues anything', () {
      final body = bodyOf(
        read('lib/store.dart'),
        'Future<CleanupOutcome> removeRetainedContent(',
      );

      expect(
        body.indexOf('_contentGeneration++'),
        lessThan(body.indexOf('_enqueue(')),
        reason:
            'a write already requested must be invalidated at the moment '
            'removal is asked for, not when it reaches the front of the queue',
      );
    });
  });
}
