import 'package:flutter/material.dart';

import 'han_script.dart';
import 'markdown_theme.dart';
import 'models.dart';

/// The user-facing name for a resolved script.
String hanScriptLabel(HanScript script) => switch (script) {
  HanScript.hant => kTraditionalChineseLabel,
  HanScript.hans => kSimplifiedChineseLabel,
};

const String kAutoLabel = 'Auto';
const String kTraditionalChineseLabel = 'Traditional Chinese';
const String kSimplifiedChineseLabel = 'Simplified Chinese';

/// The reader menu's `Language` subtitle: the **effective** state.
///
/// It deliberately distinguishes an `Auto` that *resolved to* Traditional from
/// an explicit Traditional, because that is how the user tells whether the app
/// inferred the convention or whether they overrode it (plan.md §5.6.2).
String scriptPreferenceSubtitle(
  DocumentScriptPreference preference,
  HanScript resolved,
) => switch (preference) {
  DocumentScriptPreference.auto => 'Automatic — ${hanScriptLabel(resolved)}',
  DocumentScriptPreference.traditionalChinese => kTraditionalChineseLabel,
  DocumentScriptPreference.simplifiedChinese => kSimplifiedChineseLabel,
};

/// The document's script-rendering control. Changes apply live and are
/// persisted by the caller, exactly as the Appearance sheet behaves.
///
/// A dedicated selection sheet rather than a submenu expanding inside the reader
/// menu: the reader menu closes and this opens, which is how `Appearance`
/// already behaves (plan.md §5.6.3, §1.7 UX-2).
///
/// [resolved] is what the detector currently returns for this document, shown as
/// subordinate text under `Auto`. It is passed in rather than recomputed here so
/// the sheet and the menu subtitle cannot disagree.
Future<void> showScriptRenderingSheet(
  BuildContext context, {
  required DocumentScriptPreference preference,
  required HanScript resolved,
  required ValueChanged<DocumentScriptPreference> onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: ReaderPalette.of(context).background,
    builder: (context) => _ScriptRenderingSheet(
      initial: preference,
      resolved: resolved,
      onChanged: onChanged,
    ),
  );
}

class _ScriptRenderingSheet extends StatefulWidget {
  const _ScriptRenderingSheet({
    required this.initial,
    required this.resolved,
    required this.onChanged,
  });

  final DocumentScriptPreference initial;
  final HanScript resolved;
  final ValueChanged<DocumentScriptPreference> onChanged;

  @override
  State<_ScriptRenderingSheet> createState() => _ScriptRenderingSheetState();
}

class _ScriptRenderingSheetState extends State<_ScriptRenderingSheet> {
  late DocumentScriptPreference _preference = widget.initial;

  /// Live apply, with no OK/Cancel step.
  ///
  /// The write path is a `copyWith` plus a save plus a `setState`: there is no
  /// partially-applied intermediate state, no validation that can fail and no
  /// destructive effect, so a confirmation would add a step to a two-tap
  /// reversible presentation change for no safety gain (plan.md §5.6.3).
  void _update(DocumentScriptPreference next) {
    if (next == _preference) return;
    setState(() => _preference = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    // Read from the live theme rather than the captured one, so the sheet
    // recolours immediately if the mode changes underneath it.
    final palette = ReaderPalette.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Label('Language', palette),
            const SizedBox(height: 4),
            // RadioListTile rather than the SegmentedButton the Appearance sheet
            // uses: these three labels are far longer than System/Light/Dark and
            // would truncate on a phone, and a list absorbs a fourth value from a
            // future script pack where a segmented control does not. The
            // divergence from local precedent is deliberate (plan.md §5.6.3).
            RadioGroup<DocumentScriptPreference>(
              groupValue: _preference,
              onChanged: (value) {
                if (value != null) _update(value);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _row(
                    palette,
                    value: DocumentScriptPreference.auto,
                    label: kAutoLabel,
                    // Naming what the detector currently returns is the only way
                    // the user can tell an inferred convention from a chosen one.
                    subtitle: 'Detected: ${hanScriptLabel(widget.resolved)}',
                  ),
                  _row(
                    palette,
                    value: DocumentScriptPreference.traditionalChinese,
                    label: kTraditionalChineseLabel,
                  ),
                  _row(
                    palette,
                    value: DocumentScriptPreference.simplifiedChinese,
                    label: kSimplifiedChineseLabel,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    ReaderPalette palette, {
    required DocumentScriptPreference value,
    required String label,
    String? subtitle,
  }) {
    return RadioListTile<DocumentScriptPreference>(
      value: value,
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: TextStyle(fontSize: 15, color: palette.text)),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: TextStyle(fontSize: 12.5, color: palette.muted),
            ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text, this.palette);

  final String text;
  final ReaderPalette palette;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          color: palette.muted,
        ),
      ),
    );
  }
}
