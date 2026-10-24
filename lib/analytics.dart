import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'audio_engine.dart';
import 'firebase_options.dart';

/// Usage events for retention and funnel questions (first_open, session_start,
/// user_engagement and app_remove come from the SDK itself). Every call is
/// fire-and-forget: analytics must never block or break the audio path.
class Analytics {
  Analytics._();

  static FirebaseAnalytics? _fa;

  static Future<void> init() async {
    try {
      await Firebase.initializeApp(options: firebaseOptions);
      _fa = FirebaseAnalytics.instance;
    } catch (e) {
      debugPrint('analytics init failed: $e');
    }
  }

  static void _log(String name, Map<String, Object> params) {
    final fa = _fa;
    if (fa == null) return;
    fa.logEvent(name: name, parameters: params).catchError((Object e) {
      debugPrint('analytics $name failed: $e');
    });
  }

  static void echoStart(AudioOutput output, double? latencyMs) => _log('echo_start', {
        'output': output.name,
        if (latencyMs != null) 'latency_ms': latencyMs.round(),
      });

  /// [reason]: 'user' for the in-app button, otherwise the native stop reason.
  static void echoStop(String reason, Duration? played) => _log('echo_stop', {
        'reason': reason,
        if (played != null) 'duration_s': played.inSeconds,
      });

  /// [cause]: permission_denied, permission_permanent, engine, background, error.
  static void startFailed(String cause) => _log('start_failed', {'cause': cause});

  static void presetSelect(String name) => _log('preset_select', {'name': name});
}
