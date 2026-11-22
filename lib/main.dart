import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'document_session.dart';
import 'document_tabs.dart';
import 'file_loader.dart';
import 'file_drop.dart';
import 'han_script.dart';
import 'home_screen.dart';
import 'markdown_theme.dart';
import 'models.dart';
import 'paste_sheet.dart';
import 'reader_screen.dart';
import 'retention.dart';
import 'settings_screen.dart';
import 'store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Everything is loaded before the first frame so there is no loading state and
  // no flash of the wrong colour scheme.
  await store.init();

  // DF-039: the retention boundary is resolved before the first frame, not
  // after it. Any content stored under a preference that is missing, OFF or
  // unreadable is removed here, so the frame that follows cannot be built from
  // a document the user did not choose to keep.
  final startup = await retention.resolveStartup();

  runApp(
    MarkdownViewerApp(
      initialSettings: startup.settingsLoad.settings,
      // Only read back under a confirmed ON policy. Reading it under OFF and
      // then declining to show it would still have constructed the document in
      // memory from off-policy data; not reading it is the containment.
      initialDocument: startup.effectivePolicy == RetentionPolicy.on
          ? store.loadDocument()
          : null,
      startup: startup,
    ),
  );
}

class MarkdownViewerApp extends StatefulWidget {
  const MarkdownViewerApp({
    super.key,
    required this.initialSettings,
    required this.initialDocument,
    required this.startup,
    this.fileDropMount = mountFileDrop,
  });

  final Settings initialSettings;
  final MarkdownDocument? initialDocument;

  /// What startup resolved about retention, before the first frame.
  final StartupResolution startup;

  /// Dependency seam for deterministic native-independent intake tests.
  final FileDropMount fileDropMount;

  @override
  State<MarkdownViewerApp> createState() => _MarkdownViewerAppState();
}

class _MarkdownViewerAppState extends State<MarkdownViewerApp> {
  late Settings _settings = widget.initialSettings;

  /// Issues the ID of every document created in this page lifetime.
  final DocumentIdAllocator _ids = DocumentIdAllocator();

  /// The open documents, the active one, and where each was read to.
  ///
  /// Replaced, never mutated: every change is a new value from one of the
  /// session's operations. It holds every open document, and which of them is
  /// active when any are open.
  late DocumentSession _session = _initialSession();

  /// The document being read. Single-document code reads this, unchanged.
  MarkdownDocument? get _document => _session.active;

  /// Where the active document was read to in this page lifetime, whether or
  /// not it was stored.
  ///
  /// Under OFF nothing durable is written, and §18.2 still requires returning
  /// Home and continuing to land where the reader was. Under ON it is still
  /// this, not the stored copy, that the reader resumes from: the stored copy
  /// can only be the same or older.
  ReadingPosition? get _sessionPosition {
    final document = _document;
    return document == null ? null : _session.positions[document.id];
  }

  /// The session this page lifetime starts with.
  ///
  /// A document restored from storage brings its stored position, read once
  /// here and only under a confirmed ON policy. From then on positions flow one
  /// way, from the session to storage, and storage is never consulted again.
  DocumentSession _initialSession() {
    final document = widget.initialDocument;
    if (document == null) return DocumentSession.empty;
    // The whole stored set, its positions and its active document, decoded
    // only under a confirmed ON policy (D-1, I-7).
    final retained = store.effectivePolicy == RetentionPolicy.on
        ? store.loadRetained()
        : null;
    if (retained != null && retained.activeId == document.id) {
      _ids.reserve(retained.documents.map((d) => d.id));
      return DocumentSession.restored(
        // The active document is the one startup already decoded and passed
        // in; the rest come from the same stored set.
        documents: [
          for (final stored in retained.documents)
            stored.id == document.id ? document : stored,
        ],
        activeId: retained.activeId,
        positions: retained.positions,
      );
    }
    _ids.reserve([document.id]);
    return DocumentSession.restored(
      documents: [document],
      activeId: document.id,
    );
  }

  /// What the content writers capture: the session, at the moment they run.
  RetainedSnapshot _retainedSnapshot() => RetainedSnapshot(
    documents: _session.documents,
    activeId: _session.activeId,
    positions: _session.positions,
    documentsRevision: _session.documentsRevision,
    readingStateRevision: _session.readingStateRevision,
  );

  /// Re-derives what Home claims about saved state when a receipt lands.
  ///
  /// Receipts usually land while Flutter is idle - a write completing after
  /// everything on screen has settled - and then a plain `setState` is right:
  /// it schedules the frame itself. One can also land while the tree is being
  /// built or finalized, for example from a reader's disposal report, when a
  /// rebuild cannot be requested; then it waits for the next frame, and that
  /// frame is requested explicitly so the claim cannot stay stale.
  void _savedStateChanged() {
    if (!mounted || _disposing) return;
    final binding = WidgetsBinding.instance;
    if (binding.schedulerPhase != SchedulerPhase.persistentCallbacks) {
      setState(() {});
      return;
    }
    binding.addPostFrameCallback((_) {
      if (mounted && !_disposing) setState(() {});
    });
    binding.scheduleFrame();
  }

  /// A new document's ID: unused by any open document, and never one restored
  /// at startup.
  String _newDocumentId() => _ids.allocate(_session.ids);

  /// The reader reported where reading reached.
  ///
  /// Recorded against the reporting document's ID. A report for a document
  /// that is no longer open - a replaced document's reader reports once more
  /// as it is disposed, after the replacement - is ignored, and nothing is
  /// stored for it. A changed place requests a reading-state write, which
  /// captures the session when it runs; the store's retention gate decides
  /// whether anything is written.
  ///
  /// No `setState`: the reader reads its position once, at mount, so nothing
  /// on screen depends on this, and the disposal report arrives while the tree
  /// is being finalized, when a rebuild cannot be requested.
  void _onPositionReported(ReadingPosition position) {
    if (!_session.contains(position.documentId)) return;
    final next = _session.recordPosition(position);
    if (identical(next, _session)) return;
    _session = next;
    unawaited(store.requestReadingStateWrite());
  }

