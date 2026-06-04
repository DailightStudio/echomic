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
}
