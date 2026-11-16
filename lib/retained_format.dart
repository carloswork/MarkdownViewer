/// How the open documents and reading state are encoded in the two content
/// keys, and how every shape those keys can hold is decoded.
///
/// Pure Dart. Both keys hold JSON **arrays** in this format, never objects:
///
/// ```text
/// document: ["saudo-document-set", 2, {"documents": [DOCUMENT, ...]}]
/// position: ["saudo-reading-state", 2,
///            {"activeId": ID, "positions": {ID: POSITION, ...}}]
/// ```
///
/// An array is what keeps older releases safe. v1.6.1 reads a content key only
/// when it decodes to a JSON object; anything else is stored data it cannot
/// open, which it sends to its generic recovery instead of offering it as a
/// document. That is a type test, not a field cast, so it holds in a compiled
/// release build.
///
/// The older single-document shapes - a document object and a position object
/// - are still read, so data stored by v1.6.1 opens as a one-document set.
library;

import 'dart:convert';

import 'models.dart';

const String kDocumentSetTag = 'saudo-document-set';
const String kReadingStateTag = 'saudo-reading-state';
const int kRetainedFormatVersion = 2;

/// What decoding the `document` key found.
enum DocumentKeyFormat {
  /// A v1.6.1 single document, read as a one-document set.
  legacy,

  /// A version-2 document set.
  current,

  /// Stored, but not something this build can open as a whole.
  undecodable,
}

class DecodedDocuments {
  const DecodedDocuments(this.format, [this.documents = const []]);

  static const DecodedDocuments undecodable = DecodedDocuments(
    DocumentKeyFormat.undecodable,
  );

  final DocumentKeyFormat format;
  final List<MarkdownDocument> documents;

  bool get isDecodable => format != DocumentKeyFormat.undecodable;
}

/// What decoding the `position` key found.
enum ReadingKeyFormat { legacy, current, undecodable }

class DecodedReadingState {
  const DecodedReadingState(
    this.format, {
    this.activeId,
    this.positions = const {},
  });

  static const DecodedReadingState undecodable = DecodedReadingState(
    ReadingKeyFormat.undecodable,
  );

  final ReadingKeyFormat format;
  final String? activeId;

  /// Every position decoded, keyed by document ID, before any filtering
  /// against an open set.
  final Map<String, ReadingPosition> positions;

  bool get isDecodable => format != ReadingKeyFormat.undecodable;
}

/// The documents projection, as written to the `document` key.
String encodeDocumentSet(List<MarkdownDocument> documents) => jsonEncode([
  kDocumentSetTag,
  kRetainedFormatVersion,
  {
    'documents': [for (final document in documents) document.toJson()],
  },
]);

/// The reading-state projection, as written to the `position` key.
String encodeReadingState(
  String? activeId,
  Map<String, ReadingPosition> positions,
) => jsonEncode([
  kReadingStateTag,
  kRetainedFormatVersion,
  {
    'activeId': activeId,
    'positions': {
      for (final entry in positions.entries) entry.key: entry.value.toJson(),
    },
  },
]);

/// Decodes the `document` key.
///
/// A set is decodable only as a whole: an unknown version, a malformed
/// envelope, an entry that does not decode, an empty set, a duplicate ID or a
/// duplicate non-null filename all make the key undecodable. Restoring part of
/// a set would hide the rest from the user while it stayed stored.
DecodedDocuments decodeDocumentKey(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return DecodedDocuments.undecodable;
  }

  if (decoded is Map) {
    final document = _documentFrom(decoded);
    return document == null
        ? DecodedDocuments.undecodable
        : DecodedDocuments(DocumentKeyFormat.legacy, [document]);
  }

  final body = _envelopeBody(decoded, kDocumentSetTag);
  final entries = body?['documents'];
  if (entries is! List || entries.isEmpty) return DecodedDocuments.undecodable;

  final documents = <MarkdownDocument>[];
  final ids = <String>{};
  final names = <String>{};
  for (final entry in entries) {
    final document = entry is Map ? _documentFrom(entry) : null;
    if (document == null || !ids.add(document.id)) {
      return DecodedDocuments.undecodable;
    }
    final name = document.sourceName;
    if (name != null && !names.add(name)) return DecodedDocuments.undecodable;
    documents.add(document);
  }
  return DecodedDocuments(DocumentKeyFormat.current, documents);
}