  /// Which of the two screens is showing.
  ///
  /// This one boolean is the whole navigation model. Home is not a pushed
  /// route, so returning to it cannot lose the reader's state.
  ///
  /// Always starts at Home now. DF-039's accepted boundary is that retaining a
  /// document, resuming it, and being dropped into it are three different
  /// things: a retained document earns a `Continue reading` action on Home, not
  /// an automatic reader on launch.
  bool _atHome = true;

  /// Whether Home is showing Settings. Set only from Home, and Settings only
  /// ever returns there, so it has no meaning outside the Home route.
  bool _atSettings = false;

  /// What Home says about retention state, if anything.
  late List<RetentionAlert> _alerts = _initialAlerts();

  /// A retention operation is in flight.
  bool _busy = false;

  /// An appearance change arrived while a retention operation was running.
  /// It shows at once and is stored when the operation finishes, so it cannot
  /// race the preference write that operation makes (D-013).
  bool _settingsWriteDeferred = false;

  final _navigatorKey = GlobalKey<NavigatorState>();
  late final _routeObserver = _EntryRouteObserver(_modalRouteChanged);
  late final FileDropLease _dropLease;
  _IntakeOperation? _intake;
  int _documentGeneration = 0;
  int _routeGeneration = 0;
  bool _ownedIntakeModal = false;
  bool _disposing = false;

  /// Whether a dropped file may be loaded now: on Home (not Settings) or on
  /// the Reader with nothing above it (DF-085), and only while no load or
  /// retention operation is running. Elsewhere a file drop is still
  /// suppressed, so the browser never navigates to the file, but ignored.
  bool get _dropEligible =>
      mounted &&
      !_disposing &&
      !_atSettings &&
      !_busy &&
      _intake == null &&
      !(_navigatorKey.currentState?.canPop() ?? true);

  @override
  void initState() {
    super.initState();
    if (kDf020Timing) Df020Timing._app = this;
    store.registerRetainedSource(_retainedSnapshot);
    store.savedState.addListener(_savedStateChanged);
    _dropLease = widget.fileDropMount(
      eligible: () => _dropEligible,
      onHover: (_) {},
      onCandidates: (candidates) {
        final context = _navigatorKey.currentContext;
        if (context != null && _dropEligible) {
          unawaited(
            _acquireBatch(context, () async => candidates, dropped: true),
          );
        }
      },
      onRejected: _report,
    );
  }

  @override
  void dispose() {
    _disposing = true;
    store.savedState.removeListener(_savedStateChanged);
    store.unregisterRetainedSource(_retainedSnapshot);
    _dropLease.dispose();
    _intake = null;
    super.dispose();
  }

  void _modalRouteChanged() {
    if (_ownedIntakeModal) return;
    _routeGeneration++;
  }

  _IntakeOperation? _beginIntake() {
    if (_navigatorKey.currentState?.canPop() ?? true) return null;
    if (_busy || _intake != null) {
      _report('Finish the current operation first.');
      return null;
    }
    final operation = _IntakeOperation(_documentGeneration, _routeGeneration);
    setState(() {
      _intake = operation;
    });
    return operation;
  }

  bool _validIntake(_IntakeOperation operation) =>
      mounted &&
      identical(_intake, operation) &&
      _documentGeneration == operation.documentGeneration &&
      _routeGeneration == operation.routeGeneration;

  bool _beginOpening(_IntakeOperation operation) {
    if (!_validIntake(operation)) return false;
    setState(() {
      operation.committing = true;
      _busy = true;
    });
    return true;
  }

  void _endIntake(_IntakeOperation operation) {
    if (!mounted || !identical(_intake, operation)) return;
    setState(() {
      _intake = null;
      if (operation.committing) _busy = false;
    });
    _persistDeferredSettings();
  }

  Future<T> _intakeModal<T>(Future<T> Function() action) async {
    _ownedIntakeModal = true;
    try {
      return await action();
    } finally {
      _ownedIntakeModal = false;
    }
  }

  /// Messages are shown through this rather than through the ambient
  /// [ScaffoldMessenger]. This State sits *above* the [MaterialApp] that
  /// provides one, so looking one up from its context finds nothing at all -
  /// and a truthful result the user never sees is no better than an untruthful
  /// one.
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  /// Both halves of the startup outcome, because both can be true at once.
  ///
  /// A v1.1.0 profile whose settings record is also corrupt has had its content
  /// removed *and* cannot honour a saved choice. Reporting only the more severe
  /// of the two would leave the user unable to explain what they are seeing.
  List<RetentionAlert> _initialAlerts() {
    final startup = widget.startup;
    return [
      if (startup.preferenceUncertain) RetentionAlert.preferenceUnreadable,
      if (startup.legacyContentRemoved) RetentionAlert.legacyDataRemoved,
      if (startup.offPolicyDataUnresolved) RetentionAlert.dataMayRemain,
    ];
  }

  // --- Retention ------------------------------------------------------------

  /// Stored content that Saudo can act on: present, or unreadable while storage
  /// is open.
  ///
  /// An unreadable key counts. A presence read can fail while a delete would
  /// still succeed, so hiding the removal control there would strand the user
  /// with a message telling them to retry something that is not on screen.
  /// With no storage open at all there is nothing any control could act on, and
  /// that case is reported separately instead.
  bool get _hasResidue {
    final presence = store.rawContentPresence();
    return presence == RawKeyPresence.present ||
        (presence == RawKeyPresence.indeterminate && store.isAvailable);
  }

  /// Stored data exists but no document is product-accessible.
  ///
  /// Covers a record that will not decode, an orphaned position, and content a
  /// cleanup could not verify as gone. All get the same generic presentation:
  /// no identity, no continue, no reader route (D-015).
  bool get _inRecovery => _document == null && _hasResidue;

