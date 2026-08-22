/// Pure Dart domain models.
///
/// This file must not import Flutter or any platform library. It is the part of
/// the app that a future native iOS build reuses unchanged, and keeping it plain
/// also makes it trivially unit-testable.
library;

/// How the app picks its colour scheme.
///
/// Deliberately not `ThemeMode`: that would drag Flutter into the domain layer.
/// The UI maps this onto `ThemeMode` at the top of the widget tree.
enum AppearanceMode { system, light, dark }

AppearanceMode _appearanceFromName(String? name) {
  return AppearanceMode.values.firstWhere(
    (m) => m.name == name,
    orElse: () => AppearanceMode.system,
  );
}

/// Where a document's text came from.
///
/// Kept explicit rather than derived from `sourceName != null` so display logic
/// reads honestly and a future import path has somewhere to go.
enum DocumentOrigin { pasted, file }

DocumentOrigin _originFromName(String? name) {
  return DocumentOrigin.values.firstWhere(
    (o) => o.name == name,
    orElse: () => DocumentOrigin.pasted,
  );
}

/// Shown when a document has no filename of its own.
const String kPastedDocumentLabel = 'Pasted document';

/// The single document V1 holds.
///
/// `id` exists so that adding a document list later needs no data migration,
/// but V1 only ever stores one.
class MarkdownDocument {
  const MarkdownDocument({
    required this.id,
    required this.title,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
    this.sourceName,
    this.origin = DocumentOrigin.pasted,
  });

  final String id;
  final String title;
  final String source;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// The original filename, when the document came from a file. Metadata, not
  /// the title: [title] stays derived from the first heading either way.
  final String? sourceName;

  final DocumentOrigin origin;

  /// How the document identifies itself in the UI.
  String get identityLabel => sourceName ?? kPastedDocumentLabel;

  int get characterCount => source.length;

  /// Rough reading-time estimate, used only as a subtitle on the empty/menu UI.
  int get wordCount =>
      source.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

