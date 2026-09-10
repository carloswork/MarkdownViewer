/// The browser-local retention contract (DF-039).
///
/// Pure Dart, like `models.dart`: it must not import Flutter or any platform
/// library, so the policy semantics that carry the privacy promise can be unit
/// tested without a widget tree or a browser.
///
/// The contract this file exists to make explicit is that four things fail
/// independently and must therefore be reported independently:
///
///   1. writing the retention preference,
///   2. writing the current document,
///   3. writing the reading position, and
///   4. removing what was previously stored.
///
/// Collapsing them into one boolean would either overpromise privacy - claiming
/// content is gone when a delete silently failed - or hide that a future visit
/// may still run under a stale preference. Every result type below therefore
/// keeps its own outcome, and the combined success predicates require each part
/// to be confirmed rather than merely attempted.
library;

import 'models.dart';

/// Whether this browser may keep the current document across visits.
///
/// "Effective" policy, not the stored preference: an unreadable settings record
/// or unresolved off-policy data both resolve to [off] for the current page
/// lifetime regardless of what is written on disk.
enum RetentionPolicy { off, on }

/// Outcome of one attempted durable write.
///
/// [suppressedByPolicy] and [superseded] are deliberately not failures. Nothing
/// went wrong; the write was correctly not performed. They stay distinct from
/// [saved] because neither may be reported to the user as stored.
enum WriteOutcome {
  /// The backend accepted the write and it completed.
  saved,

  /// Not attempted: effective policy was OFF when the write was requested.
  suppressedByPolicy,

  /// The write was not applied because a later removal or policy transition
  /// invalidated it. Two cases produce it: the generation fence, which stops a
  /// completion issued before a removal from landing after it; and per-document
  /// suppression, which refuses any further write for a document the user has
  /// removed - including the reader's `dispose()` position flush, which is
  /// issued after the removal and so is not stale in the generational sense.
  superseded,

  /// Attempted and rejected by the backend.
  failed,

  /// No durable storage is open at all - Private Browsing being the realistic
  /// case. Nothing was written and nothing can be.
  unavailable,
}

extension WriteOutcomeX on WriteOutcome {
  /// True only for a write that is known to have landed. Every other outcome,
  /// including the two benign ones, must not be described as stored.
  bool get isConfirmed => this == WriteOutcome.saved;
}

/// Outcome of a two-key removal, verified after the settlement boundary.
///
/// Verification is a re-read of the raw keys, not the return value of the
/// delete: the whole point of DF-039's removal contract is that a delete which
/// reports nothing is not evidence of absence.
enum CleanupOutcome {
  /// Neither raw key was present when verification ran. This is the only
  /// outcome that permits "Removed from this browser".
  confirmedAbsent,

  /// Some of what was stored went, and some of it survived.
  partiallyPresent,

  /// Everything that was stored is still stored: the removal achieved nothing.
  failed,

  /// Presence could not be established, so absence cannot be claimed either.
  indeterminate,
}

extension CleanupOutcomeX on CleanupOutcome {
  bool get isConfirmedAbsent => this == CleanupOutcome.confirmedAbsent;

  /// True when the user must be told that saved data may still remain. Both a
  /// partial removal and an unverifiable one qualify: the difference matters
  /// for diagnosis, not for what may be promised.
  bool get mayLeaveData => this != CleanupOutcome.confirmedAbsent;
}

/// Whether a raw stored key exists, independent of whether it decodes.
///
/// Presence is deliberately checked at the raw-key level. A record that cannot
/// be decoded into a document is still retained data, and treating a decode
/// failure as "nothing stored" is exactly how content becomes retained but
/// unreachable - and therefore unremovable through the product.
enum RawKeyPresence { present, absent, indeterminate }

/// How the stored settings record read back.
enum SettingsReadOutcome {
  /// A settings record existed and decoded.
  loaded,

  /// No settings record exists yet. A fresh install: defaults apply and the
  /// preference is trustworthy, because default OFF is what a new user gets.
  missing,

  /// A settings record exists but could not be decoded. The preference value is
  /// unknown, so policy fails safe to OFF and the uncertainty is reportable.
  unreadable,

  /// No durable storage is open, so no preference could be read or written.
  unavailable,
}

/// The stored settings plus how confidently they were read.
class SettingsLoadResult {
  const SettingsLoadResult({
    required this.settings,
    required this.outcome,
    required this.retentionFieldPresent,
  });

  final Settings settings;
  final SettingsReadOutcome outcome;