  /// What Home may offer as a way back in.
  ///
  /// `retained` requires the live policy to be ON, a committed `document` key
  /// holding only documents that are open now, and both keys confirmed stored
  /// at the session's current revisions (§5.6). `retainedOutOfDate` is that
  /// same stored set when either key is unconfirmed or behind. Stored content
  /// that is not a subset of the open documents is not this session's saved
  /// state - it is residue - and earns no saved claim at all.
  ContinueOffer get _continueOffer {
    final document = _document;
    if (document == null) return ContinueOffer.none;
    if (store.effectivePolicy != RetentionPolicy.on ||
        store.rawKeyPresence(Store.documentKey) != RawKeyPresence.present) {
      return ContinueOffer.currentSession;
    }
    final stored = store.committedDocumentIds;
    if (stored == null || !stored.every(_session.contains)) {
      return ContinueOffer.currentSession;
    }
    final current =
        store.confirmedDocumentsRevision == _session.documentsRevision &&
        store.confirmedReadingStateRevision == _session.readingStateRevision;
    return current ? ContinueOffer.retained : ContinueOffer.retainedOutOfDate;
  }

  bool _governedBy(ContinueOffer offer) =>
      offer == ContinueOffer.retained ||
      offer == ContinueOffer.retainedOutOfDate;

  /// Stored data that no retained document accounts for.
  bool get _offPolicyResidue => _hasResidue && !_governedBy(_continueOffer);

  /// The alerts Home shows, reconciled with what storage holds *now*.
  ///
  /// `_alerts` records what the last operation reported; this re-derives the
  /// data half from live state, so an alert about remaining data cannot outlive
  /// the data, and replacing the document cannot hide data that is still there.
  List<RetentionAlert> get _visibleAlerts {
    if (!store.isAvailable) return const [RetentionAlert.storageUnavailable];

    final residue = _hasResidue;
    final visible = <RetentionAlert>[];
    for (final alert in _alerts) {
      switch (alert) {
        case RetentionAlert.dataMayRemain:
          if (residue) visible.add(alert);
        case RetentionAlert.preferenceAndDataUnresolved:
          // Once the data is gone only the preference half is still true.
          visible.add(residue ? alert : RetentionAlert.preferenceMayNotPersist);
        default:
          visible.add(alert);
      }
    }
    if (_offPolicyResidue &&
        !visible.contains(RetentionAlert.dataMayRemain) &&
        !visible.contains(RetentionAlert.preferenceAndDataUnresolved)) {
      visible.add(RetentionAlert.dataMayRemain);
    }
    return visible;
  }

  /// Derived from the live store, never from the startup snapshot, which goes
  /// stale the moment the user changes the preference.
  RetentionHomeState get _retentionHomeState {
    final offer = _continueOffer;
    return RetentionHomeState(
      keepForNextTime: store.effectivePolicy == RetentionPolicy.on,
      continueOffer: offer,
      alerts: _visibleAlerts,
      recovery: _inRecovery,
      offPolicyResidue: store.isAvailable && _offPolicyResidue,
      storageAvailable: store.isAvailable,
      documentLabel: _governedBy(offer) ? _document?.identityLabel : null,
      savedDocumentCount: _session.documents.length,
      busy: _busy || _intake != null,
    );
  }

  /// Whether a document write the user was promised under ON did not land,
  /// so they must be told. Under OFF nothing is promised.
  bool _unsavedUnderOn(WriteReceipt receipt) =>
      store.effectivePolicy == RetentionPolicy.on &&
      receipt.outcome != WriteOutcome.suppressedByPolicy &&
      !receipt.confirmed;

  void _onSettingsChanged(Settings settings) {
    // Appearance only. The retention choice changes through its own
    // transition and nothing else: what arrives here comes from a snapshot the
    // appearance controls took when they were built, which can predate the
    // latest choice, and storing that snapshot's copy of it would leave the
    // stored preference disagreeing with the policy the store enforces.
    final next = _settings.copyWith(
      appearance: settings.appearance,
      fontScale: settings.fontScale,
      wrapCode: settings.wrapCode,
    );
    setState(() => _settings = next);
    if (_busy) {
      _settingsWriteDeferred = true;
      return;
    }
    unawaited(_persistSettings(next));
  }

  /// Stores an appearance change held back while a retention operation ran,
  /// merged onto the settings as that operation left them.
  void _persistDeferredSettings() {
    if (!_settingsWriteDeferred) return;
    _settingsWriteDeferred = false;
    unawaited(_persistSettings(_settings));
  }

  /// Appearance settings are never gated on retention policy: they describe the
  /// app, not the document, and must survive whatever happens to content.
  Future<void> _persistSettings(Settings settings) async {
    final outcome = await store.saveSettings(settings);
    // `unavailable` is not reported per change: the standing storage alert on
    // Home already says nothing can be stored, and a slider drag would otherwise
    // raise one message per step.
    if (!outcome.isConfirmed &&
        outcome != WriteOutcome.superseded &&
        outcome != WriteOutcome.unavailable &&
        // Not confirmed in time is not the same as not saved; it is not
        // reported per change either, for the same reason as `unavailable`.
        outcome != WriteOutcome.indeterminate &&
        mounted) {
      _report('Your settings could not be saved in this browser.');
    }
  }

