import 'package:flutter/material.dart';

import 'markdown_theme.dart';
import 'models.dart';

/// Shows the table of contents. Resolves to the block index to jump to, or null.
Future<int?> showTocSheet(BuildContext context, List<TocEntry> entries) {
  final palette = ReaderPalette.of(context);
  return showModalBottomSheet<int>(
    context: context,
    backgroundColor: palette.background,
    isScrollControlled: true,
    builder: (context) => _TocSheet(entries: entries, palette: palette),
  );
}

class _TocSheet extends StatelessWidget {
  const _TocSheet({required this.entries, required this.palette});

  final List<TocEntry> entries;
  final ReaderPalette palette;

  @override
  Widget build(BuildContext context) {
    // Headings are indented relative to the shallowest level present, so a
    // document whose top level is h2 does not start with a wasted indent.
    final minLevel = entries
        .map((e) => e.level)
        .fold(6, (a, b) => a < b ? a : b);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                'Contents',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: palette.text,
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 12),
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final depth = (entry.level - minLevel).clamp(0, 4);
                  return InkWell(
                    onTap: () => Navigator.pop(context, entry.blockIndex),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        20.0 + depth * 16,
                        11,
                        20,
                        11,
                      ),
                      child: Text(
                        entry.text.isEmpty ? 'Untitled section' : entry.text,
                        style: TextStyle(
                          fontSize: depth == 0 ? 15.5 : 14.5,
                          height: 1.3,
                          fontWeight: depth == 0
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: depth == 0 ? palette.text : palette.muted,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
