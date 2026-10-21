import 'package:flutter/services.dart';

/// Dart wrapper around the native low-latency audio engine.
///
/// Communicates with the iOS (AVAudioEngine) and Android (Oboe/AAudio)
/// implementations through a single [MethodChannel].
class AudioEngine {
  AudioEngine._();

  static final AudioEngine instance = AudioEngine._();

  static const MethodChannel _channel =
      MethodChannel('com.dailightstudio.echomic/audio');

  static const EventChannel _events =
      EventChannel('com.dailightstudio.echomic/events');

  /// Stream of native audio events. Emits level updates (`{'type': 'level',
  /// 'rms': <linear RMS>}`) roughly every 50 ms while running, state
  /// changes (`{'type': 'state', 'running': false, 'reason': 'unplug' |
  /// 'interruption'}`, reason absent when unknown) when the engine stops
  /// unexpectedly, and route changes (`{'type': 'route', ...}` with the same
  /// payload as [routeInfo]) when an output device comes or goes.
  Stream<Map<String, dynamic>> get audioEvents =>
      _events.receiveBroadcastStream().map(
            (e) => Map<String, dynamic>.from(e as Map),
          );

  bool _running = false;

  bool get isRunning => _running;

  /// Starts capturing from the mic and routing the processed signal to the
  /// speaker. Returns `true` when the native engine started successfully.
  Future<bool> start() async {
    final bool? ok = await _channel.invokeMethod<bool>('start');
    _running = ok ?? false;
    return _running;
  }

  /// Stops the audio engine and releases the input/output streams.
  Future<void> stop() async {
    await _channel.invokeMethod<void>('stop');
    _running = false;
  }

  /// Current output route and, while running, the mic-to-ear latency estimate.
  Future<RouteInfo> routeInfo() async {
    final raw = await _channel.invokeMethod<Map>('routeInfo');
    return RouteInfo.fromMap(raw ?? const {});
  }

  /// Linear input gain multiplier. Typical range 1.0 (unity) .. 4.0.
  Future<void> setGain(double gain) async {
    await _channel.invokeMethod<void>('setGain', {'gain': gain});
  }

  /// Amplification on/off. When off, input gain is pinned to unity and the
  /// compressor's +12 dB makeup is skipped, so the voice is not made louder.
  Future<void> setBoost(bool enabled) async {
    await _channel.invokeMethod<void>('setBoost', {'enabled': enabled});
  }

  /// Echo delay time in milliseconds (0 .. 500).
  Future<void> setEchoDelay(double delayMs) async {
    await _channel.invokeMethod<void>('setEchoDelay', {'delayMs': delayMs});
  }

  /// Echo feedback amount (0.0 .. 0.8). Higher values = more repeats.
  Future<void> setEchoFeedback(double feedback) async {
    await _channel.invokeMethod<void>('setEchoFeedback', {'feedback': feedback});
  }

  /// Reverb wet/dry mix (0.0 dry .. 1.0 fully wet).
  Future<void> setReverbMix(double mix) async {
    await _channel.invokeMethod<void>('setReverbMix', {'mix': mix});
  }

  /// Master output volume multiplier (0.0 .. 1.0).
  Future<void> setMasterVolume(double volume) async {
    await _channel.invokeMethod<void>('setMasterVolume', {'volume': volume});
  }

  /// Noise gate threshold in dBFS (-80.0 .. 0.0). Default -34 dBFS.
  Future<void> setGateThreshold(double db) async {
    await _channel.invokeMethod<void>('setGateThreshold', {'db': db});
  }

  /// Set EQ band gain. band: 0-4 (100Hz/400Hz/1kHz/3kHz/8kHz), gainDb: -12..12.
  Future<void> setEQBand(int band, double gainDb) async {
    await _channel.invokeMethod<void>('setEQBand', {'band': band, 'gainDb': gainDb});
  }

  /// Enable or disable the SSB frequency shifter (anti-feedback).
  Future<void> setFrequencyShift(bool enabled) async {
    await _channel.invokeMethod<void>('setFrequencyShift', {'enabled': enabled});
  }
}

enum AudioOutput { speaker, wired, bluetooth, other }

/// Where the sound is going and how late it gets there.
class RouteInfo {
  const RouteInfo({required this.output, this.latencyMs});

  final AudioOutput output;

  /// Mic -> speaker round trip in ms; null while the engine is not running
  /// or when the platform cannot say.
  final double? latencyMs;

  static RouteInfo fromMap(Map raw) {
    final output = switch (raw['output']) {
      'speaker' => AudioOutput.speaker,
      'wired' => AudioOutput.wired,
      'bluetooth' => AudioOutput.bluetooth,
      _ => AudioOutput.other,
    };
    return RouteInfo(output: output, latencyMs: (raw['latencyMs'] as num?)?.toDouble());
  }
}
