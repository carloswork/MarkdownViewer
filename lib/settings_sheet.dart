import 'package:flutter/material.dart';

import 'markdown_theme.dart';
import 'models.dart';

/// Appearance controls in a sheet, as the reader offers them. Changes apply live
/// and are persisted by the caller.
Future<void> showSettingsSheet(
  BuildContext context, {
  required Settings settings,
  required ValueChanged<Settings> onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: ReaderPalette.of(context).background,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: AppearanceControls(initial: settings, onChanged: onChanged),
      ),
    ),
  );
}

/// The appearance controls themselves, shared by the reader's sheet and the
/// Settings screen so both show exactly the same thing.
///
/// Holds its own copy of [initial] so a control moves the moment it is used.
/// That copy is a snapshot, so it is trusted only for the fields these controls
/// own: the caller merges appearance onto its live settings rather than storing
/// what comes back wholesale, which would write back whatever the snapshot held
/// for the retention choice (DF-039, D-013).
class AppearanceControls extends StatefulWidget {
  const AppearanceControls({
    super.key,
    required this.initial,
    required this.onChanged,
  });

  final Settings initial;
  final ValueChanged<Settings> onChanged;

  @override
  State<AppearanceControls> createState() => _AppearanceControlsState();
}

class _AppearanceControlsState extends State<AppearanceControls> {
  late Settings _settings = widget.initial;

  void _update(Settings next) {
    setState(() => _settings = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    // Read from the live theme rather than the captured one so the controls
    // recolour immediately when the mode changes underneath them.
    final palette = ReaderPalette.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsSectionLabel('Appearance'),
        const SizedBox(height: 8),
        SegmentedButton<AppearanceMode>(
          segments: const [
            ButtonSegment(
              value: AppearanceMode.system,
              label: Text('System'),
              icon: Icon(Icons.brightness_auto_rounded, size: 18),
            ),
            ButtonSegment(
              value: AppearanceMode.light,
              label: Text('Light'),
              icon: Icon(Icons.light_mode_rounded, size: 18),
            ),
            ButtonSegment(
              value: AppearanceMode.dark,
              label: Text('Dark'),
              icon: Icon(Icons.dark_mode_rounded, size: 18),
            ),
          ],
          selected: {_settings.appearance},
          showSelectedIcon: false,
          onSelectionChanged: (selection) =>
              _update(_settings.copyWith(appearance: selection.first)),
        ),
        const SizedBox(height: 22),
        const SettingsSectionLabel('Text size'),
        Row(
          children: [
            Icon(Icons.text_fields_rounded, size: 16, color: palette.muted),
            Expanded(
              child: Slider(
                value: _settings.fontScale,
                min: Settings.minFontScale,
                max: Settings.maxFontScale,
                // 15 steps across the range: fine enough to find a
                // comfortable size, coarse enough to hit with a thumb.
                divisions: 15,
                label: '${(_settings.fontScale * 100).round()}%',
                onChanged: (value) =>
                    _update(_settings.copyWith(fontScale: value)),
              ),
            ),
            Icon(Icons.text_fields_rounded, size: 24, color: palette.muted),
          ],
        ),
        const SizedBox(height: 4),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _settings.wrapCode,
          onChanged: (value) => _update(_settings.copyWith(wrapCode: value)),
          title: Text(
            'Wrap long code lines',
            style: TextStyle(fontSize: 15, color: palette.text),
          ),
          subtitle: Text(
            _settings.wrapCode
                ? 'Code wraps to fit the screen'
                : 'Code blocks scroll sideways',
            style: TextStyle(fontSize: 12.5, color: palette.muted),
          ),
        ),
      ],
    );
  }
}

/// A small heading over a group of settings.
class SettingsSectionLabel extends StatelessWidget {
  const SettingsSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = ReaderPalette.of(context);

    return Semantics(
      header: true,
      child: Align(
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
      ),
    );
  }
}