  /// Whether the stored JSON carried the retention field at all.
  ///
  /// Both absence and an explicit `false` resolve to OFF, so this does not
  /// change policy. It distinguishes a v1.1.0 record that predates the choice
  /// from a record where the user chose OFF, which is what makes the legacy
  /// transition in D-010 provable rather than assumed.
  final bool retentionFieldPresent;

  /// Whether the preference value can be trusted for this page lifetime.
  ///
  /// A missing record is trustworthy: it means default OFF.
  bool get preferenceTrustworthy =>
      outcome == SettingsReadOutcome.loaded ||
      outcome == SettingsReadOutcome.missing;

  /// The preference as stored, before any interlock is applied.
  bool get storedKeepForNextTime =>
      preferenceTrustworthy && settings.keepForNextTime;
}

/// What startup resolved before any route or user-facing claim is chosen.
///
/// Checkpoint 1 owns this resolution because the OFF to ON interlock depends on
/// it. Checkpoint 2 owns the routing and presentation built on top of it; this
/// class deliberately describes state and says nothing about screens.
class StartupResolution {
  const StartupResolution({
    required this.effectivePolicy,
    required this.settingsLoad,
    required this.rawContentPresentAtStartup,
    required this.legacyRecord,
    this.cleanup,
  });

  /// Policy in force for this page lifetime.
  final RetentionPolicy effectivePolicy;

  final SettingsLoadResult settingsLoad;

  /// Whether either raw content key existed when startup began.
  final RawKeyPresence rawContentPresentAtStartup;

  /// True when raw content was found alongside a settings record that carried
  /// no retention field - the v1.1.0 profile D-010 governs.
  final bool legacyRecord;

  /// The removal attempt, present only when off-policy content was found.
  final CleanupOutcome? cleanup;

  /// Whether off-policy data remains unresolved, which blocks enabling ON.
  ///
  /// True whenever a cleanup ran and did not confirm absence. Absence of a
  /// cleanup means there was nothing off-policy to remove.
  bool get offPolicyDataUnresolved =>
      cleanup != null && !cleanup!.isConfirmedAbsent;

  /// Whether cleanup ran and succeeded, which is what earns the session-scoped
  /// notice that previously saved reading data was removed.
  bool get legacyContentRemoved =>
      cleanup != null && cleanup!.isConfirmedAbsent;

  /// Whether the preference itself is in an error state the user must be told
  /// about, separately from anything about content.
  bool get preferenceUncertain => !settingsLoad.preferenceTrustworthy;
}

/// The result of a requested retention-policy transition.
///
/// Every field is reported separately on purpose. `plan.md` §19.2 and §19.3
/// enumerate the partial combinations, and each one has a different truthful
/// message; a single success flag could not express them.
class RetentionTransitionResult {
  const RetentionTransitionResult({
    required this.requested,
    required this.effectivePolicy,
    required this.preferenceOutcome,
    this.cleanup,
    this.documentOutcome,
    this.positionOutcome,
    this.blockedByOffPolicyData = false,
  });

  /// Refused before anything was written, because off-policy data is still
  /// unresolved. Effective policy stays OFF and no preference is persisted.
  factory RetentionTransitionResult.blocked({required CleanupOutcome cleanup}) {
    return RetentionTransitionResult(
      requested: RetentionPolicy.on,
      effectivePolicy: RetentionPolicy.off,
      preferenceOutcome: WriteOutcome.suppressedByPolicy,
      cleanup: cleanup,
      blockedByOffPolicyData: true,
    );
  }

  final RetentionPolicy requested;

  /// Policy actually in force after the transition. A blocked or failed
  /// enable leaves this OFF; a disable sets it OFF immediately, before any
  /// write is attempted.
  final RetentionPolicy effectivePolicy;

  final WriteOutcome preferenceOutcome;

  /// Removal result, for a disable or for the interlock cleanup of an enable.
  final CleanupOutcome? cleanup;

  /// Content results, for an enable that reached the save step.
  final WriteOutcome? documentOutcome;
  final WriteOutcome? positionOutcome;

  final bool blockedByOffPolicyData;

  bool get preferenceConfirmed => preferenceOutcome.isConfirmed;

  bool get documentConfirmed => documentOutcome?.isConfirmed ?? false;

  /// Whether the removal side is proven complete.
  bool get contentConfirmedAbsent => cleanup?.isConfirmedAbsent ?? false;

  /// The combined claim `Kept for next time` is allowed to make.
  ///
  /// Requires both the preference and the current document to be confirmed
  /// after the settlement boundary. A confirmed preference with a failed
  /// document save is a real state - future loads will be retained - but this
  /// document is not saved, so the combined claim is withheld.
  bool get keptForNextTime =>
      requested == RetentionPolicy.on &&
      !blockedByOffPolicyData &&
      preferenceConfirmed &&
      documentConfirmed;

