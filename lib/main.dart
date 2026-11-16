import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'document_session.dart';
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
  /// session's operations. The app still opens one document at a time, so the
  /// session holds at most one.
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

  bool get _homeRendered => _atHome || _document == null || _inRecovery;
  bool get _dropEligible =>
      mounted &&
      !_disposing &&
      _homeRendered &&
      !_atSettings &&
      !_busy &&
      _intake == null &&
      !(_navigatorKey.currentState?.canPop() ?? true);

  @override
  void initState() {
    super.initState();
    store.registerRetainedSource(_retainedSnapshot);
    store.savedState.addListener(_savedStateChanged);
    _dropLease = widget.fileDropMount(
      eligible: () => _dropEligible,
      onHover: (_) {},
      onCandidate: (candidate) {
        final context = _navigatorKey.currentContext;
        if (context != null && _dropEligible) {
          unawaited(_acquireFile(context, candidate.read, dropped: true));
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

  /// Lightweight guard before discarding the document currently being read.
  /// Skipped entirely when there is nothing to lose.
  Future<bool> _confirmReplace(BuildContext context) async {
    final current = _document;
    if (current == null) return true;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Replace current document?'),
        content: Text(
          '"${current.identityLabel}" and your place in it will be removed '
          'from this device.',
        ),
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
    );
    return confirmed ?? false;
  }

  /// Replaces the current document.
  ///
  /// The removal runs first and unconditionally, including under OFF, so a
  /// replaced document's stored bytes and its stored position cannot outlive it.
  /// It also invalidates any content write that was already requested when the
  /// removal was issued, so an outgoing document's in-flight save cannot land
  /// behind it.
  ///
  /// What stops the *new* document from inheriting the old one's position is
  /// separate and stronger: `Store.loadPosition` returns a stored position only
  /// when its `documentId` matches. A position write whose debounce fires after
  /// this removal is a new request rather than a stale one, so the fence does
  /// not cover it - the identity filter does.
  Future<void> _openDocument(MarkdownDocument document) async {
    final outgoing = _document;
    // Suppressing the outgoing document closes the same hole `Remove saved
    // document` has: its reader is about to be replaced, and the `dispose()`
    // position flush that follows is issued after this removal, so the
    // generation fence would not catch it.
    final cleanup = await store.removeRetainedContent(
      suppressDocumentId: outgoing?.id,
    );
    if (!mounted) return;
    // Under OFF anything the removal could not clear is off-policy data, and
    // the interlock has to know that before any later attempt to turn ON.
    if (store.effectivePolicy == RetentionPolicy.off &&
        store.isAvailable &&
        !cleanup.isConfirmedAbsent) {
      store.setOffPolicyDataUnresolved(true);
    }
    setState(() {
      _documentGeneration++;
      // Still one document at a time: the new one takes the open document's
      // place, and that document's reading place goes with it.
      final replaced = _document;
      _session = replaced == null
          ? _session.commitBatch(adds: [document], activeId: document.id)
          : _session.commitBatch(
              replacements: {replaced.id: document},
              activeId: document.id,
            );
      _atHome = false;
      // A load supersedes whatever the last retention operation reported. The
      // exception is a preference that still cannot be written: that describes
      // the browser, not the document just replaced.
      _alerts = _alerts
          .where((a) => a == RetentionAlert.preferenceMayNotPersist)
          .toList();
    });
    // The writes capture the session that now holds the new document.
    final saved = store.requestDocumentsWrite();
    unawaited(store.requestReadingStateWrite());
    final receipt = await saved;
    if (!mounted) return;
    // Under ON the user has been told their documents are kept; a save that did
    // not land contradicts that and has to be said out loud.
    if (store.effectivePolicy == RetentionPolicy.on && !receipt.confirmed) {
      _report('This document could not be saved in this browser.');
    }
  }

  Future<void> _pasteNewDocument(BuildContext context) async {
    final operation = _beginIntake();
    if (operation == null) return;
    try {
      // Preserve paste's confirmation-before-editor ordering.
      if (!await _intakeModal(() => _confirmReplace(context))) return;
      if (!_validIntake(operation) || !context.mounted) return;
      final source = await _intakeModal(() => showMarkdownEditor(context));
      if (source == null || !_beginOpening(operation)) return;
      await _openDocument(
        MarkdownDocument.fromSource(source, id: _newDocumentId()),
      );
    } finally {
      _endIntake(operation);
    }
  }

  Future<void> _loadFromFile(BuildContext context) =>
      _acquireFile(context, pickMarkdownFile);

  /// Picker and drop share acceptance, confirmation and retention behavior.
  Future<void> _acquireFile(
    BuildContext context,
    Future<LoadedFile?> Function() acquire, {
    bool dropped = false,
  }) async {
    final operation = _beginIntake();
    if (operation == null) return;
    try {
      final file = await acquire();
      if (file == null || !_validIntake(operation) || !context.mounted) return;
      if (dropped && (!_homeRendered || _atSettings)) return;
      if (!isMarkdownFileName(file.name)) {
        throw UnsupportedFileException(file.name);
      }
      if (file.contents.trim().isEmpty) {
        _report('"${file.name}" is empty.');
        return;
      }
      if (!await _intakeModal(() => _confirmReplace(context))) return;
      if (!context.mounted || !_beginOpening(operation)) return;
      await _openDocument(
        MarkdownDocument.fromSource(
          file.contents,
          id: _newDocumentId(),
          sourceName: file.name,
        ),
      );
    } on UnsupportedFileException catch (error) {
      if (_validIntake(operation)) {
        _report(
          'Cannot open "${error.fileName}". Choose a Markdown file '
          '(.md, .markdown or .txt).',
        );
      }
    } catch (error) {
      if (_validIntake(operation)) _report('Could not read that file: $error');
    } finally {
      _endIntake(operation);
    }
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
              retention: _retentionHomeState,
              onContinue: _continueReading,
              onPaste: () => _pasteNewDocument(context),
              onLoadFile: () => _loadFromFile(context),
              onOpenSettings: _openSettings,
              onRemoveRetainedData: () => _removeRetainedData(context),
            );
          }

          return ReaderScreen(
            // Remounting on a document or edit change gives the list a fresh
            // initialScrollIndex, which is the only point it is read.
            key: ValueKey(
              '${document.id}:${document.updatedAt.microsecondsSinceEpoch}',
            ),
            document: document,
            settings: _settings,
            onSettingsChanged: _onSettingsChanged,
            onScriptPreferenceChanged: _setScriptPreference,
            onEdit: () => _editDocument(context),
            // The same workflow Home uses - picker, validation, replacement
            // confirmation and error handling all live in _loadFromFile.
            onLoadFile: () => _loadFromFile(context),
            onReturnHome: _returnHome,
            onPositionChanged: _onPositionReported,
            sessionPosition: _sessionPosition,
          );
        },
      ),
    );
  }
}

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
