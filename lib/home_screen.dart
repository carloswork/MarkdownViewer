import 'package:flutter/material.dart';

import 'home_widgets.dart';
import 'markdown_theme.dart';
import 'models.dart';
import 'retention.dart';

/// The document entry point.
///
/// Reaching this screen never unloads the current document - that is what makes
/// "Continue reading" meaningful.
///
/// Home carries what a visit needs now: continue, load, paste, and the way to
/// Settings. `Keep for next time` and `Remove saved document` live on Settings -
/// the arrangement D-012 permits, selected on physical-phone evidence that the
/// inline choice crowded this screen. The choice stays discoverable from here:
/// the Settings entry says whether it is on, so default OFF is visible before
/// the first document is opened. Retention notices, and the recovery control a
/// notice asks for, stay here as well.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.document,
    required this.retention,
    required this.onContinue,
    required this.onPaste,
    required this.onLoadFile,
    required this.onOpenSettings,
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
        child: Center(
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
                        // The mascot, on a transparent background so it sits
                        // directly on the page rather than inside a tile. The
                        // app/PWA icons keep their opaque plate; that is right
                        // for a launcher, wrong here. Framed to the same 88% of
                        // its square canvas as those icons, so this renders at
                        // exactly the size and position already approved.
                        // Decorative: the title beside it already carries the
                        // name, so it stays out of the semantics tree.
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
                      RetentionAlertCard(alert: alert, palette: palette),
                    ],
                    const SizedBox(height: 26),

                    if (offer != ContinueOffer.none && current != null) ...[
                      ActionCard(
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

                    // The generic removal control. Offered whenever stored data
                    // exists that no retained document accounts for: with no
                    // document it is the recovery state, and with a document in
                    // memory it is the way to retry a removal that did not
                    // verify. No identity either way, because what is stored is
                    // not necessarily what is on screen, and naming it would
                    // disclose something the app cannot open (D-015). It stays
                    // on Home because the notice above asks for it.
                    if (retention.offPolicyResidue) ...[
                      ActionCard(
                        icon: Icons.cleaning_services_rounded,
                        label: 'Remove unreadable saved data',
                        detail: 'Clear saved reading data from this browser',
                        palette: palette,
                        destructive: true,
                        onTap: retention.busy ? null : onRemoveRetainedData,
                      ),
                      const SizedBox(height: 12),
                    ],

                    // Load from file comes before Paste: real-device testing
                    // showed it is the practical way to open a long document,
                    // especially on a phone. Paste stays for short or ad-hoc
                    // Markdown.
                    ActionCard(
                      icon: Icons.folder_open_rounded,
                      label: 'Load from file',
                      detail: 'Choose a .md file from this device',
                      palette: palette,
                      onTap: onLoadFile,
                    ),
                    const SizedBox(height: 12),
                    ActionCard(
                      icon: Icons.content_paste_rounded,
                      label: 'Paste Markdown',
                      detail: 'Paste text copied from anywhere',
                      palette: palette,
                      onTap: onPaste,
                    ),
                    const SizedBox(height: 12),

                    // The status line is what keeps the retention choice
                    // discoverable from Home: default OFF is stated here, before
                    // any document exists, not only one screen away.
                    ActionCard(
                      icon: Icons.settings_rounded,
                      label: 'Settings',
                      detail: 'Appearance and reading data',
                      status: !retention.storageAvailable
                          ? 'Keep for next time is unavailable'
                          : retention.keepForNextTime
                          ? 'Keep for next time is on'
                          : 'Keep for next time is off',
                      palette: palette,
                      onTap: onOpenSettings,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
