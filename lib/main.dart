import 'dart:async';

import 'package:flutter/material.dart';

import 'file_loader.dart';
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
  });

  final Settings initialSettings;
  final MarkdownDocument? initialDocument;

  /// What startup resolved about retention, before the first frame.
  final StartupResolution startup;

  @override
  State<MarkdownViewerApp> createState() => _MarkdownViewerAppState();
}

class _MarkdownViewerAppState extends State<MarkdownViewerApp> {
  late Settings _settings = widget.initialSettings;
  late MarkdownDocument? _document = widget.initialDocument;

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

  /// Where reading reached in this page lifetime, whether or not it was stored.
  ///
  /// Under OFF nothing durable is written, and §18.2 still requires returning
  /// Home and continuing to land where the reader was. This is that memory, and
  /// it is deliberately not persistence: a refresh loses it, which is exactly
  /// what OFF promises.
  ReadingPosition? _sessionPosition;

  /// The document this session last *confirmed* stored, if any.
  ///
  /// Tracked from real write outcomes rather than inferred from the preference
  /// or from key presence. A stored `document` key proves that something is
  /// stored, not that it is the document on screen: after a failed replacement
  /// or a failed edit, the bytes on disk are an older or different document,
  /// and `Saved in this browser` would describe something the user is not
  /// looking at.
  late String? _storedDocumentId = widget.initialDocument?.id;

  /// Whether that stored copy includes the latest in-memory changes.
  bool _storedDocumentCurrent = true;

  /// What Home says about retention state, if anything.
  late List<RetentionAlert> _alerts = _initialAlerts();

  /// A retention operation is in flight.
  bool _busy = false;

