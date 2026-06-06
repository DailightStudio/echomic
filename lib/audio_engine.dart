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
  /// 'rms': <linear RMS>}`) roughly every 50 ms while running, plus state
  /// changes (`{'type': 'state', 'running': false}`) when the engine stops
  /// unexpectedly.
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

  /// Linear input gain multiplier. Typical range 1.0 (unity) .. 4.0.
  Future<void> setGain(double gain) async {
    await _channel.invokeMethod<void>('setGain', {'gain': gain});
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
