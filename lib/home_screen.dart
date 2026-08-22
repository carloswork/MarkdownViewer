import 'package:flutter/material.dart';

import 'markdown_theme.dart';
import 'models.dart';

/// The document entry point.
///
/// Replaces the old empty state, which was only reachable while no document
/// existed and so left the app feeling locked to whatever was loaded first.
/// Reaching this screen never unloads the stored document - that is what makes
/// "Continue reading" meaningful.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.document,
    required this.onContinue,
    required this.onPaste,
    required this.onLoadFile,
    required this.onOpenSettings,
  });

  /// The stored document, if there is one.
  final MarkdownDocument? document;

  final VoidCallback onContinue;
  final VoidCallback onPaste;
  final VoidCallback onLoadFile;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final palette = ReaderPalette.of(context);
    final current = document;

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
                        Text(
                          'Markdown Reader',
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                            color: palette.text,
                          ),
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
                        const SizedBox(height: 26),
                        if (current != null) ...[
                          _HomeAction(
                            icon: Icons.menu_book_rounded,
                            label: 'Continue reading',
                            detail: current.identityLabel,
                            palette: palette,
                            prominent: true,
                            onTap: onContinue,
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

/// One tappable row. Deliberately plain: an icon for recognition, a label, and
/// one line of context. Not a card design exercise.
class _HomeAction extends StatelessWidget {
  const _HomeAction({
    required this.icon,
    required this.label,
    required this.detail,
    required this.palette,
    required this.onTap,
    this.prominent = false,
  });

  final IconData icon;
  final String label;
  final String detail;
  final ReaderPalette palette;
  final VoidCallback onTap;

  /// The primary action gets the accent colour; the rest stay quiet.
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final foreground = prominent ? palette.link : palette.text;

    return Material(
      color: palette.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
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
                      style: TextStyle(fontSize: 12.5, color: palette.muted),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 20, color: palette.muted),
            ],
          ),
        ),
      ),
    );
  }
}