  /// The combined claim a disable is allowed to make.
  ///
  /// Requires the OFF preference to be confirmed *and* both raw keys verified
  /// absent. Hiding the continue action is containment, not proof of deletion.
  bool get removedAndWillNotReturn =>
      requested == RetentionPolicy.off &&
      preferenceConfirmed &&
      contentConfirmedAbsent;
}

/// What Home may offer as a way back into the current document.
///
/// The two positive cases are deliberately distinct rather than one "continue"
/// with a caption. They make different promises: [currentSession] survives only
/// until this page goes away, [retained] survives a reopen. Collapsing them
/// would be the exact overstatement D-015's terminology rules forbid.
enum ContinueOffer {
  /// Nothing to continue.
  none,

  /// A document loaded in this page lifetime while retention is OFF. Real, and
  /// gone on refresh.
  currentSession,

  /// A document stored under a confirmed ON preference, and the stored copy is
  /// the one in memory.
  retained,

  /// A copy of this document is stored under a confirmed ON preference, but the
  /// latest changes to it did not save.
  ///
  /// Distinct from [retained] because what would come back on a reopen is not
  /// what is on screen, and saying `Saved in this browser` would be the
  /// overstatement D-015 forbids. Distinct from [currentSession] because
  /// something *is* stored in this browser, so the user must still be able to
  /// see that and remove it.
  retainedOutOfDate,
}

/// Something Home must tell the user about retention state.
///
/// Semantic rather than textual: the wording belongs to the UI layer, and
/// keeping it there stops the copy rules in D-015 from being restated in three
/// places.
///
/// More than one can apply at once, which is why Home takes a list. A profile
/// whose settings will not decode *and* whose off-policy content was just
/// removed has two true things to be told, and `plan.md` §18.1 requires
/// preference uncertainty and data uncertainty to be reported separately rather
/// than collapsed into whichever is judged more severe.
enum RetentionAlert {
  none,

  /// Startup found content stored under a non-ON preference and removed it.
  /// Session-scoped: it reports something that just happened (`plan.md` §21
  /// step 5), not a standing condition.
  legacyDataRemoved,

  /// Neither the OFF preference nor the removal could be confirmed.
  preferenceAndDataUnresolved,

  /// Content could not be confirmed gone. Never say it was removed.
  dataMayRemain,

  /// Content is confirmed gone but the choice may not survive a future visit.
  preferenceMayNotPersist,

  /// The stored settings record could not be read, so the saved choice is
  /// unknown and this session fails safe to OFF.
  preferenceUnreadable,

  /// No browser storage is open at all, so nothing can be kept, read, or
  /// removed by Saudo in this session.
  ///
  /// Kept apart from [dataMayRemain] on purpose: that alert tells the user to
  /// try removing again, and here no removal control could ever work. The only
  /// truthful remedy left is the browser's own site-data control.
  storageUnavailable,
}

/// Everything Home needs to render the retention surface, and nothing else.
///
/// Derived state, computed in one place from the live store and controller, so
/// the widget layer never has to work out for itself what may truthfully be
/// claimed. In particular it is derived from `store.effectivePolicy` rather than
/// from the startup snapshot, which goes stale the moment the user enables
/// retention.
class RetentionHomeState {
  const RetentionHomeState({
    required this.keepForNextTime,
    required this.continueOffer,
    required this.alerts,
    required this.recovery,
    this.offPolicyResidue = false,
    this.storageAvailable = true,
    this.documentLabel,
    this.busy = false,
  });

  /// The position of the `Keep for next time` control.
  final bool keepForNextTime;

  final ContinueOffer continueOffer;

  /// Everything true about retention state right now, in the order it should
  /// be read. Empty when there is nothing to say.
  final List<RetentionAlert> alerts;

  /// Stored content exists but no document is product-accessible, so Home shows
  /// the generic recovery state: no identity, no continue, no reader route.
  final bool recovery;

  /// Stored content exists that no retained document governs, so the generic
  /// removal control is offered - with or without a document in memory.
  ///
  /// Wider than [recovery]. After a failed ON to OFF removal the document stays
  /// readable in memory for this page lifetime (`plan.md` §19.3 step 6), so
  /// there is a document on screen *and* data left behind. That state still has
  /// to offer a way to try the removal again; otherwise Home would tell the
  /// user to retry a control it is not showing (D-015).
  final bool offPolicyResidue;

  /// Whether any browser storage is open. When it is not, nothing can be kept
  /// and no removal can be attempted, so neither is offered.
  final bool storageAvailable;