/// Decodes the `position` key, without reference to any document set.
DecodedReadingState decodeReadingKey(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return DecodedReadingState.undecodable;
  }

  if (decoded is Map) {
    final position = _positionFrom(decoded);
    return position == null
        ? DecodedReadingState.undecodable
        : DecodedReadingState(
            ReadingKeyFormat.legacy,
            positions: {position.documentId: position},
          );
  }

  final body = _envelopeBody(decoded, kReadingStateTag);
  if (body == null) return DecodedReadingState.undecodable;
  final activeId = body['activeId'];
  final entries = body['positions'];
  if ((activeId != null && activeId is! String) || entries is! Map) {
    return DecodedReadingState.undecodable;
  }
  final positions = <String, ReadingPosition>{};
  for (final entry in entries.entries) {
    final key = entry.key;
    final value = entry.value;
    final position = value is Map ? _positionFrom(value) : null;
    if (key is! String || position == null) {
      return DecodedReadingState.undecodable;
    }
    // A position filed under another document's ID belongs to neither.
    if (position.documentId == key) positions[key] = position;
  }
  return DecodedReadingState(
    ReadingKeyFormat.current,
    activeId: activeId as String?,
    positions: positions,
  );
}

/// Whether a raw `document` value is a committed version-2 set, the condition
/// for writing a version-2 reading state (§5.2 ordering).
bool isCurrentDocumentSet(String raw) =>
    decodeDocumentKey(raw).format == DocumentKeyFormat.current;

/// The open set, active document and positions a page lifetime starts with.
class RetainedState {
  const RetainedState({
    required this.documents,
    required this.activeId,
    required this.positions,
    required this.readingStateDecodable,
  });

  final List<MarkdownDocument> documents;
  final String activeId;
  final Map<String, ReadingPosition> positions;

  /// False when the `position` key held something undecodable: the documents
  /// restore at the top, and the saved state is out of date.
  final bool readingStateDecodable;

  MarkdownDocument get active =>
      documents.firstWhere((document) => document.id == activeId);
}

/// Combines what the two keys decoded to (§5.2).
///
/// Returns null when there is no decodable document set. Positions are kept
/// only for documents in the set. An active ID that is absent or not in the set
/// falls back to the first document, as does an undecodable reading state.
RetainedState? combineRetained(
  DecodedDocuments? documents,
  DecodedReadingState? reading,
) {
  if (documents == null || !documents.isDecodable) return null;
  final set = documents.documents;
  final ids = {for (final document in set) document.id};
  final readable = reading == null || reading.isDecodable;
  final positions = <String, ReadingPosition>{
    if (reading != null && readable)
      for (final entry in reading.positions.entries)
        if (ids.contains(entry.key)) entry.key: entry.value,
  };
  final candidate = readable ? reading?.activeId : null;
  return RetainedState(
    documents: set,
    activeId: candidate != null && ids.contains(candidate)
        ? candidate
        : set.first.id,
    positions: positions,
    readingStateDecodable: readable,
  );
}

Map<String, dynamic>? _envelopeBody(Object? decoded, String tag) {
  if (decoded is! List || decoded.length != 3) return null;
  if (decoded[0] != tag || decoded[1] != kRetainedFormatVersion) return null;
  final body = decoded[2];
  return body is Map ? Map<String, dynamic>.from(body) : null;
}

/// A document decoded as v1.6.1 decodes it, but refusing anything that is not
/// shaped like one: a string `id`, and string or absent text fields.
MarkdownDocument? _documentFrom(Map<dynamic, dynamic> map) {
  final json = Map<String, dynamic>.from(map);
  if (json['id'] is! String) return null;
  for (final field in const [
    'title',
    'source',
    'createdAt',
    'updatedAt',
    'sourceName',
    'origin',
    'scriptPreference',
  ]) {
    final value = json[field];
    if (value != null && value is! String) return null;
  }
  try {
    return MarkdownDocument.fromJson(json);
  } catch (_) {
    return null;
  }
}

ReadingPosition? _positionFrom(Map<dynamic, dynamic> map) {
  final json = Map<String, dynamic>.from(map);
  if (json['documentId'] is! String) return null;
  if (json['blockIndex'] is! num || json['fraction'] is! num) return null;
  final heading = json['headingText'];
  if (heading != null && heading is! String) return null;
  try {
    return ReadingPosition.fromJson(json);
  } catch (_) {
    return null;
  }
}