  /// An appearance change arrived while a retention operation was running.
  /// It shows at once and is stored when the operation finishes, so it cannot
  /// race the preference write that operation makes (D-013).
  bool _settingsWriteDeferred = false;

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
  /// `retained` requires the live policy to be ON, a stored document key, *and*
  /// that the stored copy is known to be this document - not merely that some
  /// document is on disk. `retainedOutOfDate` is that same stored copy when the
  /// latest changes to it failed to save. Anything else is current-session.
  ContinueOffer get _continueOffer {
    final document = _document;
    if (document == null) return ContinueOffer.none;
    final storedCopyOfThis =
        store.effectivePolicy == RetentionPolicy.on &&
        _storedDocumentId == document.id &&
        store.rawKeyPresence(Store.documentKey) == RawKeyPresence.present;
    if (!storedCopyOfThis) return ContinueOffer.currentSession;
    return _storedDocumentCurrent
        ? ContinueOffer.retained
        : ContinueOffer.retainedOutOfDate;
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
      busy: _busy,
    );
  }

  /// Records the outcome of saving the in-memory [document] under ON.
  ///
  /// Returns whether the caller must tell the user the save did not land.
  bool _recordDocumentSave(MarkdownDocument document, WriteOutcome outcome) {
    if (outcome.isConfirmed) {
      _storedDocumentId = document.id;
      _storedDocumentCurrent = true;
      return false;
    }
    if (store.effectivePolicy != RetentionPolicy.on) return false;
    if (_storedDocumentId == document.id) _storedDocumentCurrent = false;
    return true;
  }

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
    if (_busy) return;
    setState(() => _busy = true);

    final result = value
        ? await retention.enable(
            current: _settings,
            document: _document,
            position: _sessionPosition,
          )
        : await retention.disable(current: _settings);

    if (!mounted) return;
    setState(() {
      _settings = _settings.copyWith(
        keepForNextTime: result.effectivePolicy == RetentionPolicy.on,
      );
      if (result.requested == RetentionPolicy.on && result.documentConfirmed) {
        _storedDocumentId = _document?.id;
        _storedDocumentCurrent = true;
      }
      if (result.requested == RetentionPolicy.off &&
          result.contentConfirmedAbsent) {
        _storedDocumentId = null;
      }
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

  /// `Remove saved document`. Separate from the preference by design: removing
  /// this document says nothing about what happens to the next one (D-014).
  Future<void> _removeSavedDocument(BuildContext context) async {
    final current = _document;
    if (_busy || current == null) return;

    final confirmed = await _confirmRemoval(
      context,
      title: 'Remove saved document?',
      body:
          '"${current.identityLabel}" and your reading place in it will be '
          'removed from this browser. "Keep for next time" stays on, so the '
          'next document you open will still be kept.',
    );
    if (!confirmed) return;

    setState(() => _busy = true);
    final outcome = await retention.removeSavedDocument(documentId: current.id);
    if (!mounted) return;

    setState(() {
      _busy = false;
      if (outcome.isConfirmedAbsent) {
        // The user chose removal, not merely a change of preference, so the
        // document goes from this session too (§20.3).
        _document = null;
        _sessionPosition = null;
        _storedDocumentId = null;
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
    if (_busy) return;

    final confirmed = await _confirmRemoval(
      context,
      title: 'Remove saved reading data?',
      body:
          'Saved document data and reading place will be removed from this '
          'browser. Your appearance settings are not affected.',
    );
    if (!confirmed) return;

    setState(() => _busy = true);
    final outcome = await retention.removeUnreadableData();
    if (!mounted) return;

    setState(() {
      _busy = false;
      if (outcome.isConfirmedAbsent) _storedDocumentId = null;
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
    if (current == null || current.scriptPreference == next) return;

    final updated = current.copyWith(scriptPreference: next);
    // Governed by the store's retention gate: under OFF this is suppressed and
    // the preference stays in memory for the current session only.
    final outcome = await store.saveDocument(updated);
    if (!mounted) return;
    var unsaved = false;
    setState(() {
      _document = updated;
      unsaved = _recordDocumentSave(updated, outcome);
    });
    // Same rule as an edit: under ON the user has been told this document is
    // kept, so a preference that did not save has to be said out loud.
    if (unsaved) _report('Your changes could not be saved in this browser.');
  }

  // --- Navigation -----------------------------------------------------------

  void _returnHome() => setState(() => _atHome = true);

  void _openSettings() => setState(() => _atSettings = true);

  void _closeSettings() => setState(() => _atSettings = false);

  /// Reopens the stored document. Nothing to reload: it never left the store,
  /// and the reader restores its own position on mount.
  void _continueReading() => setState(() => _atHome = false);

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
    final saved = await store.saveDocument(document);
    if (!mounted) return;
    // Under OFF anything the removal could not clear is off-policy data, and
    // the interlock has to know that before any later attempt to turn ON.
    if (store.effectivePolicy == RetentionPolicy.off &&
        store.isAvailable &&
        !cleanup.isConfirmedAbsent) {
      store.setOffPolicyDataUnresolved(true);
    }
    setState(() {
      _document = document;
      if (saved.isConfirmed) {
        _storedDocumentId = document.id;
        _storedDocumentCurrent = true;
      } else if (cleanup.isConfirmedAbsent) {
        _storedDocumentId = null;
      }
      // The outgoing document's reading place, which does not belong to this
      // one. `loadPosition` filters by id as well, so this is belt and braces
      // for the in-memory half.
      _sessionPosition = null;
      _atHome = false;
      // A load supersedes whatever the last retention operation reported. The
      // exception is a preference that still cannot be written: that describes
      // the browser, not the document just replaced.
      _alerts = _alerts
          .where((a) => a == RetentionAlert.preferenceMayNotPersist)
          .toList();
    });
    // Under ON the user has been told their documents are kept; a save that did
    // not land contradicts that and has to be said out loud.
    if (store.effectivePolicy == RetentionPolicy.on &&
        saved != WriteOutcome.saved) {
      _report('This document could not be saved in this browser.');
    }
  }

  Future<void> _pasteNewDocument(BuildContext context) async {
    if (!await _confirmReplace(context)) return;
    if (!context.mounted) return;

    final source = await showMarkdownEditor(context);
    if (source == null) return;

    await _openDocument(MarkdownDocument.fromSource(source));
  }

  /// Load from file, confirming replacement only once there is something to
  /// replace the document *with*.
  ///
  /// Deliberately different from [_pasteNewDocument], which still confirms
  /// first: there the confirmation precedes the effort, and asking after
  /// someone has pasted a long document would waste it. Here the picker costs
  /// nothing to cancel, so the guard belongs after a valid choice.
  Future<void> _loadFromFile(BuildContext context) async {
    // Resolved before the await because the context must not cross it, and then
    // checked for each use: the system picker can stay open for an arbitrary
    // time, so every path below runs after an unbounded gap.
    final messenger = ScaffoldMessenger.of(context);
    void report(String text) {
      if (!messenger.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(text)));
    }

    try {
      final file = await pickMarkdownFile();
      if (file == null) return; // cancelled: nothing changes, nothing asked

      if (file.contents.trim().isEmpty) {
        report('"${file.name}" is empty.');
        return;
      }

      if (!context.mounted) return;
      if (!await _confirmReplace(context)) return;

      await _openDocument(
        MarkdownDocument.fromSource(file.contents, sourceName: file.name),
      );
    } on UnsupportedFileException catch (error) {
      report(
        'Cannot open "${error.fileName}". Choose a Markdown file '
        '(.md, .markdown or .txt).',
      );
    } catch (error) {
      // Reading can fail for reasons outside our control - permissions, a
      // browser restriction. Report it rather than leaving a dead button.
      report('Could not read that file: $error');
    }
  }

  Future<void> _editDocument(BuildContext context) async {
    final current = _document;
    if (current == null) return;

    final source = await showMarkdownEditor(
      context,
      initialText: current.source,
    );
    if (source == null || source == current.source) return;

    // The reading position is kept. Block indices usually survive a small edit,
    // and being a little off beats being sent back to the top of a long document.
    // The origin and filename are preserved too: editing changes this device's
    // copy, never the file it came from.
    final updated = current.copyWith(
      title: MarkdownDocument.deriveTitle(source),
      source: source,
      updatedAt: DateTime.now(),
    );
    final outcome = await store.saveDocument(updated);
    if (!mounted) return;
    var unsaved = false;
    setState(() {
      // Kept in memory either way, as `_openDocument` does: the user can go on
      // reading their edit in this session. What changes is the claim - Home
      // stops saying `Saved in this browser` for content that is not.
      _document = updated;
      unsaved = _recordDocumentSave(updated, outcome);
    });
    if (unsaved) _report('Your changes could not be saved in this browser.');
  }

  /// The resolved Han lead for the app theme, or the declared default when
  /// there is no document at all.
  HanScript get _resolvedScript => resolveHanScriptForDocument(_document);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      scaffoldMessengerKey: _messengerKey,
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
            onPositionChanged: (position) => _sessionPosition = position,
            sessionPosition: _sessionPosition,
          );
        },
      ),
    );
  }
}
