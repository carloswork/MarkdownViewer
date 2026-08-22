import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'models.dart';

/// The only file in the app that knows persistence exists.
///
/// Hive maps to IndexedDB on web and to files on native, so nothing here is
/// web-specific and the rest of the app never imports a storage package.
/// Values are stored as JSON strings rather than Hive type adapters: the schema
/// is three small classes, there is no code generation to maintain, and the
/// stored data stays readable in Safari's Web Inspector during validation.
class Store {
  static const String _boxName = 'markdown_viewer';
  static const String _documentKey = 'document';
  static const String _positionKey = 'position';
  static const String _settingsKey = 'settings';

  Box<String>? _box;

  /// False when the browser refused to open the box - Private Browsing being the
  /// realistic case. The app then runs entirely in memory rather than failing.
  bool get isAvailable => _box != null;

  Future<void> init() async {
    try {
      await Hive.initFlutter();
      _box = await Hive.openBox<String>(_boxName);
    } catch (error, stack) {
      // Never fatal. A reader that cannot persist is still a usable reader.
      debugPrint('Store unavailable, continuing in memory only: $error');
      debugPrintStack(stackTrace: stack);
      _box = null;
    }
  }

  // --- Document -------------------------------------------------------------

  MarkdownDocument? loadDocument() {
    return _read(_documentKey, MarkdownDocument.fromJson);
  }

  Future<void> saveDocument(MarkdownDocument document) {
    return _write(_documentKey, document.toJson());
  }

  Future<void> clearDocument() async {
    await _delete(_documentKey);
    await _delete(_positionKey);
  }

  // --- Reading position -----------------------------------------------------

  /// Returns the stored position only when it belongs to [documentId], so a
  /// replaced document can never inherit the previous one's position.
  ReadingPosition? loadPosition(String documentId) {
    final position = _read(_positionKey, ReadingPosition.fromJson);
    if (position == null || position.documentId != documentId) return null;
    return position;
  }

  Future<void> savePosition(ReadingPosition position) {
    return _write(_positionKey, position.toJson());
  }

  // --- Settings -------------------------------------------------------------

  Settings loadSettings() {
    return _read(_settingsKey, Settings.fromJson) ?? const Settings();
  }

  Future<void> saveSettings(Settings settings) {
    return _write(_settingsKey, settings.toJson());
  }

  // --- Plumbing -------------------------------------------------------------

  T? _read<T>(String key, T Function(Map<String, dynamic>) parse) {
    final box = _box;
    if (box == null) return null;
    try {
      final raw = box.get(key);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return parse(Map<String, dynamic>.from(decoded));
    } catch (error) {
      // Corrupt or stale data must degrade to "nothing stored", never crash.
      debugPrint('Store: could not read "$key": $error');
      return null;
    }
  }

  Future<void> _write(String key, Map<String, dynamic> value) async {
    final box = _box;
    if (box == null) return;
    try {
      await box.put(key, jsonEncode(value));
    } catch (error) {
      debugPrint('Store: could not write "$key": $error');
    }
  }

  Future<void> _delete(String key) async {
    final box = _box;
    if (box == null) return;
    try {
      await box.delete(key);
    } catch (error) {
      debugPrint('Store: could not delete "$key": $error');
    }
  }
}

/// Single instance. The app is one screen deep; a container would be ceremony.
final Store store = Store();
