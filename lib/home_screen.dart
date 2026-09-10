import 'package:flutter/material.dart';

import 'markdown_theme.dart';
import 'models.dart';
import 'retention.dart';

/// The document entry point, and the place the retention choice lives.
///
/// Reaching this screen never unloads the current document - that is what makes
/// "Continue reading" meaningful.
///
/// DF-039 puts `Keep for next time` here, beside the load actions, rather than
/// behind the reader's `...` menu. The choice governs what happens to a document
/// once it is loaded, so it has to be visible *before* the first one is, and it
/// has to be visible in the document context afterwards. Its default is OFF and
/// the control shows that, which is the whole point: nothing is kept across
/// visits unless the user says so.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.document,
    required this.retention,
    required this.onContinue,
    required this.onPaste,
    required this.onLoadFile,
    required this.onOpenSettings,
    required this.onKeepForNextTimeChanged,
    required this.onRemoveSavedDocument,
    required this.onRemoveRetainedData,
  });

  /// The current document, in memory or retained. Null on an empty Home.
  final MarkdownDocument? document;

  /// Everything Home must show about retention, already resolved.
  final RetentionHomeState retention;

  final VoidCallback onContinue;
  final VoidCallback onPaste;
  final VoidCallback onLoadFile;
  final VoidCallback onOpenSettings;

  final ValueChanged<bool> onKeepForNextTimeChanged;

  /// `Remove saved document` - the destructive control shown only for a valid
  /// retained document.
  final VoidCallback onRemoveSavedDocument;

  /// `Remove unreadable saved data` - the recovery control, which carries no
  /// document identity because in that state there is no document to name.
  final VoidCallback onRemoveRetainedData;

  @override
  Widget build(BuildContext context) {
    final palette = ReaderPalette.of(context);
    final current = document;
    final offer = retention.continueOffer;

    return Scaffold(
      backgroundColor: palette.background,
      body: SafeArea(
        child: Stack(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: IconButton(
                  icon: Icon(Icons.tune_rounded, color: palette.muted),
                  tooltip: 'Appearance',
                  onPressed: onOpenSettings,
                ),
              ),
            ),
            Center(
              child: SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 24,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            // The mascot, on a transparent background so it
                            // sits directly on the page rather than inside a
                            // tile. The app/PWA icons keep their opaque plate;
                            // that is right for a launcher, wrong here.
                            // Framed to the same 88% of its square canvas as
                            // those icons, so this renders at exactly the size
                            // and position already approved. Decorative: the
                            // title beside it already carries the name, so it
                            // stays out of the semantics tree.
                            Image.asset(
                              'branding/pencil-bird.png',
                              width: 38,
                              height: 38,
                              filterQuality: FilterQuality.medium,
                              excludeFromSemantics: true,
                            ),
                            const SizedBox(width: 12),
                            Flexible(
                              child: Text(
                                'Markdown Viewer',
                                style: TextStyle(
                                  fontSize: 26,
                                  fontWeight: FontWeight.w700,
                                  color: palette.text,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Open a Markdown document to read comfortably. '
                          'Everything stays on this device.',
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.5,
                            color: palette.muted,
                          ),
                        ),
                        for (final alert in retention.alerts) ...[
                          const SizedBox(height: 12),
                          _RetentionAlert(alert: alert, palette: palette),
                        ],
                        const SizedBox(height: 26),

                        // The generic recovery state. No identity, no continue,
                        // no reader route - there is stored data but nothing
                        // that can be shown, and naming it would disclose
                        // something the app cannot actually open (D-015).
                        if (offer != ContinueOffer.none && current != null) ...[
                          _HomeAction(
                            icon: Icons.menu_book_rounded,
                            label: 'Continue reading',
                            detail: current.identityLabel,
                            // The distinction the whole feature turns on. A
                            // current-session document is real and is gone on
                            // refresh; only a retained one comes back.
                            status: switch (offer) {
                              ContinueOffer.retained => 'Saved in this browser',
                              // A copy is stored, but not this one.
                              ContinueOffer.retainedOutOfDate =>
                                'Latest changes not saved in this browser',
                              _ => 'Current session only',
                            },
                            palette: palette,
                            prominent: true,
                            onTap: onContinue,
                          ),
                          const SizedBox(height: 12),
                        ],

                        // The generic removal control. Offered whenever stored
                        // data exists that no retained document accounts for:
                        // with no document it is the recovery state, and with a
                        // document in memory it is the way to retry a removal
                        // that did not verify. No identity either way, because
                        // what is stored is not necessarily what is on screen.
                        if (retention.offPolicyResidue) ...[
                          _HomeAction(
                            icon: Icons.cleaning_services_rounded,
                            label: 'Remove unreadable saved data',
                            detail:
                                'Clear saved reading data from this browser',
                            palette: palette,
                            destructive: true,
                            onTap: retention.busy ? null : onRemoveRetainedData,
                          ),
                          const SizedBox(height: 12),
                        ],

                        // Load from file comes before Paste: real-device
                        // testing showed it is the practical way to open a long
                        // document, especially on a phone. Paste stays for
                        // short or ad-hoc Markdown.
                        _HomeAction(
                          icon: Icons.folder_open_rounded,
                          label: 'Load from file',
                          detail: 'Choose a .md file from this device',
                          palette: palette,
                          onTap: onLoadFile,
                        ),
                        const SizedBox(height: 12),
                        _HomeAction(
                          icon: Icons.content_paste_rounded,
                          label: 'Paste Markdown',
                          detail: 'Paste text copied from anywhere',
                          palette: palette,
                          onTap: onPaste,
                        ),

                        const SizedBox(height: 18),
                        _KeepForNextTime(
                          state: retention,
                          palette: palette,
                          onChanged: onKeepForNextTimeChanged,
                        ),

                        // Removing this document and changing what happens to
                        // future ones are separate intentions, so this is a
                        // separate control and never a side effect of the
                        // toggle above (D-014).
                        if ((offer == ContinueOffer.retained ||
                                offer == ContinueOffer.retainedOutOfDate) &&
                            !retention.recovery) ...[
                          const SizedBox(height: 12),
                          _HomeAction(
                            icon: Icons.delete_outline_rounded,
                            label: 'Remove saved document',
                            detail: retention.documentLabel ?? 'Saved document',
                            palette: palette,
                            destructive: true,
                            onTap: retention.busy
                                ? null
                                : onRemoveSavedDocument,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The retention choice.
///
/// A switch rather than a button, because it shows its own current state - and
/// default OFF being *visible* is a requirement, not a detail. The helper text
/// says what the choice does in plain terms and deliberately promises nothing
/// about durability: browser-local storage can be cleared or evicted by the
/// browser, so `Store this document ... in this browser` is the strongest true
/// statement available (D-012, D-015).
class _KeepForNextTime extends StatelessWidget {
  const _KeepForNextTime({
    required this.state,
    required this.palette,
    required this.onChanged,
  });

  final RetentionHomeState state;
  final ReaderPalette palette;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final enabled = state.canChangePreference;

    return Semantics(
      // The helper text is the control's explanation, so it belongs to the
      // control for a screen reader rather than being read as loose prose.
      container: true,
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: state.keepForNextTime,
          onChanged: enabled ? onChanged : null,
          title: Text(
            'Keep for next time',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: palette.text,
            ),
          ),
          subtitle: Text(
            !state.storageAvailable
                ? 'Unavailable because this browser is not letting Saudo '
                      'store data'
                : !state.keepForNextTime && state.offPolicyResidue
                ? 'Unavailable until saved reading data is removed'
                : 'Store this document and your reading place in this browser '
                      'so you can continue after reopening Saudo.',
            style: TextStyle(fontSize: 12.5, height: 1.4, color: palette.muted),
          ),
        ),
      ),
    );
  }
}

/// One line of truthful state about retention, when there is something to say.
///
/// Every string here is bounded by D-015: nothing claims removal that was not
/// verified, and nothing claims a choice will survive that was not confirmed.
class _RetentionAlert extends StatelessWidget {
  const _RetentionAlert({required this.alert, required this.palette});

  final RetentionAlert alert;
  final ReaderPalette palette;

  @override
  Widget build(BuildContext context) {
    final (text, warning) = switch (alert) {
      RetentionAlert.none => ('', false),
      RetentionAlert.legacyDataRemoved => (
        'Previously saved reading data was removed from this browser because '
            '"Keep for next time" is off.',
        false,
      ),
      RetentionAlert.preferenceAndDataUnresolved => (
        'Saved reading data may still remain in this browser, and your choice '
            'may not apply on your next visit. Try removing it again, or clear '
            'this site’s data in your browser settings.',
        true,
      ),
      RetentionAlert.dataMayRemain => (
        'Saved reading data may still remain in this browser. Try removing it '
            'again, or clear this site’s data in your browser settings.',
        true,
      ),
      RetentionAlert.preferenceMayNotPersist => (
        'The document was removed from this browser, but your choice may not '
            'apply on your next visit.',
        true,
      ),
      RetentionAlert.preferenceUnreadable => (
        'Your saved choice could not be read, so nothing will be kept for next '
            'time during this visit.',
        true,
      ),
      // No "try again": with no storage open there is no removal Saudo could
      // attempt, so the browser's own control is the only honest remedy.
      RetentionAlert.storageUnavailable => (
        'This browser is not letting Saudo store data, so nothing will be kept '
            'for next time. If reading data was saved here before, you can '
            'clear this site’s data in your browser settings.',
        true,
      ),
    };

    if (text.isEmpty) return const SizedBox.shrink();

    final colour = warning ? palette.link : palette.muted;

    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              warning
                  ? Icons.warning_amber_rounded
                  : Icons.info_outline_rounded,
              size: 18,
              color: colour,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  color: palette.text,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeAction extends StatelessWidget {
  const _HomeAction({
    required this.icon,
    required this.label,
    required this.detail,
    required this.palette,
    required this.onTap,
    this.status,
    this.prominent = false,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final String detail;

  /// What this action promises, on its own line beneath [detail].
  ///
  /// Separate from [detail] on purpose. [detail] is usually a filename and can
  /// be arbitrarily long, so if the two shared a line the promise would be the
  /// half that got truncated - and "Current session only" disappearing into an
  /// ellipsis is exactly the overstatement D-015 forbids.
  final String? status;

  final ReaderPalette palette;

  /// Null while the action is unavailable - during a retention operation, so a
  /// second tap cannot race the first.
  final VoidCallback? onTap;

  /// The primary action gets the accent colour; the rest stay quiet.
  final bool prominent;

  /// A destructive action. Marked for assistive technology rather than only
  /// coloured, so the warning is not carried by colour alone.
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final foreground = prominent ? palette.link : palette.text;

    return Semantics(
      button: true,
      enabled: enabled,
      // One node per action rather than four. Without this the label, the
      // filename and the status line each announce separately, and a screen
      // reader user has to assemble the control from fragments.
      excludeSemantics: true,
      label: label,
      // The status is part of what the control promises, so a screen reader
      // must get it too, not only a sighted user.
      hint: destructive
          ? 'Removes saved data from this browser'
          : [detail, ?status].join('. '),
      child: Material(
        color: palette.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
            child: Opacity(
              opacity: enabled ? 1 : 0.5,
              child: Row(
                children: [
                  Icon(icon, size: 22, color: foreground),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: prominent
                                ? FontWeight.w700
                                : FontWeight.w600,
                            color: foreground,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: palette.muted,
                          ),
                        ),
                        if (status != null) ...[
                          const SizedBox(height: 3),
                          Text(
                            status!,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.1,
                              color: palette.muted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: palette.muted,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
