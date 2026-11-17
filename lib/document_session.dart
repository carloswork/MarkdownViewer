/// The set of open documents, and which one is being read.
///
/// Pure Dart, like `models.dart`: no Flutter and no storage. The app holds one
/// [DocumentSession] and replaces it with the value each operation returns, so
/// every change is a whole new value and can be checked against the invariants
/// below in a plain unit test.
library;

import 'models.dart';

/// The order files are loaded in (D-2): alphabetical by filename, compared
/// case-insensitively, with code-unit order breaking ties. It is not natural
/// number ordering, so `10.md` comes before `9.md`.
int compareFileNames(String a, String b) {
  final folded = a.toLowerCase().compareTo(b.toLowerCase());
  return folded != 0 ? folded : a.compareTo(b);
}

/// An immutable ordered set of documents with an active one and per-document
/// reading positions.
///
/// Invariants, checked whenever a value is built:
///
///   * document IDs are unique;
///   * [activeId] names an open document whenever any are open, and is null
///     when none are;
///   * every key of [positions] is an open document, and each position belongs
///     to the document it is filed under;
///   * no two documents share a non-null `sourceName`. Any number may have a
///     null one: pasted documents have no filename, and filenames are the only
///     thing that identifies a document across loads.
///
/// Two counters describe what has changed since the value was created. Each
/// operation bumps exactly the counters for the state it changed:
/// [documentsRevision] for the documents themselves, [readingStateRevision] for
/// which one is active and where each was read to. They only ever increase.
class DocumentSession {
  DocumentSession._({
    required List<MarkdownDocument> documents,
    required this.activeId,
    required Map<String, ReadingPosition> positions,
    required this.documentsRevision,
    required this.readingStateRevision,
  }) : documents = List.unmodifiable(documents),
       positions = Map.unmodifiable(positions) {
    _checkInvariants();
  }

  /// No documents open.
  static final DocumentSession empty = DocumentSession._(
    documents: const [],
    activeId: null,
    positions: const {},
    documentsRevision: 0,
    readingStateRevision: 0,
  );

  /// The session a page lifetime starts with, from documents and positions that
  /// were stored by an earlier one.
  ///
  /// Revisions start at zero: nothing has changed yet in this page lifetime.
  /// Throws [ArgumentError] when the arguments break an invariant.
  factory DocumentSession.restored({
    required List<MarkdownDocument> documents,
    String? activeId,
    Map<String, ReadingPosition> positions = const {},
  }) {
    return DocumentSession._(
      documents: documents,
      activeId: activeId,
      positions: positions,
      documentsRevision: 0,
      readingStateRevision: 0,
    );
  }

  /// The open documents, in display order.
  final List<MarkdownDocument> documents;

  /// The document being read, or null when nothing is open.
  final String? activeId;

  /// Where each open document was last read to in this page lifetime.
  ///
  /// This is the authoritative place for the page lifetime. Durable storage is
  /// only ever written from it, and never read back into it after startup, so a
  /// write that is still pending or that failed cannot send a document back to
  /// an older place.
  final Map<String, ReadingPosition> positions;

  final int documentsRevision;
  final int readingStateRevision;

  bool get isEmpty => documents.isEmpty;

  /// The document being read, or null when nothing is open.
  MarkdownDocument? get active {
    final id = activeId;
    return id == null ? null : byId(id);
  }

  /// The IDs of the open documents.
  Set<String> get ids => {for (final document in documents) document.id};

  bool contains(String id) => documents.any((document) => document.id == id);

  MarkdownDocument? byId(String id) {
    for (final document in documents) {
      if (document.id == id) return document;
    }
    return null;
  }

  /// The open document loaded from a file named exactly [name], if any.
  ///
  /// Filenames identify documents (M2), and only filenames do: a pasted
  /// document has no name and is never found here. Names match only when they
  /// are exactly equal, so `A.md` and `a.md` are different documents.
  MarkdownDocument? byName(String name) {
    for (final document in documents) {
      if (document.sourceName == name) return document;
    }
    return null;
  }

