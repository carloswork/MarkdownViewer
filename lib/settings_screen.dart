import 'package:flutter/material.dart';

import 'home_widgets.dart';
import 'markdown_theme.dart';
import 'models.dart';
import 'retention.dart';
import 'settings_sheet.dart';

/// The controls that are set once and then left alone, one step from Home.
///
/// DF-039 first placed `Keep for next time` and `Remove saved document` on Home
/// beside the load actions. On real phones that crowded Home, set a switch and
/// its explanation in among the action cards, and pushed the removal below the
/// first screen on the smallest ones, so Human Authority selected the Settings
/// arrangement D-012 already permits. Only placement changed: the choice still
/// defaults OFF and Home's Settings entry still says whether it is on, removal
/// is still a separate confirmed action, and the recovery control stays on Home
/// as well as here, because the notice that asks for it is shown on both.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.retention,
    required this.onBack,
    required this.onSettingsChanged,
    required this.onKeepForNextTimeChanged,
    required this.onRemoveSavedDocument,
    required this.onRemoveRetainedData,
  });

  /// The live settings, as the appearance controls' starting values.
  final Settings settings;

  /// Everything this screen must show about retention, already resolved. It is
  /// the same state Home is built from, so the two cannot disagree.
  final RetentionHomeState retention;

  final VoidCallback onBack;
  final ValueChanged<Settings> onSettingsChanged;
  final ValueChanged<bool> onKeepForNextTimeChanged;

  /// `Remove saved document` - offered only for a valid retained document.
  final VoidCallback onRemoveSavedDocument;

  /// `Remove unreadable saved data` - the recovery control, which carries no
  /// document identity because in that state there is no document to name.
  final VoidCallback onRemoveRetainedData;

  @override
  Widget build(BuildContext context) {
    final palette = ReaderPalette.of(context);
    final offer = retention.continueOffer;
    final retained =
        (offer == ContinueOffer.retained ||
            offer == ContinueOffer.retainedOutOfDate) &&
        !retention.recovery;

    return Scaffold(
      backgroundColor: palette.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.arrow_back_rounded, color: palette.text),
                    tooltip: 'Back',
                    onPressed: onBack,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Semantics(
                      header: true,
                      child: Text(
                        'Settings',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: palette.text,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(28, 16, 28, 28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // The retention group comes first: it is the reason
                          // this screen exists, and on a small phone it is the
                          // part that has to be in view on arrival.
                          const SettingsSectionLabel('Reading data'),
                          for (final alert in retention.alerts) ...[
                            const SizedBox(height: 10),
                            RetentionAlertCard(alert: alert, palette: palette),
                          ],
                          const SizedBox(height: 8),
                          _KeepForNextTime(
                            state: retention,
                            palette: palette,
                            onChanged: onKeepForNextTimeChanged,
                          ),
                          const SizedBox(height: 6),
                          _KeepForNextTimeExplanation(palette: palette),

                          // Removing this document and changing what happens to
                          // future ones are separate intentions, so this is a
                          // separate control and never a side effect of the
                          // switch above (D-014).
                          if (retained) ...[
                            const SizedBox(height: 18),
                            ActionCard(
                              icon: Icons.delete_outline_rounded,
                              label: 'Remove saved document',
                              detail:
                                  retention.documentLabel ?? 'Saved document',
                              palette: palette,
                              destructive: true,
                              onTap: retention.busy
                                  ? null
                                  : onRemoveSavedDocument,
                            ),
                          ],

                          // Stored data no retained document accounts for. It
                          // blocks turning the choice on, so the way to clear it
                          // sits beside the switch it unblocks.
                          if (retention.offPolicyResidue) ...[
                            const SizedBox(height: 18),
                            ActionCard(
                              icon: Icons.cleaning_services_rounded,
                              label: 'Remove unreadable saved data',
                              detail:
                                  'Clear saved reading data from this browser',
                              palette: palette,
                              destructive: true,
                              onTap: retention.busy
                                  ? null
                                  : onRemoveRetainedData,
                            ),
                          ],

                          const SizedBox(height: 32),
                          AppearanceControls(
                            initial: settings,
                            onChanged: onSettingsChanged,
                          ),
                        ],
                      ),
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
/// browser, so `in this browser` is the strongest true statement available
/// (D-012, D-015).
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
                ? 'Unavailable because this browser is not allowing this site '
                      'to store data'
                : !state.keepForNextTime && state.offPolicyResidue
                ? 'Unavailable until saved reading data is removed'
                : 'Store this document and your reading place in this browser '
                      'so you can continue after reopening the app.',
            style: TextStyle(fontSize: 12.5, height: 1.4, color: palette.muted),
          ),
        ),
      ),
    );
  }
}

/// The caveat the switch's own helper cannot carry.
///
/// Deliberately one short line. Human Authority removed the longer ON/OFF
/// prose after physical-phone evidence: the helper above already says what
/// the choice does, and on a small phone the extra paragraphs pushed the rest
/// of Settings past the first screen. What had to survive is the part the
/// helper cannot say - that this is browser-local and browser-owned - held to
/// the same bounds as every other retention string (D-015).
class _KeepForNextTimeExplanation extends StatelessWidget {
  const _KeepForNextTimeExplanation({required this.palette});

  final ReaderPalette palette;

  @override
  Widget build(BuildContext context) {
    return Text(
      'Nothing is uploaded. Clearing this site’s data in your browser '
      'settings removes it, and the browser can clear it on its own.',
      style: TextStyle(fontSize: 12.5, height: 1.45, color: palette.muted),
    );
  }
}
