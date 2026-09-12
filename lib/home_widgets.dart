import 'package:flutter/material.dart';

import 'markdown_theme.dart';
import 'retention.dart';

/// One line of truthful state about retention, when there is something to say.
///
/// Shown on Home and on Settings alike, so a result stays visible on whichever
/// screen the user acted from. Every string here is bounded by D-015: nothing
/// claims removal that was not verified, and nothing claims a choice will
/// survive that was not confirmed.
class RetentionAlertCard extends StatelessWidget {
  const RetentionAlertCard({
    super.key,
    required this.alert,
    required this.palette,
  });

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
      // No "try again": with no storage open there is no removal the app could
      // attempt, so the browser's own control is the only honest remedy.
      RetentionAlert.storageUnavailable => (
        'This browser is not allowing this site to store data, so nothing will '
            'be kept for next time. If reading data was saved here before, you '
            'can clear this site’s data in your browser settings.',
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

/// A full-width action card: icon, label, a detail line, and optionally what the
/// action promises.
class ActionCard extends StatelessWidget {
  const ActionCard({
    super.key,
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