  /// The stored document's existing bounded identity. Set only for
  /// [ContinueOffer.retained] and [ContinueOffer.retainedOutOfDate]; never in
  /// [recovery], per D-015.
  final String? documentLabel;

  /// A retention operation is in flight, so its controls are disabled.
  final bool busy;

  /// Whether the retention choice may be changed right now.
  ///
  /// Only the ON direction is ever blocked by stored data: D-010 forbids
  /// persisting or confirming ON while off-policy data is unresolved, but
  /// turning retention OFF is the privacy-protective direction and removes data
  /// itself, so it stays available. Nothing can be changed without storage.
  bool get canChangePreference =>
      !busy && storageAvailable && (keepForNextTime || !offPolicyResidue);
}

/// Owns the retention policy and every transition that changes it.
///
/// This is the seam `plan.md` §24 asks for: the [Store] holds the durable
/// primitives and enforces the write gate that no call site can bypass, while
/// this class holds the ordering, the interlock and the truth rules. Keeping
/// them apart means the sequences in §19 can be read and reviewed in one place
/// instead of being distributed across the persistence primitives.
class RetentionController {
  RetentionController(this._store);

  final RetentionStore _store;

  /// Whether off-policy data blocks enabling retention.
  ///
  /// Delegated to the store, which owns it: the controller is deliberately
  /// stateless so that reopening storage resets everything the interlock
  /// depends on, and so a replacement controller over the same store cannot
  /// disagree with it about whether cleanup is outstanding.
  bool get offPolicyDataUnresolved => _store.offPolicyDataUnresolved;

  RetentionPolicy get effectivePolicy => _store.effectivePolicy;

  /// Resolves the effective policy for this page lifetime and, when the stored
  /// content is off-policy, attempts to remove it before anything can reach it.
  ///
  /// The order matters and is the reason this runs before the first frame: the
  /// policy and the raw-content boundary must both be settled before any route
  /// that could expose a retained document is constructible.
  Future<StartupResolution> resolveStartup() async {
    final load = _store.loadSettingsResult();

    // Fail safe. An unreadable settings record resolves to OFF, so a profile
    // whose preference cannot be read never retains content by accident.
    final storedOn = load.storedKeepForNextTime;
    final rawPresence = _store.rawContentPresence();

    // Content is off-policy when it exists while the effective preference is
    // not a trustworthy ON. That covers missing field, explicit OFF, unreadable
    // settings and unavailable storage in one condition.
    final offPolicy = !storedOn && rawPresence != RawKeyPresence.absent;

    CleanupOutcome? cleanup;
    if (offPolicy) {
      // Policy is already OFF here, so the store's gate is suppressing new
      // content writes before this runs.
      _store.applyResolvedPolicy(RetentionPolicy.off);
      cleanup = await _store.removeRetainedContent();
      _store.setOffPolicyDataUnresolved(!cleanup.isConfirmedAbsent);
    }

    final effective = storedOn && !offPolicy
        ? RetentionPolicy.on
        : RetentionPolicy.off;
    _store.applyResolvedPolicy(effective);

    return StartupResolution(
      effectivePolicy: effective,
      settingsLoad: load,
      rawContentPresentAtStartup: rawPresence,
      legacyRecord:
          load.outcome == SettingsReadOutcome.loaded &&
          !load.retentionFieldPresent &&
          rawPresence == RawKeyPresence.present,
      cleanup: cleanup,
    );
  }

