import 'package:flutter/material.dart';

import 'markdown_theme.dart';
import 'models.dart';

/// Appearance controls. Changes apply live and are persisted by the caller.
Future<void> showSettingsSheet(
  BuildContext context, {
  required Settings settings,
  required ValueChanged<Settings> onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: ReaderPalette.of(context).background,
    builder: (context) =>
        _SettingsSheet(initial: settings, onChanged: onChanged),
  );
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.initial, required this.onChanged});

  final Settings initial;
  final ValueChanged<Settings> onChanged;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late Settings _settings = widget.initial;

  void _update(Settings next) {
    setState(() => _settings = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    // Read from the live theme rather than the captured one so the sheet
    // recolours immediately when the mode changes underneath it.
    final palette = ReaderPalette.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Label('Appearance', palette),
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
            _Label('Text size', palette),
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
              onChanged: (value) =>
                  _update(_settings.copyWith(wrapCode: value)),
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
        ),
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