  MarkdownDocument copyWith({
    String? title,
    String? source,
    DateTime? updatedAt,
  }) {
    return MarkdownDocument(
      id: id,
      title: title ?? this.title,
      source: source ?? this.source,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      // Editing changes the local copy, never where it came from.
      sourceName: sourceName,
      origin: origin,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'source': source,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'sourceName': sourceName,
    'origin': origin.name,
  };

  /// Tolerates documents written by any earlier build: a stored document with no
  /// `sourceName`/`origin` reads back as a pasted document, which is what it was.
  /// No migration step and no schema version are needed.
  static MarkdownDocument fromJson(Map<String, dynamic> json) {
    return MarkdownDocument(
      id: json['id'] as String,
      title: json['title'] as String? ?? 'Untitled',
      source: json['source'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      sourceName: json['sourceName'] as String?,
      origin: _originFromName(json['origin'] as String?),
    );
  }

  /// Builds a document from freshly pasted, loaded or edited text.
  ///
  /// Passing [sourceName] marks it as file-loaded.
  factory MarkdownDocument.fromSource(
    String source, {
    String? id,
    DateTime? createdAt,
    String? sourceName,
  }) {
    final now = DateTime.now();
    return MarkdownDocument(
      id: id ?? now.microsecondsSinceEpoch.toString(),
      title: deriveTitle(source),
      source: source,
      createdAt: createdAt ?? now,
      updatedAt: now,
      sourceName: sourceName,
      origin: sourceName == null ? DocumentOrigin.pasted : DocumentOrigin.file,
    );
  }

  /// First ATX heading, else first non-empty line, else 'Untitled'.
  ///
  /// Lines inside fenced code blocks are skipped so that a leading fence
  /// containing a `# comment` does not become the title.
  static String deriveTitle(String source) {
    var inFence = false;
    String? firstText;

    for (final rawLine in source.split('\n')) {
      final line = rawLine.trim();
      if (line.startsWith('```') || line.startsWith('~~~')) {
        inFence = !inFence;
        continue;
      }
      if (inFence || line.isEmpty) continue;

      final heading = RegExp(r'^#{1,6}\s+(.*)$').firstMatch(line);
      if (heading != null) {
        final text = _cleanInline(heading.group(1) ?? '');
        if (text.isNotEmpty) return _truncate(text);
      }
      firstText ??= line;
    }

    if (firstText != null) {
      final text = _cleanInline(firstText);
      if (text.isNotEmpty) return _truncate(text);
    }
    return 'Untitled';
  }

  /// Strips the inline markers most likely to show up in a heading. This is
  /// cosmetic only - it does not need to be a full Markdown parser.
  static String _cleanInline(String input) {
    return input
        .replaceAll(RegExp(r'[*_`]'), '')
        .replaceAllMapped(
          RegExp(r'\[([^\]]*)\]\([^)]*\)'),
          (m) => m.group(1) ?? '',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _truncate(String text, {int max = 60}) {
    if (text.length <= max) return text;
    return '${text.substring(0, max - 1).trimRight()}…';
  }
}

/// Approximately where the reader stopped.
///
/// Stored as a block index plus how far into that block we were, never as a
/// pixel offset: rotation, a font-size change and Safari's collapsing URL bar
/// all invalidate pixels, and being roughly right beats being precisely wrong.
class ReadingPosition {
  const ReadingPosition({
    required this.documentId,
    required this.blockIndex,
    required this.fraction,
    this.headingText,
    required this.savedAt,
  });

  final String documentId;

  /// Index into the rendered top-level block list.
  final int blockIndex;

  /// How far into that block the viewport top sits, as a proportion of the
  /// viewport height. 0.0 means the block starts exactly at the top.
  final double fraction;

  /// Nearest preceding heading. Human-readable aid for debugging and review;
  /// V1 does not use it to recover position.
  final String? headingText;

  final DateTime savedAt;

  Map<String, dynamic> toJson() => {
    'documentId': documentId,
    'blockIndex': blockIndex,
    'fraction': fraction,
    'headingText': headingText,
    'savedAt': savedAt.toIso8601String(),
  };

  static ReadingPosition fromJson(Map<String, dynamic> json) {
    return ReadingPosition(
      documentId: json['documentId'] as String? ?? '',
      blockIndex: (json['blockIndex'] as num?)?.toInt() ?? 0,
      fraction: (json['fraction'] as num?)?.toDouble() ?? 0,
      headingText: json['headingText'] as String?,
      savedAt:
          DateTime.tryParse(json['savedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// User preferences. Small enough to live beside the document in one store.
class Settings {
  const Settings({
    this.appearance = AppearanceMode.system,
    this.fontScale = 1.0,
    this.wrapCode = false,
  });

  final AppearanceMode appearance;

  /// Multiplies all text. Required because Flutter Web/CanvasKit does not honour
  /// the iOS system text-size setting.
  final double fontScale;

  /// Soft-wrap long code lines instead of scrolling them horizontally.
  final bool wrapCode;

  static const double minFontScale = 0.85;
  static const double maxFontScale = 1.60;

  Settings copyWith({
    AppearanceMode? appearance,
    double? fontScale,
    bool? wrapCode,
  }) {
    return Settings(
      appearance: appearance ?? this.appearance,
      fontScale: fontScale ?? this.fontScale,
      wrapCode: wrapCode ?? this.wrapCode,
    );
  }

  Map<String, dynamic> toJson() => {
    'appearance': appearance.name,
    'fontScale': fontScale,
    'wrapCode': wrapCode,
  };

  static Settings fromJson(Map<String, dynamic> json) {
    final scale = (json['fontScale'] as num?)?.toDouble() ?? 1.0;
    return Settings(
      appearance: _appearanceFromName(json['appearance'] as String?),
      fontScale: scale.clamp(minFontScale, maxFontScale),
      wrapCode: json['wrapCode'] as bool? ?? false,
    );
  }
}

/// One entry in the generated table of contents.
class TocEntry {
  const TocEntry({
    required this.level,
    required this.text,
    required this.blockIndex,
  });

  /// 1 for h1 through 6 for h6.
  final int level;
  final String text;

  /// Index into the rendered block list - the same coordinate space as
  /// [ReadingPosition.blockIndex], so a TOC jump and a resume use one mechanism.
  final int blockIndex;
}
