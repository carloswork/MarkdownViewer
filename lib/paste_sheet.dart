import 'package:flutter/material.dart';

import 'markdown_theme.dart';

/// Full-screen Markdown input. Returns the text, or null if cancelled.
///
/// The same screen serves both pasting a new document and editing the raw
/// source of the current one, because they are the same interaction.
Future<String?> showMarkdownEditor(
  BuildContext context, {
  String? initialText,
}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(
      fullscreenDialog: true,
      builder: (context) => _MarkdownEditor(initialText: initialText),
    ),
  );
}

class _MarkdownEditor extends StatefulWidget {
  const _MarkdownEditor({this.initialText});

  final String? initialText;

  @override
  State<_MarkdownEditor> createState() => _MarkdownEditorState();
}

class _MarkdownEditorState extends State<_MarkdownEditor> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText ?? '',
  );
  late bool _hasText = _controller.text.trim().isNotEmpty;

  bool get _isEditing => widget.initialText != null;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final hasText = _controller.text.trim().isNotEmpty;
      if (hasText != _hasText) setState(() => _hasText = hasText);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final palette = ReaderPalette.of(context);

    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(
        backgroundColor: palette.background,
        surfaceTintColor: Colors.transparent,
        foregroundColor: palette.text,
        elevation: 0,
        leading: TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel', style: TextStyle(color: palette.muted)),
        ),
        leadingWidth: 88,
        title: Text(
          // Matches the menu wording: this edits the copy stored on this
          // device, and never writes back to a file it was loaded from.
          _isEditing ? 'Edit local copy' : 'Paste Markdown',
          style: TextStyle(fontSize: 16, color: palette.text),
        ),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _hasText ? _submit : null,
            child: Text(
              _isEditing ? 'Save' : 'Open',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: _hasText ? palette.link : palette.muted,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                // A plain TextField, filled with the device's own paste gesture.
                //
                // There is deliberately no "Paste from clipboard" button:
                // Safari restricts programmatic clipboard reads behind a
                // permission prompt and Flutter's web implementation of
                // Clipboard.getData is unreliable there. Long-press -> Paste
                // is both more reliable and fewer taps.
                child: TextField(
                  controller: _controller,
                  autofocus: !_isEditing,
                  expands: true,
                  maxLines: null,
                  minLines: null,
                  keyboardType: TextInputType.multiline,
                  textAlignVertical: TextAlignVertical.top,
                  style: TextStyle(
                    fontFamily: kCodeFont,
                    fontSize: 14,
                    height: 1.45,
                    color: palette.text,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Long-press here and choose Paste.',
                    hintStyle: TextStyle(
                      fontFamily: kBodyFont,
                      fontSize: 15,
                      color: palette.muted,
                    ),
                    filled: true,
                    fillColor: palette.surface,
                    contentPadding: const EdgeInsets.all(14),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: palette.codeBorder),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: palette.codeBorder),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Stays on this device. Nothing is uploaded.',
                style: TextStyle(fontSize: 12, color: palette.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