  /// Applies one loading operation as a single change (M5).
  ///
  /// [replacements] maps the ID of an open document to the document that
  /// replaces it. The replacement takes that document's place in the order, and
  /// the replaced document's position goes with it: the new copy has a new ID
  /// and starts at the top. [adds] are appended after the existing documents, in
  /// the order given. [activeId] must be one of the documents this operation
  /// adds or puts in place.
  ///
  /// Throws [ArgumentError] and changes nothing if the result would break an
  /// invariant, a replaced ID is not open, or the operation contains no
  /// documents.
  DocumentSession commitBatch({
    List<MarkdownDocument> adds = const [],
    Map<String, MarkdownDocument> replacements = const {},
    required String activeId,
  }) {
    if (adds.isEmpty && replacements.isEmpty) {
      throw ArgumentError('A batch must contain at least one document.');
    }
    for (final replacedId in replacements.keys) {
      if (!contains(replacedId)) {
        throw ArgumentError.value(replacedId, 'replacements', 'not open');
      }
    }
    final incoming = {
      for (final document in [...adds, ...replacements.values]) document.id,
    };
    if (!incoming.contains(activeId)) {
      throw ArgumentError.value(
        activeId,
        'activeId',
        'not a document in this batch',
      );
    }
    return DocumentSession._(
      documents: [
        for (final document in documents) replacements[document.id] ?? document,
        ...adds,
      ],
      activeId: activeId,
      positions: {
        for (final entry in positions.entries)
          if (!replacements.containsKey(entry.key)) entry.key: entry.value,
      },
      documentsRevision: documentsRevision + 1,
      readingStateRevision: readingStateRevision + 1,
    );
  }

  /// Makes [id] the document being read.
  ///
  /// Activating the document that is already active changes nothing and
  /// returns this value. Throws [ArgumentError] when [id] is not open.
  DocumentSession activate(String id) {
    if (!contains(id)) throw ArgumentError.value(id, 'id', 'not open');
    if (id == activeId) return this;
    return DocumentSession._(
      documents: documents,
      activeId: id,
      positions: positions,
      documentsRevision: documentsRevision,
      readingStateRevision: readingStateRevision + 1,
    );
  }

  /// Closes [id] and reports which document is active afterwards (D-11).
  ///
  /// Closing an inactive document leaves the active one unchanged. Closing the
  /// active one activates its right neighbour, or its left one when it was
  /// last. Closing the only document leaves the session empty, and the
  /// successor is null. Throws [ArgumentError] when [id] is not open.
  ({DocumentSession session, String? successor}) close(String id) {
    final index = documents.indexWhere((document) => document.id == id);
    if (index < 0) throw ArgumentError.value(id, 'id', 'not open');
    final remaining = [...documents]..removeAt(index);
    String? successor;
    if (remaining.isEmpty) {
      successor = null;
    } else if (id != activeId) {
      successor = activeId;
    } else {
      // The right neighbour now sits at the closed document's index.
      successor = remaining[index < remaining.length ? index : index - 1].id;
    }
    final session = DocumentSession._(
      documents: remaining,
      activeId: successor,
      positions: {
        for (final entry in positions.entries)
          if (entry.key != id) entry.key: entry.value,
      },
      documentsRevision: documentsRevision + 1,
      readingStateRevision: readingStateRevision + 1,
    );
    return (session: session, successor: successor);
  }

  /// Puts [document] in place of the open document with the same ID: an edit,
  /// or a change of its script preference.
  ///
  /// Its place in the order and its reading position are kept. Throws
  /// [ArgumentError] when no open document has that ID, or when the result
  /// would break an invariant.
  DocumentSession updateDocument(MarkdownDocument document) {
    if (!contains(document.id)) {
      throw ArgumentError.value(document.id, 'document.id', 'not open');
    }
    return DocumentSession._(
      documents: [
        for (final open in documents) open.id == document.id ? document : open,
      ],
      activeId: activeId,
      positions: positions,
      documentsRevision: documentsRevision + 1,
      readingStateRevision: readingStateRevision,
    );
  }

