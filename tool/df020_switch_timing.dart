// ignore_for_file: avoid_web_libraries_in_flutter

// DF-020 V-17: switch latency against open latency, in the real app.
//
// Verification support, not product code. Built with
//   flutter build web --release -t tool/df020_switch_timing.dart \
//     --dart-define=DF020_TIMING=true
// and driven by test/browser/df020_switch_timing.mjs.
//
// It runs the real MarkdownViewerApp exactly as main() starts it, and exposes
// window.df020Open / df020OpenStress / df020Activate / df020Close, which call
// the app's own open (the intake commit) and activate paths through the
// DF020_TIMING seam. Each path reports the instant its session change is
// applied and the instant after the frame in which the incoming Reader first
// builds; both are read with performance.now().

import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:markdown_viewer/main.dart';
import 'package:markdown_viewer/retention.dart';
import 'package:markdown_viewer/store.dart';
import 'package:web/web.dart' as web;

import 'df041_cp1_performance.dart' show df041StressFixture;

@JS('df020Open')
external set _open(JSFunction value);
@JS('df020OpenStress')
external set _openStress(JSFunction value);
@JS('df020Activate')
external set _activate(JSFunction value);
@JS('df020Close')
external set _close(JSFunction value);
@JS('df020Marks')
external set _marks(JSFunction value);

final List<Map<String, Object>> _recorded = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await store.init();
  final startup = await retention.resolveStartup();

  Df020Timing.onMark = (phase, id) => _recorded.add({
    'phase': phase,
    'id': id,
    't': web.window.performance.now(),
  });

  runApp(
    MarkdownViewerApp(
      initialSettings: startup.settingsLoad.settings,
      initialDocument: startup.effectivePolicy == RetentionPolicy.on
          ? store.loadDocument()
          : null,
      startup: startup,
    ),
  );

  String? stress;
  _open = ((JSString name, JSString text) => Df020Timing.open(
    name.toDart,
    text.toDart,
  ).toJS).toJS;
  _openStress = (() {
    stress ??= df041StressFixture();
    return Df020Timing.open('f1.md', stress!).toJS;
  }).toJS;
  _activate = ((JSString id) => Df020Timing.activate(id.toDart)).toJS;
  _close = ((JSString id) => Df020Timing.close(id.toDart).toJS).toJS;
  _marks = (() => jsonEncode(_recorded).toJS).toJS;
  web.document.body?.dataset['df020TimingReady'] = 'true';
}