  /// Shows the result of the action just taken, replacing any earlier result.
  ///
  /// Replacing rather than queueing: a retry that succeeds must say so now, not
  /// four seconds later behind the failure it just resolved.
  void _report(String message) {
    _messengerKey.currentState
      // Drops anything queued, then removes the showing bar outright:
      // `clearSnackBars` alone would animate it out first and make the new
      // result wait behind the old one.
      ?..clearSnackBars()
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// The retention choice. Every outcome below is reported for what it is,
  /// separately for the preference and for the content (D-013).
  Future<void> _setKeepForNextTime(bool value) async {
    if (_busy || _intake != null) return;
    setState(() => _busy = true);

    final result = value
        ? await retention.enable(current: _settings)
        : await retention.disable(current: _settings);

    if (!mounted) return;
    setState(() {
      _settings = _settings.copyWith(
        keepForNextTime: result.effectivePolicy == RetentionPolicy.on,
      );
      _alerts = _alertsFor(result);
      _busy = false;
    });
    _persistDeferredSettings();
    _report(_messageFor(result));
  }

  List<RetentionAlert> _alertsFor(RetentionTransitionResult result) {
    if (result.blockedByOffPolicyData) return [RetentionAlert.dataMayRemain];
    if (result.requested == RetentionPolicy.off) {
      final dataGone = result.contentConfirmedAbsent;
      final choiceKept = result.preferenceConfirmed;
      if (dataGone && choiceKept) return const [];
      if (!dataGone && !choiceKept) {
        return [RetentionAlert.preferenceAndDataUnresolved];
      }
      return [
        dataGone
            ? RetentionAlert.preferenceMayNotPersist
            : RetentionAlert.dataMayRemain,
      ];
    }
    // Enabling: a preference that could not be written is the only standing
    // condition worth a persistent line. A failed document save is reported in
    // the transient message and does not describe the state of the browser.
    return result.preferenceConfirmed
        ? const []
        : [RetentionAlert.preferenceMayNotPersist];
  }

  /// The transient result of the action just taken.
  ///
  /// `Kept for next time` and `Removed from this browser` are the two claims
  /// D-015 binds hardest, and neither is said unless its condition is verified.
  String _messageFor(RetentionTransitionResult result) {
    if (result.blockedByOffPolicyData) {
      return 'Saved reading data must be removed from this browser first.';
    }
    if (result.requested == RetentionPolicy.on) {
      if (result.preferenceOutcome == WriteOutcome.indeterminate) {
        // Issued but not confirmed in time: it may yet land, so "could not be
        // saved" would be untrue. What is true is the D-013 statement.
        return 'Your choice may not be kept for your next visit.';
      }
      if (!result.preferenceConfirmed) {
        return 'Your choice could not be saved in this browser.';
      }
      if (result.keptForNextTime) return 'Kept for next time.';
      if (result.documentOutcome == null) {
        return 'The next document you open will be kept for next time.';
      }
      return 'This document could not be saved in this browser.';
    }
    if (result.removedAndWillNotReturn) return 'Removed from this browser.';
    if (result.contentConfirmedAbsent) {
      return 'Removed from this browser, but your choice may not be saved.';
    }
    return 'Saved reading data could not be removed.';
  }

  /// `Remove saved document(s)`. Separate from the preference by design:
  /// removing what is saved says nothing about what happens to the next
  /// document (D-014). Under ON every open document is saved, so all of them
  /// are removed, verified gone, and closed (D-10).
  Future<void> _removeSavedDocument(BuildContext context) async {
    final current = _document;
    if (_busy || _intake != null || current == null) return;
    final ids = _session.ids;
    final others = ids.length - 1;

    setState(() {
      _busy = true;
    });
    final confirmed = await _confirmRemoval(
      context,
      title: others == 0 ? 'Remove saved document?' : 'Remove saved documents?',
      body: others == 0
          ? '"${current.identityLabel}" and your reading place in it will be '
                'removed from this browser. "Keep for next time" stays on, so '
                'the next document you open will still be kept.'
          : '"${current.identityLabel}" and $others other '
                '${others == 1 ? 'document' : 'documents'}, and your reading '
                'places in them, will be removed from this browser and closed. '
                '"Keep for next time" stays on, so the next document you open '
                'will still be kept.',
    );
    if (!mounted) return;
    if (!confirmed) {
      setState(() => _busy = false);
      _persistDeferredSettings();
      return;
    }
    final outcome = await retention.removeSavedDocument(documentIds: ids);
    if (!mounted) return;

    setState(() {
      _busy = false;
      if (outcome.isConfirmedAbsent) {
        // The user chose removal, not merely a change of preference, so the
        // documents and their reading places go from this session too, and
        // Home is empty (§20.3; D-10).
        _documentGeneration++;
        for (final id in ids) {
          if (_session.contains(id)) _session = _session.close(id).session;
        }
        _atHome = true;
        _alerts = const [];
      } else {
        _alerts = [RetentionAlert.dataMayRemain];
      }
    });
    _persistDeferredSettings();
    _report(
      outcome.isConfirmedAbsent
          ? 'Removed from this browser.'
          : 'Saved reading data could not be removed.',
    );
  }

  /// `Remove unreadable saved data`. Carries no identity: in this state there is
  /// no document to name, and naming one would disclose something the app
  /// cannot open (D-015).
  Future<void> _removeRetainedData(BuildContext context) async {
    if (_busy || _intake != null) return;

    setState(() {
      _busy = true;
    });
    final confirmed = await _confirmRemoval(
      context,
      title: 'Remove saved reading data?',
      body:
          'Saved document data and reading place will be removed from this '
          'browser. Your appearance settings are not affected.',
    );
    if (!mounted) return;
    if (!confirmed) {
      setState(() => _busy = false);
      _persistDeferredSettings();
      return;
    }
    final outcome = await retention.removeUnreadableData();
    if (!mounted) return;

    setState(() {
      _busy = false;
      _alerts = outcome.isConfirmedAbsent
          ? const []
          : [RetentionAlert.dataMayRemain];
    });
    _persistDeferredSettings();
    _report(
      outcome.isConfirmedAbsent
          ? 'Removed from this browser.'
          : 'Saved reading data could not be removed.',
    );
  }

  Future<bool> _confirmRemoval(
    BuildContext context, {
    required String title,
    required String body,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// Persists the document's script preference and re-renders in place.
  ///
  /// `updatedAt` is deliberately **not** passed. The reader is keyed on
  /// `id:updatedAt` below, so bumping it would remount the reader and throw the
  /// user back to their restored scroll position on what is only a presentation
  /// change (plan.md §5.5 fact 4, §5.7.2). Changing the language is a re-render,
  /// not a reload: nothing here reloads the page, re-reads the document from the
  /// store, or re-pushes a route.
  Future<void> _setScriptPreference(DocumentScriptPreference next) async {
    final current = _document;
    if (_busy ||
        _intake != null ||
        current == null ||
        current.scriptPreference == next) {
      return;
    }
    setState(() => _busy = true);

    final updated = current.copyWith(scriptPreference: next);
    // The session first, then the write, which captures it (§4.5). Governed by
    // the store's retention gate: under OFF nothing is written and the
    // preference stays in memory for the current session only.
    setState(() {
      _documentGeneration++;
      _session = _session.updateDocument(updated);
    });
    final receipt = await store.requestDocumentsWrite();
    if (!mounted) return;
    final unsaved = _unsavedUnderOn(receipt);
    setState(() => _busy = false);
    // Same rule as an edit: under ON the user has been told this document is
    // kept, so a preference that did not save has to be said out loud.
    _persistDeferredSettings();
    if (unsaved) _report('Your changes could not be saved in this browser.');
  }

  // --- Navigation -----------------------------------------------------------

  void _navigate(VoidCallback update) {
    if (_busy || (_intake?.committing ?? false)) return;
    setState(() {
      _routeGeneration++;
      update();
    });
  }

  void _returnHome() => _navigate(() => _atHome = true);
  void _openSettings() => _navigate(() => _atSettings = true);
  void _closeSettings() => _navigate(() => _atSettings = false);
  void _continueReading() => _navigate(() => _atHome = false);

  // --- Document entry -------------------------------------------------------

  /// Asks before a loaded file replaces the open document with its name (M2).
  ///
  /// [offerSameForOthers] shows "Do the same for other documents", which is
  /// offered only while more confirmations remain (S11-06). Returns null on
  /// Cancel; otherwise whether the remaining matches are accepted without
  /// asking.
  Future<bool?> _confirmReplace(
    BuildContext context,
    MarkdownDocument current, {
    required bool offerSameForOthers,
  }) async {
    var sameForOthers = false;
    final message = Text(
      '"${current.identityLabel}" and your place in it will be removed '
      'from this device.',
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Replace current document?'),
          content: offerSameForOthers
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    message,
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      value: sameForOthers,
                      onChanged: (value) =>
                          setDialogState(() => sameForOthers = value ?? false),
                      title: const Text('Do the same for other documents'),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                )
              : message,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Replace'),
            ),
          ],
        ),
      ),
    );
    return confirmed == true ? sameForOthers : null;
  }

  /// Applies a checked and confirmed batch (§4.5 steps 7 and 8).
  ///
  /// [files] are in D-2 order, and [matches] holds, for each, the open
  /// document with its name, if any. A replacement takes that document's place
  /// with a new ID, so its reading place goes with the old copy and the new
  /// copy starts at the top. The first file becomes active.
  ///
  /// Under ON, a batch that replaces commits only inside the removal of every
  /// replaced document's saved copy, once that removal is verified (E-1,
  /// §5.5). If it is not verified nothing changes: the open set is written
  /// again and the error makes no removal claim. Under OFF the whole-store
  /// removal runs first, as a replacement has always done, so residue keeps
  /// being cleaned and flagged (§5.4); suppressing the replaced IDs closes the
  /// same hole `Remove saved document` has, for a flush issued behind it.
  Future<void> _applyBatch(
    List<LoadedFile> files,
    List<MarkdownDocument?> matches,
  ) async {
    final ids = _ids.allocateBatch(files.length, _session.ids);
    final adds = <MarkdownDocument>[];
    final replacements = <String, MarkdownDocument>{};
    for (var i = 0; i < files.length; i++) {
      final document = MarkdownDocument.fromSource(
        files[i].contents,
        id: ids[i],
        sourceName: files[i].name,
      );
      final match = matches[i];
      if (match == null) {
        adds.add(document);
      } else {
        replacements[match.id] = document;
      }
    }

    void commit() {
      if (!mounted || !replacements.keys.every(_session.contains)) return;
      setState(() {
        _documentGeneration++;
        _session = _session.commitBatch(
          adds: adds,
          replacements: replacements,
          activeId: ids.first,
        );
        _atHome = false;
        // A load supersedes whatever the last retention operation reported.
        // The exception is a preference that still cannot be written: that
        // describes the browser, not the documents just loaded.
        _alerts = _alerts
            .where((a) => a == RetentionAlert.preferenceMayNotPersist)
            .toList();
      });
      if (kDf020Timing) Df020Timing._applied(ids.first);
    }

    if (replacements.isNotEmpty &&
        store.effectivePolicy == RetentionPolicy.on) {
      final outcome = await store.removeDocuments(
        replacements.keys.toSet(),
        replacing: true,
        onVerified: commit,
      );
      if (outcome != RemovalOutcome.verified) {
        // Nothing changed; the open set is written again (§5.5), and both
        // receipts settle before anything is reported or released.
        final documents = store.requestDocumentsWrite();
        final reading = store.requestReadingStateWrite();
        final documentsReceipt = await documents;
        final readingReceipt = await reading;
        if (!mounted) return;
        final restored = documentsReceipt.confirmed && readingReceipt.confirmed;
        final replaced = [
          for (final match in matches)
            if (match != null) match.identityLabel,
        ];
        _report(
          '${_replacementFailure(files.length, replaced)}'
          '${restored ? '' : ' Saved documents in this browser may be out of date.'}',
        );
        return;
      }
    } else {
      if (replacements.isNotEmpty) {
        final cleanup = await store.removeRetainedContent(
          suppressDocumentIds: replacements.keys,
        );
        if (!mounted) return;
        // Under OFF anything the removal could not clear is off-policy data,
        // and the interlock has to know that before any later attempt to turn
        // ON.
        if (store.effectivePolicy == RetentionPolicy.off &&
            store.isAvailable &&
            !cleanup.isConfirmedAbsent) {
          store.setOffPolicyDataUnresolved(true);
        }
      }
      commit();
    }
    // The writes capture the session that now holds the new documents.
    final saved = store.requestDocumentsWrite();
    unawaited(store.requestReadingStateWrite());
    final receipt = await saved;
    if (!mounted) return;
    // Under ON the user has been told their documents are kept (S09-11).
    if (_unsavedUnderOn(receipt)) {
      _report(
        files.length == 1
            ? 'This document could not be saved in this browser.'
            : 'These documents could not be saved in this browser.',
      );
    }
  }

  /// The S09-13 error: the batch was not loaded, and no removal is claimed.
  static String _replacementFailure(int fileCount, List<String> replaced) {
    if (fileCount == 1) {
      return '"${replaced.single}" was not replaced. Removal of its saved copy '
          'from this browser could not be confirmed.';
    }
    final quoted = [for (final name in replaced) '"$name"'];
    final names = quoted.length == 1
        ? quoted.single
        : '${quoted.sublist(0, quoted.length - 1).join(', ')} and '
              '${quoted.last}';
    return 'These files were not loaded. Removal of the saved '
        '${quoted.length == 1 ? 'copy' : 'copies'} of $names from this '
        'browser could not be confirmed.';
  }

  /// Adds [document] to the open set as the active document (D-4).
  Future<void> _addDocument(MarkdownDocument document) async {
    setState(() {
      _documentGeneration++;
      _session = _session.commitBatch(adds: [document], activeId: document.id);
      _atHome = false;
      _alerts = _alerts
          .where((a) => a == RetentionAlert.preferenceMayNotPersist)
          .toList();
    });
    if (kDf020Timing) Df020Timing._applied(document.id);
    final saved = store.requestDocumentsWrite();
    unawaited(store.requestReadingStateWrite());
    final receipt = await saved;
    if (!mounted) return;
    // Under ON the user has been told their documents are kept (S09-11).
    if (_unsavedUnderOn(receipt)) {
      _report('This document could not be saved in this browser.');
    }
  }

  // --- Switching and closing (D-3, D-6, D-11) ---------------------------------

  /// Whether the tabs, the switcher and every close control are inert: a load,
  /// close or removal is being verified (S10-08).
  bool get _navigationInert => _busy || _intake != null;

  /// Makes [id] the document being read. Never waits on storage: the switch
  /// is in memory, and the reading-state write that records it follows.
  void _activateDocument(String id) {
    if (_navigationInert || !_session.contains(id) || _session.activeId == id) {
      return;
    }
    setState(() {
      _routeGeneration++;
      _session = _session.activate(id);
    });
    if (kDf020Timing) Df020Timing._applied(id);
    unawaited(store.requestReadingStateWrite());
  }

  /// Closes [id] under D-11.
  ///
  /// Under ON the document closes only after its saved copy is verified gone
  /// (D-6, §5.5): the session change runs inside the removal. If it cannot be
  /// verified the document stays open, nothing claims it was removed, and the
  /// open set is written again. Under OFF nothing is stored for it, but the
  /// whole-store removal still runs, as for a replacement, so residue keeps
  /// being cleaned and flagged (§5.4).
  Future<void> _closeDocument(String id) async {
    if (_navigationInert || !_session.contains(id)) return;
    final document = _session.byId(id)!;
    final next = _session.close(id);
    setState(() => _busy = true);

    void applyClose() {
      if (!mounted || !_session.contains(id)) return;
      setState(() {
        _documentGeneration++;
        _routeGeneration++;
        _session = _session.close(id).session;
        if (_session.isEmpty) _atHome = true;
      });
    }

    if (store.effectivePolicy == RetentionPolicy.on) {
      final outcome = await store.removeDocuments(
        {id},
        successorActiveId: next.successor,
        onVerified: applyClose,
      );
      // Verified or not, the open set is written: after a verified close it
      // saves the new set; after a failed one it restores the old.
      final documents = store.requestDocumentsWrite();
      final reading = store.requestReadingStateWrite();
      // Both receipts settle before anything is reported or released (§5.5):
      // awaiting them separately, so a failed documents write cannot skip the
      // wait for the reading state.
      final documentsReceipt = await documents;
      final readingReceipt = await reading;
      final restored = documentsReceipt.confirmed && readingReceipt.confirmed;
      if (!mounted) return;
      setState(() => _busy = false);
      _persistDeferredSettings();
      if (outcome != RemovalOutcome.verified) {
        _report(
          '"${document.identityLabel}" is still open. Its removal from this '
          'browser could not be confirmed.'
          '${restored ? '' : ' Saved documents in this browser may be out of date.'}',
        );
      }
      return;
    }

    final cleanup = await store.removeRetainedContent(suppressDocumentId: id);
    if (!mounted) return;
    if (store.isAvailable && !cleanup.isConfirmedAbsent) {
      store.setOffPolicyDataUnresolved(true);
    }
    applyClose();
    setState(() => _busy = false);
    _persistDeferredSettings();
  }

  Future<void> _showDocuments(BuildContext context) async {
    if (_navigationInert) return;
    final action = await showDocumentsSheet(
      context,
      documents: _session.documents,
      activeId: _session.activeId,
    );
    if (!mounted || action == null) return;
    if (action.close) {
      await _closeDocument(action.id);
    } else {
      _activateDocument(action.id);
    }
  }

  Future<void> _pasteNewDocument(BuildContext context) async {
    final operation = _beginIntake();
    if (operation == null) return;
    try {
      // Paste adds a document; it never replaces one (D-4), so there is
      // nothing to confirm. A pasted document has no filename, so it can never
      // match another (M2).
      final source = await _intakeModal(() => showMarkdownEditor(context));
      if (source == null || !_beginOpening(operation)) return;
      await _addDocument(
        MarkdownDocument.fromSource(source, id: _newDocumentId()),
      );
    } finally {
      _endIntake(operation);
    }
  }

  Future<void> _loadFromFile(BuildContext context) =>
      _acquireBatch(context, pickMarkdownFiles);

  /// Loads picked or dropped files into the open set (§4.5; M5, D-2, D-5,
  /// M2, E-1). Picker and drop share every step.
  ///
  /// Nothing changes until every file has been read and checked, every
  /// matching name confirmed and, under ON, the saved copy of every document
  /// being replaced verified removed. The batch is then applied as one change.
  /// Any failure or Cancel rejects all of it and leaves the open documents, the
  /// active one and every reading place as they were.
  Future<void> _acquireBatch(
    BuildContext context,
    Future<List<FileCandidate>?> Function() acquire, {
    bool dropped = false,
  }) async {
    final operation = _beginIntake();
    if (operation == null) return;
    try {
      final candidates = await acquire();
      if (candidates == null ||
          candidates.isEmpty ||
          !_validIntake(operation) ||
          !context.mounted) {
        return;
      }
      if (dropped && _atSettings) return;

      // Every eligible file is read, and every read settles, before anything
      // is reported, asked or changed (§4.5 step 2).
      final reads = await Future.wait([
        for (final candidate in candidates) _readEligible(candidate),
      ]);
      if (!_validIntake(operation) || !context.mounted) return;
      if (dropped && _atSettings) return;
      final problem = _batchProblem(reads);
      if (problem != null) {
        _report(problem);
        return;
      }
      final files = [for (final read in reads) read.file!]
        ..sort((a, b) => compareFileNames(a.name, b.name));

      // Same name, same document (M2): one confirmation per match, in D-2
      // order. "Do the same" accepts the rest; any Cancel rejects them all.
      final matches = [for (final file in files) _session.byName(file.name)];
      final confirmations = matches.nonNulls.toList();
      for (var i = 0; i < confirmations.length; i++) {
        final sameForOthers = await _intakeModal(
          () => _confirmReplace(
            context,
            confirmations[i],
            offerSameForOthers: i < confirmations.length - 1,
          ),
        );
        if (sameForOthers == null ||
            !context.mounted ||
            !_validIntake(operation)) {
          return;
        }
        if (sameForOthers) break;
      }
      if (!context.mounted || !_beginOpening(operation)) return;
      await _applyBatch(files, matches);
    } catch (error) {
      if (_validIntake(operation)) _report('Could not read that file: $error');
    } finally {
      _endIntake(operation);
    }
  }

  /// Reads [candidate] if its name is a Markdown filename, keeping a failure
  /// as a result (§4.5 step 2). A file with any other name is not read or
  /// decoded: it is rejected by that name, whatever it holds.
  static Future<_IntakeRead> _readEligible(FileCandidate candidate) async {
    if (!isMarkdownFileName(candidate.name)) {
      return (name: candidate.name, file: null, error: null);
    }
    try {
      final file = await candidate.read();
      return (name: file.name, file: file, error: null);
    } catch (error) {
      return (name: candidate.name, file: null, error: error);
    }
  }

  /// The first reason the batch cannot be loaded, or null (§4.5 step 4;
  /// S11-04).
  ///
  /// Names are taken in D-2 order. For each, the checks run in turn: an
  /// unsupported extension, a read or decode failure, empty content, then a
  /// name used more than once (D-5). Files sharing a name are checked
  /// together, so the result never depends on which copy was delivered or
  /// read first.
  static String? _batchProblem(List<_IntakeRead> reads) {
    final names = {for (final read in reads) read.name}.toList()
      ..sort(compareFileNames);
    for (final name in names) {
      final named = [
        for (final read in reads)
          if (read.name == name) read,
      ];
      if (!isMarkdownFileName(name)) {
        return 'Cannot open "$name". Choose a Markdown file '
            '(.md, .markdown or .txt).';
      }
      final errors = [
        for (final read in named)
          if (read.file == null) '${read.error}',
      ]..sort();
      if (errors.isNotEmpty) {
        // The reason is today's, and the file is named (S11-04).
        return 'Could not read "$name": ${errors.first}';
      }
      if (named.any((read) => read.file!.contents.trim().isEmpty)) {
        return '"$name" is empty.';
      }
      if (named.length > 1) {
        return 'Cannot open these files: more than one is named "$name".';
      }
    }
    return null;
  }

  Future<void> _editDocument(BuildContext context) async {
    final current = _document;
    if (current == null) return;
    final operation = _beginIntake();
    if (operation == null) return;
    try {
      final source = await _intakeModal(
        () => showMarkdownEditor(context, initialText: current.source),
      );
      if (source == null ||
          source == current.source ||
          !_beginOpening(operation)) {
        return;
      }

      // The reading position is kept. Block indices usually survive a small edit,
      // and being a little off beats being sent back to the top of a long document.
      // The origin and filename are preserved too: editing changes this device's
      // copy, never the file it came from.
      final updated = current.copyWith(
        title: MarkdownDocument.deriveTitle(source),
        source: source,
        updatedAt: DateTime.now(),
      );
      // The session first, then the write, which captures it (§4.5). The edit
      // stands in memory either way: the user goes on reading it in this
      // session. What a failed write changes is the claim - Home stops saying
      // `Saved in this browser` for content that is not.
      setState(() {
        _documentGeneration++;
        _session = _session.updateDocument(updated);
      });
      final receipt = await store.requestDocumentsWrite();
      if (!mounted) return;
      if (_unsavedUnderOn(receipt)) {
        _report('Your changes could not be saved in this browser.');
      }
    } finally {
      _endIntake(operation);
    }
  }

  /// The resolved Han lead for the app theme, or the declared default when
  /// there is no document at all.
  HanScript get _resolvedScript => resolveHanScriptForDocument(_document);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      scaffoldMessengerKey: _messengerKey,
      navigatorKey: _navigatorKey,
      navigatorObservers: [_routeObserver],
      title: 'Markdown Viewer',
      debugShowCheckedModeBanner: false,
      themeMode: switch (_settings.appearance) {
        AppearanceMode.system => ThemeMode.system,
        AppearanceMode.light => ThemeMode.light,
        AppearanceMode.dark => ThemeMode.dark,
      },
      // These run above the `home:` builder that reads `_document`, but
      // `_document` is a State field and is in scope here, so the resolved
      // script threads straight in. It is nullable - the home screen has no
      // document - and that path resolves to the declared §5.4.3 default rather
      // than to an accident (plan.md §5.5 fact 1).
      theme: buildAppTheme(ReaderPalette.light, script: _resolvedScript),
      darkTheme: buildAppTheme(ReaderPalette.dark, script: _resolvedScript),
      home: Builder(
        builder: (context) {
          final document = _document;

          // The recovery state is a Home state, and it must win over any reader
          // route: stored data that cannot be opened has no reader to show, and
          // routing into one would be the reclassification D-010 forbids.
          if (_atHome || document == null || _inRecovery) {
            // Settings is a Home state too: reached only from Home and
            // returning only there, so the same rule routes it and recovery
            // still wins over any reader route.
            if (_atSettings) {
              return SettingsScreen(
                settings: _settings,
                retention: _retentionHomeState,
                onBack: _closeSettings,
                onSettingsChanged: _onSettingsChanged,
                onKeepForNextTimeChanged: _setKeepForNextTime,
                onRemoveSavedDocument: () => _removeSavedDocument(context),
                onRemoveRetainedData: () => _removeRetainedData(context),
              );
            }
            return HomeScreen(
              document: document,
              otherDocumentCount: _session.documents.length - 1,
              retention: _retentionHomeState,
              onContinue: _continueReading,
              onPaste: () => _pasteNewDocument(context),
              onLoadFile: () => _loadFromFile(context),
              onOpenSettings: _openSettings,
              onRemoveRetainedData: () => _removeRetainedData(context),
            );
          }

          // The Reader always sits at the same place in the tree: a Column
          // whose first slot is the tab bar or nothing. Showing or hiding the
          // bar, or crossing the width threshold, never moves the Reader, so
          // its State - and the reading position - survive (§4.4).
          return LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= kDocumentTabsBreakpoint;
              final several = _session.documents.length >= 2;
              final tabs = wide && several;
              return ColoredBox(
                color: ReaderPalette.of(context).background,
                child: Column(
                  children: [
                    if (tabs)
                      DocumentTabBar(
                        documents: _session.documents,
                        activeId: _session.activeId,
                        busy: _navigationInert,
                        onSelect: _activateDocument,
                        onClose: _closeDocument,
                      )
                    else
                      const SizedBox.shrink(),
                    Expanded(
                      child: MediaQuery.removePadding(
                        context: context,
                        // The bar takes the top inset when it is shown.
                        removeTop: tabs,
                        child: ReaderScreen(
                          // Remounting on a document or edit change gives the
                          // list a fresh initialScrollIndex, which is the only
                          // point it is read. A switch is a remount too.
                          key: ValueKey(
                            '${document.id}:'
                            '${document.updatedAt.microsecondsSinceEpoch}',
                          ),
                          document: document,
                          settings: _settings,
                          onSettingsChanged: _onSettingsChanged,
                          onScriptPreferenceChanged: _setScriptPreference,
                          onEdit: () => _editDocument(context),
                          // The same workflow Home uses - picker, validation,
                          // replacement confirmation and error handling all
                          // live in _loadFromFile.
                          onLoadFile: () => _loadFromFile(context),
                          onReturnHome: _returnHome,
                          onPositionChanged: _onPositionReported,
                          sessionPosition: _sessionPosition,
                          onCloseDocument: () => _closeDocument(document.id),
                          onShowDocuments: !wide && several
                              ? () => _showDocuments(context)
                              : null,
                          documentCount: _session.documents.length,
                          onFirstFrame: kDf020Timing
                              ? () => Df020Timing._shown(document.id)
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// DF-020 V-17: the switch-latency seam, compiled in only with
/// `--dart-define=DF020_TIMING=true`. In any other build every use is behind
/// this constant and is removed by the compiler.
const bool kDf020Timing = bool.fromEnvironment('DF020_TIMING');

/// Drives the real app's open and switch paths for the latency harness and
/// reports when each was applied and when its Reader first painted.
abstract final class Df020Timing {
  static _MarkdownViewerAppState? _app;

  /// Called with `('df020-timing:applied' | 'df020-timing:shown', id)`.
  static void Function(String phase, String id)? onMark;

  static void _applied(String id) => onMark?.call('df020-timing:applied', id);
  static void _shown(String id) => onMark?.call('df020-timing:shown', id);

  /// Opens a document through the same commit the intake paths use.
  static String open(String name, String text) {
    final app = _app!;
    final document = MarkdownDocument.fromSource(
      text,
      id: app._newDocumentId(),
      sourceName: name,
    );
    unawaited(app._addDocument(document));
    return document.id;
  }

  static void activate(String id) => _app!._activateDocument(id);

  static Future<void> close(String id) => _app!._closeDocument(id);
}

/// One file of a batch after §4.5 step 2: read ([file]), failed ([error]), or
/// not read because its name is not Markdown (both null).
typedef _IntakeRead = ({String name, LoadedFile? file, Object? error});

class _IntakeOperation {
  _IntakeOperation(this.documentGeneration, this.routeGeneration);
  final int documentGeneration;
  final int routeGeneration;
  bool committing = false;
}

class _EntryRouteObserver extends NavigatorObserver {
  _EntryRouteObserver(this.changed);
  final VoidCallback changed;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      changed();
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => changed();
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      changed();
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      changed();
}
