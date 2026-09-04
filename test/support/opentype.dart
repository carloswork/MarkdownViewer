import 'dart:convert';
import 'dart:typed_data';

/// A deliberately small OpenType reader, sufficient for the DF-031 successor
/// guardrail and nothing more.
///
/// DF-031 `plan.md` §10.2 puts the CI locus for the shipped-font invariants in
/// the `flutter test` suite, because the generation tool runs precisely when the
/// bytes are *expected* to change and so can never catch a shipped binary
/// drifting from its pinned identity between regenerations. Asserting the
/// repertoire and the `name` records therefore means parsing the font here.
///
/// It reads what those invariants need — the `name` table and every Unicode
/// `cmap` subtable, formats 0, 4, 6, 12 and 14 — and nothing else. It is not a
/// general font library and should not grow into one.
class OpenTypeFont {
  OpenTypeFont._(this._data, this._tables);

  final ByteData _data;
  final Map<String, ({int offset, int length})> _tables;

  /// Parses the SFNT table directory. Handles both `OTTO` (CFF outlines, which
  /// the two Han derivatives use) and TrueType, which share this header.
  factory OpenTypeFont.parse(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final numTables = data.getUint16(4);
    final tables = <String, ({int offset, int length})>{};
    for (var i = 0; i < numTables; i++) {
      final record = 12 + i * 16;
      final tag = String.fromCharCodes(bytes.sublist(record, record + 4));
      tables[tag] = (
        offset: data.getUint32(record + 8),
        length: data.getUint32(record + 12),
      );
    }
    return OpenTypeFont._(data, tables);
  }

  bool hasTable(String tag) => _tables.containsKey(tag);

  /// Every record in the `name` table, in table order.
  ///
  /// The whole table is returned deliberately: DF-031 `plan.md` §9.1 step 7
  /// evaluates the RFN state against *every* record, not against a handful of
  /// chosen strings, because the gate's own premise is that an RFN surviving in
  /// a retained upstream record would embed itself in the binary while a
  /// narrower check passed cleanly.
  List<NameRecord> get nameRecords {
    final table = _tables['name'];
    if (table == null) return const <NameRecord>[];
    final base = table.offset;
    final count = _data.getUint16(base + 2);
    final storage = base + _data.getUint16(base + 4);
    final records = <NameRecord>[];
    for (var i = 0; i < count; i++) {
      final r = base + 6 + i * 12;
      final platformId = _data.getUint16(r);
      final encodingId = _data.getUint16(r + 2);
      final languageId = _data.getUint16(r + 4);
      final nameId = _data.getUint16(r + 6);
      final length = _data.getUint16(r + 8);
      final offset = _data.getUint16(r + 10);
      records.add(
        NameRecord(
          nameId: nameId,
          platformId: platformId,
          encodingId: encodingId,
          languageId: languageId,
          value: _decodeName(
            platformId,
            Uint8List.sublistView(_data, storage + offset, storage + offset + length),
          ),
        ),
      );
    }
    return records;
  }

  static String _decodeName(int platformId, Uint8List raw) {
    // Platform 0 (Unicode) and platform 3 (Windows) store UTF-16BE. Platform 1
    // (Macintosh) stores MacRoman, which agrees with Latin-1 over the ASCII
    // range these fonts use.
    if (platformId == 0 || platformId == 3) {
      final units = <int>[];
      for (var i = 0; i + 1 < raw.length; i += 2) {
        units.add((raw[i] << 8) | raw[i + 1]);
      }
      return String.fromCharCodes(units);
    }
    return latin1.decode(raw, allowInvalid: true);
  }

  /// The code points mapped by **every** Unicode `cmap` subtable.
  ///
  /// Not "the best" subtable: DF-031 `plan.md` §10.1 property 7 requires formats
  /// 4, 6, 12 and, when present, 14 to be read, so a future regeneration that
  /// introduces coverage through a subtable nothing looked at cannot slip past
  /// the disjointness assertion.
  CmapCoverage get cmapCoverage {
    final table = _tables['cmap'];
    if (table == null) {
      return const CmapCoverage(codePoints: <int>{}, formats: <int>[], variationSequences: 0);
    }
    final base = table.offset;
    final numTables = _data.getUint16(base + 2);
    final codePoints = <int>{};
    final formats = <int>[];
    var variationSequences = 0;

    for (var i = 0; i < numTables; i++) {
      final record = base + 4 + i * 8;
      final platformId = _data.getUint16(record);
      final encodingId = _data.getUint16(record + 2);
      final subtable = base + _data.getUint32(record + 4);
      if (!_isUnicode(platformId, encodingId)) continue;
      final format = _data.getUint16(subtable);
      formats.add(format);
      switch (format) {
        case 0:
          for (var c = 0; c < 256; c++) {
            if (_data.getUint8(subtable + 6 + c) != 0) codePoints.add(c);
          }
        case 4:
          _readFormat4(subtable, codePoints);
        case 6:
          final first = _data.getUint16(subtable + 6);
          final count = _data.getUint16(subtable + 8);
          for (var c = 0; c < count; c++) {
            if (_data.getUint16(subtable + 10 + c * 2) != 0) codePoints.add(first + c);
          }
        case 12:
          final groups = _data.getUint32(subtable + 12);
          for (var g = 0; g < groups; g++) {
            final rec = subtable + 16 + g * 12;
            final start = _data.getUint32(rec);
            final end = _data.getUint32(rec + 4);
            for (var c = start; c <= end; c++) {
              codePoints.add(c);
            }
          }
        case 14:
          variationSequences += _readFormat14(subtable, codePoints);
      }
    }
    return CmapCoverage(
      codePoints: codePoints,
      formats: formats,
      variationSequences: variationSequences,
    );
  }