  /// OFF to ON, following `plan.md` §19.2.
  ///
  /// [document] and [position] are the current in-memory reading state, which
  /// is what an enable is allowed to retain. Nothing that was already on disk
  /// under an earlier policy can be adopted by this transition.
  Future<RetentionTransitionResult> enable({
    required Settings current,
    MarkdownDocument? document,
    ReadingPosition? position,
  }) async {
    // 1-2. Interlock. Any unresolved off-policy data must be gone before ON can
    // be persisted, otherwise enabling retention would silently reclassify data
    // the user never chose to keep.
    if (offPolicyDataUnresolved ||
        _store.rawContentPresence() != RawKeyPresence.absent) {
      final retry = await _store.removeRetainedContent();
      _store.setOffPolicyDataUnresolved(!retry.isConfirmedAbsent);
      if (offPolicyDataUnresolved) {
        return RetentionTransitionResult.blocked(cleanup: retry);
      }
    }

    // 3. Establish the ordering boundary, then persist the preference. The
    // store bumps the settings generation on every save, so an older settings
    // write still in flight cannot land on top of this one.
    final preference = await _store.saveSettings(
      current.copyWith(keepForNextTime: true),
    );

    if (!preference.isConfirmed) {
      // The preference could not be confirmed, so a future visit may still run
      // under OFF. Retaining content that no confirmed preference governs would
      // be exactly the exposure default-OFF exists to prevent, so nothing is
      // written and effective policy stays OFF.
      return RetentionTransitionResult(
        requested: RetentionPolicy.on,
        effectivePolicy: RetentionPolicy.off,
        preferenceOutcome: preference,
      );
    }

    // 4-5. Only now may content be written. Turning the gate on precedes the
    // saves because the store refuses content writes under OFF by design.
    _store.applyResolvedPolicy(RetentionPolicy.on);

    WriteOutcome? documentOutcome;
    WriteOutcome? positionOutcome;
    if (document != null) {
      documentOutcome = await _store.saveDocument(document);
      if (position != null && position.documentId == document.id) {
        positionOutcome = await _store.savePosition(position);
      }
    }

    // 6-7. Report the parts separately; the combined claim is derived, not
    // asserted, and requires every part above to have been confirmed.
    return RetentionTransitionResult(
      requested: RetentionPolicy.on,
      effectivePolicy: RetentionPolicy.on,
      preferenceOutcome: preference,
      documentOutcome: documentOutcome,
      positionOutcome: positionOutcome,
    );
  }

  /// ON to OFF, following `plan.md` §19.3.
  Future<RetentionTransitionResult> disable({required Settings current}) async {
    // 1-2. Effective policy goes OFF first and synchronously. From this point
    // the store suppresses new content writes, and the generation bump inside
    // removeRetainedContent invalidates any write already queued under ON.
    _store.applyResolvedPolicy(RetentionPolicy.off);

    // 3. Persist OFF.
    final preference = await _store.saveSettings(
      current.copyWith(keepForNextTime: false),
    );

    // 4-5. Delete regardless of how the preference write went: a failed
    // preference write is not a reason to leave content behind.
    final cleanup = await _store.removeRetainedContent();
    _store.setOffPolicyDataUnresolved(!cleanup.isConfirmedAbsent);

    return RetentionTransitionResult(
      requested: RetentionPolicy.off,
      effectivePolicy: RetentionPolicy.off,
      preferenceOutcome: preference,
      cleanup: cleanup,
    );
  }

  /// `Remove saved document` while ON, following `plan.md` §20.3.
  ///
  /// Deliberately does not touch the preference: removing this document and
  /// choosing what happens to future ones are separate intentions (D-014).
  ///
  /// [documentId] is the document being removed. Passing it suppresses any
  /// further content write for that document, which is what makes the verified
  /// absence hold rather than being undone a moment later by the reader's
  /// `dispose()` position flush.
  Future<CleanupOutcome> removeSavedDocument({String? documentId}) async {
    final cleanup = await _store.removeRetainedContent(
      suppressDocumentId: documentId,
    );
    if (!cleanup.isConfirmedAbsent) {
      // Data that could not be removed is off-policy for any later enable, even
      // though the preference itself is still legitimately ON.
      _store.setOffPolicyDataUnresolved(true);
    }
    return cleanup;
  }

  /// `Remove unreadable saved data`, following `plan.md` §20.4.
  ///
  /// Mechanically the same verified two-key removal as [removeSavedDocument];
  /// they are separate methods because they are separate user-facing controls
  /// reached from different states, and D-015 requires the recovery path to
  /// stay distinct rather than becoming a synonym for the retention choice.
  Future<CleanupOutcome> removeUnreadableData({String? documentId}) async {
    final cleanup = await _store.removeRetainedContent(
      suppressDocumentId: documentId,
    );
    _store.setOffPolicyDataUnresolved(!cleanup.isConfirmedAbsent);
    return cleanup;
  }
}

/// The persistence surface [RetentionController] depends on.
///
/// Declared here rather than in `store.dart` so that the controller stays pure
/// Dart and can be driven directly by a test double, without the controller and
/// the Hive-backed store having to know about each other.
abstract class RetentionStore {
  RetentionPolicy get effectivePolicy;

  /// Whether stored content exists that no confirmed ON preference governs.
  bool get offPolicyDataUnresolved;

  void setOffPolicyDataUnresolved(bool value);

  void applyResolvedPolicy(RetentionPolicy policy);

  SettingsLoadResult loadSettingsResult();

  Future<WriteOutcome> saveSettings(Settings settings);

  RawKeyPresence rawContentPresence();

  Future<WriteOutcome> saveDocument(MarkdownDocument document);

  Future<WriteOutcome> savePosition(ReadingPosition position);

  Future<CleanupOutcome> removeRetainedContent({String? suppressDocumentId});
}
