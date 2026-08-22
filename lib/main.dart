import 'package:flutter/material.dart';

import 'file_loader.dart';
import 'home_screen.dart';
import 'markdown_theme.dart';
import 'models.dart';
import 'paste_sheet.dart';
import 'reader_screen.dart';
import 'settings_sheet.dart';
import 'store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Everything is loaded before the first frame so the reader opens straight
  // into the stored document at the stored position, with the correct theme -
  // no loading state and no flash of the wrong colour scheme.
  await store.init();

  runApp(
    MarkdownViewerApp(
      initialSettings: store.loadSettings(),
      initialDocument: store.loadDocument(),
    ),
  );
}

class MarkdownViewerApp extends StatefulWidget {
  const MarkdownViewerApp({
    super.key,
    required this.initialSettings,
    required this.initialDocument,
  });

  final Settings initialSettings;
  final MarkdownDocument? initialDocument;

  @override
  State<MarkdownViewerApp> createState() => _MarkdownViewerAppState();
}

class _MarkdownViewerAppState extends State<MarkdownViewerApp> {
  late Settings _settings = widget.initialSettings;
  late MarkdownDocument? _document = widget.initialDocument;

  /// Which of the two screens is showing.
  ///
  /// This one boolean is the whole navigation model. Home is not a pushed
  /// route, so returning to it cannot lose the reader's state, and it stays
  /// reachable when a document exists - which the previous
  /// `_document == null` branch did not.
  late bool _atHome = _document == null;

  void _onSettingsChanged(Settings settings) {
    setState(() => _settings = settings);
    store.saveSettings(settings);
  }

  // --- Navigation -----------------------------------------------------------

  void _returnHome() => setState(() => _atHome = true);

  /// Reopens the stored document. Nothing to reload: it never left the store,
  /// and the reader restores its own position on mount.
  void _continueReading() => setState(() => _atHome = false);

  // --- Document entry -------------------------------------------------------

  /// Lightweight guard before discarding the document currently being read.
  /// Skipped entirely when there is nothing to lose.
  Future<bool> _confirmReplace(BuildContext context) async {
    final current = _document;
    if (current == null) return true;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Replace current document?'),
        content: Text(
          '"${current.identityLabel}" and your place in it will be removed '
          'from this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _openDocument(MarkdownDocument document) async {
    await store.clearDocument();
    await store.saveDocument(document);
    if (!mounted) return;
    setState(() {
      _document = document;
      _atHome = false;
    });
  }

  Future<void> _pasteNewDocument(BuildContext context) async {
    if (!await _confirmReplace(context)) return;
    if (!context.mounted) return;

    final source = await showMarkdownEditor(context);
    if (source == null) return;

    await _openDocument(MarkdownDocument.fromSource(source));
  }

  /// Load from file, confirming replacement only once there is something to
  /// replace the document *with*.
  ///
  /// Deliberately different from [_pasteNewDocument], which still confirms
  /// first: there the confirmation precedes the effort, and asking after
  /// someone has pasted a long document would waste it. Here the picker costs
  /// nothing to cancel, so the guard belongs after a valid choice.
  Future<void> _loadFromFile(BuildContext context) async {
    // Resolved before the await because the context must not cross it, and then
    // checked for each use: the system picker can stay open for an arbitrary
    // time, so every path below runs after an unbounded gap.
    final messenger = ScaffoldMessenger.of(context);
    void report(String text) {
      if (!messenger.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(text)));
    }

    try {
      final file = await pickMarkdownFile();
      if (file == null) return; // cancelled: nothing changes, nothing asked

      if (file.contents.trim().isEmpty) {
        report('"${file.name}" is empty.');
        return;
      }

      if (!context.mounted) return;
      if (!await _confirmReplace(context)) return;

      await _openDocument(
        MarkdownDocument.fromSource(file.contents, sourceName: file.name),
      );
    } on UnsupportedFileException catch (error) {
      report(
        'Cannot open "${error.fileName}". Choose a Markdown file '
        '(.md, .markdown or .txt).',
      );
    } catch (error) {
      // Reading can fail for reasons outside our control - permissions, a
      // browser restriction. Report it rather than leaving a dead button.
      report('Could not read that file: $error');
    }
  }

  Future<void> _editDocument(BuildContext context) async {
    final current = _document;
    if (current == null) return;

    final source = await showMarkdownEditor(
      context,
      initialText: current.source,
    );
    if (source == null || source == current.source) return;

    // The reading position is kept. Block indices usually survive a small edit,
    // and being a little off beats being sent back to the top of a long document.
    // The origin and filename are preserved too: editing changes this device's
    // copy, never the file it came from.
    final updated = current.copyWith(
      title: MarkdownDocument.deriveTitle(source),
      source: source,
      updatedAt: DateTime.now(),
    );
    await store.saveDocument(updated);
    if (!mounted) return;
    setState(() => _document = updated);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Markdown Viewer',
      debugShowCheckedModeBanner: false,
      themeMode: switch (_settings.appearance) {
        AppearanceMode.system => ThemeMode.system,
        AppearanceMode.light => ThemeMode.light,
        AppearanceMode.dark => ThemeMode.dark,
      },
      theme: buildAppTheme(ReaderPalette.light),
      darkTheme: buildAppTheme(ReaderPalette.dark),
      home: Builder(
        builder: (context) {
          final document = _document;

          if (_atHome || document == null) {
            return HomeScreen(
              document: document,
              onContinue: _continueReading,
              onPaste: () => _pasteNewDocument(context),
              onLoadFile: () => _loadFromFile(context),
              onOpenSettings: () => showSettingsSheet(
                context,
                settings: _settings,
                onChanged: _onSettingsChanged,
              ),
            );
          }

          return ReaderScreen(
            // Remounting on a document or edit change gives the list a fresh
            // initialScrollIndex, which is the only point it is read.
            key: ValueKey(
              '${document.id}:${document.updatedAt.microsecondsSinceEpoch}',
            ),
            document: document,
            settings: _settings,
            onSettingsChanged: _onSettingsChanged,
            onEdit: () => _editDocument(context),
            // The same workflow Home uses - picker, validation, replacement
            // confirmation and error handling all live in _loadFromFile.
            onLoadFile: () => _loadFromFile(context),
            onReturnHome: _returnHome,
          );
        },
      ),
    );
  }
}