  static bool _isUnicode(int platformId, int encodingId) {
    if (platformId == 0) return true; // Unicode platform, every encoding
    if (platformId == 3) return encodingId == 1 || encodingId == 10; // BMP / full
    return false;
  }

  void _readFormat4(int subtable, Set<int> out) {
    final segCount = _data.getUint16(subtable + 6) ~/ 2;
    final endCodes = subtable + 14;
    final startCodes = endCodes + segCount * 2 + 2;
    final idDeltas = startCodes + segCount * 2;
    final idRangeOffsets = idDeltas + segCount * 2;
    for (var s = 0; s < segCount; s++) {
      final end = _data.getUint16(endCodes + s * 2);
      final start = _data.getUint16(startCodes + s * 2);
      if (start > end) continue;
      final delta = _data.getInt16(idDeltas + s * 2);
      final rangeOffsetPos = idRangeOffsets + s * 2;
      final rangeOffset = _data.getUint16(rangeOffsetPos);
      for (var c = start; c <= end && c != 0xFFFF; c++) {
        int glyph;
        if (rangeOffset == 0) {
          glyph = (c + delta) & 0xFFFF;
        } else {
          final gi = rangeOffsetPos + rangeOffset + (c - start) * 2;
          if (gi + 1 >= _data.lengthInBytes) continue;
          glyph = _data.getUint16(gi);
          if (glyph != 0) glyph = (glyph + delta) & 0xFFFF;
        }
        if (glyph != 0) out.add(c);
      }
    }
  }

  /// Unicode Variation Sequences. Returns the number of (base, selector) pairs
  /// and adds every base character to [out], so UVS-only coverage can never be
  /// invisible to a disjointness check.
  int _readFormat14(int subtable, Set<int> out) {
    final numRecords = _data.getUint32(subtable + 6);
    var pairs = 0;
    for (var i = 0; i < numRecords; i++) {
      final rec = subtable + 10 + i * 11;
      final defaultOffset = _data.getUint32(rec + 3);
      final nonDefaultOffset = _data.getUint32(rec + 7);
      if (defaultOffset != 0) {
        final table = subtable + defaultOffset;
        final ranges = _data.getUint32(table);
        for (var r = 0; r < ranges; r++) {
          final entry = table + 4 + r * 4;
          final start = (_data.getUint16(entry) << 8) | _data.getUint8(entry + 2);
          final extra = _data.getUint8(entry + 3);
          for (var c = start; c <= start + extra; c++) {
            out.add(c);
            pairs++;
          }
        }
      }
      if (nonDefaultOffset != 0) {
        final table = subtable + nonDefaultOffset;
        final mappings = _data.getUint32(table);
        for (var m = 0; m < mappings; m++) {
          final entry = table + 4 + m * 5;
          out.add((_data.getUint16(entry) << 8) | _data.getUint8(entry + 2));
          pairs++;
        }
      }
    }
    return pairs;
  }
}

class NameRecord {
  const NameRecord({
    required this.nameId,
    required this.platformId,
    required this.encodingId,
    required this.languageId,
    required this.value,
  });

  final int nameId;
  final int platformId;
  final int encodingId;
  final int languageId;
  final String value;

  @override
  String toString() =>
      'name ID $nameId (platform $platformId, language 0x'
      '${languageId.toRadixString(16).padLeft(4, '0')}): "$value"';
}

class CmapCoverage {
  const CmapCoverage({
    required this.codePoints,
    required this.formats,
    required this.variationSequences,
  });

  final Set<int> codePoints;

  /// The format of every Unicode subtable actually read, so a test can assert
  /// which formats are present rather than assuming.
  final List<int> formats;

  /// Count of (base character, variation selector) pairs across format-14
  /// subtables. Zero when no format-14 subtable exists.
  final int variationSequences;
}