  /// Records where [position]'s document was read to.
  ///
  /// A position for a document that is no longer open is ignored: a closed or
  /// replaced document's reader can still report on its way out, after the
  /// document has gone. A position equal to the one already recorded changes
  /// nothing. Either way this value is returned unchanged.
  DocumentSession recordPosition(ReadingPosition position) {
    final id = position.documentId;
    if (!contains(id)) return this;
    final current = positions[id];
    if (current != null && _samePlace(current, position)) return this;
    return DocumentSession._(
      documents: documents,
      activeId: activeId,
      positions: {...positions, id: position},
      documentsRevision: documentsRevision,
      readingStateRevision: readingStateRevision + 1,
    );
  }

  /// Whether two positions describe the same place. `savedAt` records when a
  /// place was reported, not where it is, so it is not compared.
  static bool _samePlace(ReadingPosition a, ReadingPosition b) =>
      a.documentId == b.documentId &&
      a.blockIndex == b.blockIndex &&
      a.fraction == b.fraction &&
      a.headingText == b.headingText;

  void _checkInvariants() {
    final seenIds = <String>{};
    final seenNames = <String>{};
    for (final document in documents) {
      if (!seenIds.add(document.id)) {
        throw ArgumentError.value(document.id, 'documents', 'duplicate ID');
      }
      final name = document.sourceName;
      if (name != null && !seenNames.add(name)) {
        throw ArgumentError.value(name, 'documents', 'duplicate filename');
      }
    }
    final active = activeId;
    if (documents.isEmpty) {
      if (active != null) {
        throw ArgumentError.value(active, 'activeId', 'no documents are open');
      }
    } else if (active == null || !seenIds.contains(active)) {
      throw ArgumentError.value(active, 'activeId', 'not an open document');
    }
    for (final entry in positions.entries) {
      if (!seenIds.contains(entry.key)) {
        throw ArgumentError.value(entry.key, 'positions', 'not open');
      }
      if (entry.value.documentId != entry.key) {
        throw ArgumentError.value(
          entry.value.documentId,
          'positions',
          'filed under "${entry.key}"',
        );
      }
    }
  }
}

/// Issues document IDs that are unique for the page lifetime.
///
/// `MarkdownDocument.fromSource` derives an ID from the clock, and on the web
/// the clock has millisecond resolution, so documents created together in one
/// batch can get the same ID. This issues `<microsecondsSinceEpoch>-<sequence>`
/// instead: the sequence only ever increases, so no two IDs from one allocator
/// are equal however fast they are asked for, and a candidate that is already
/// in use - an open document, or an ID passed to [reserve] - is skipped.
///
/// IDs are opaque. Nothing parses them, and IDs in any older format, such as
/// the plain numbers earlier releases stored, stay valid beside these.
class DocumentIdAllocator {
  DocumentIdAllocator({int Function()? clock})
    : _clock = clock ?? (() => DateTime.now().microsecondsSinceEpoch);

  final int Function() _clock;
  int _sequence = 0;
  final Set<String> _reserved = {};

  /// Makes [ids] unavailable for the rest of the page lifetime: IDs restored
  /// from storage, and IDs of documents whose removal must not be undone by a
  /// new document taking the same ID.
  void reserve(Iterable<String> ids) => _reserved.addAll(ids);

  bool isReserved(String id) => _reserved.contains(id);

  /// One new ID that is not in [inUse] and not reserved.
  String allocate([Set<String> inUse = const {}]) =>
      allocateBatch(1, inUse).single;

  /// [count] new IDs, distinct from each other, from [inUse] and from every
  /// reserved ID. Loading several files at once uses this.
  List<String> allocateBatch(int count, [Set<String> inUse = const {}]) {
    if (count < 0) throw ArgumentError.value(count, 'count', 'is negative');
    final issued = <String>[];
    while (issued.length < count) {
      final candidate = '${_clock()}-${_sequence++}';
      if (_reserved.contains(candidate) || inUse.contains(candidate)) continue;
      issued.add(candidate);
    }
    return issued;
  }
}
