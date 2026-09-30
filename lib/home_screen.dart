import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'ads.dart';
import 'audio_engine.dart';

// Karaoke preset — also the fresh-install default, so the first Start already sounds like one.
const double _kPresetDelayMs = 120.0;
const double _kPresetFeedback = 0.35;
const double _kPresetReverb = 0.25;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final AudioEngine _engine = AudioEngine.instance;

  bool _running = false;
  DateTime? _sessionStart;
  bool _busy = false;
  String _status = 'Idle';

  bool _boostEnabled = false;
  double _gain = 2.0;
  double _echoDelayMs = _kPresetDelayMs;
  double _echoFeedback = _kPresetFeedback;
  double _reverbMix = _kPresetReverb;
  double _masterVolume = 0.8;
  double _gateThresholdDb = -40.0;
  final List<double> _eqGains = [-4.0, -2.0, 0.0, -4.0, 2.0]; // dB per band
  bool _freqShiftEnabled = false;
  double _rmsLevel = 0.0; // 0.0~1.0 선형
  StreamSubscription? _eventSub;

  DateTime? _lastParamSend;
  Timer? _pendingSend;

  @override
  void initState() {
    super.initState();
    StopInterstitial.preload();
    _loadPrefs();
    try {
      _eventSub = _engine.audioEvents.listen(
        (event) {
          if (!mounted) return;
          final type = event['type'] as String?;
          if (type == 'level') {
            setState(() => _rmsLevel =
                (event['rms'] as double? ?? 0.0).clamp(0.0, 1.0));
          } else if (type == 'state') {
            final running = event['running'] as bool? ?? false;
            if (!running && _running) {
              WakelockPlus.disable();
              setState(() {
                _running = false;
                _status = '정지됨 (이어폰·통화 등 오디오 변경)';
              });
            }
          }
        },
        onError: (Object error) {
          if (!mounted) return;
          setState(() => _status = '이벤트 채널 오류: $error');
        },
      );
    } catch (e) {
      // 네이티브 이벤트 채널이 아직 준비되지 않았더라도 UI는 계속 렌더링한다.
      _status = '이벤트 채널 초기화 실패: $e';
    }
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _pendingSend?.cancel();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _boostEnabled = p.getBool('boost') ?? false;
      _gain = p.getDouble('gain') ?? 2.0;
      _echoDelayMs = p.getDouble('echoDelayMs') ?? _kPresetDelayMs;
      _echoFeedback = p.getDouble('echoFeedback') ?? _kPresetFeedback;
      _reverbMix = p.getDouble('reverbMix') ?? _kPresetReverb;
      _masterVolume = p.getDouble('masterVolume') ?? 0.8;
      _gateThresholdDb = p.getDouble('gateThresholdDb') ?? -40.0;
      const eqDefaults = [-4.0, -2.0, 0.0, -4.0, 2.0];
      for (int i = 0; i < 5; i++) {
        _eqGains[i] = p.getDouble('eq$i') ?? eqDefaults[i];
      }
      _freqShiftEnabled = p.getBool('freqShift') ?? false;
    });
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('boost', _boostEnabled);
    await p.setDouble('gain', _gain);
    await p.setDouble('echoDelayMs', _echoDelayMs);
    await p.setDouble('echoFeedback', _echoFeedback);
    await p.setDouble('reverbMix', _reverbMix);
    await p.setDouble('masterVolume', _masterVolume);
    await p.setDouble('gateThresholdDb', _gateThresholdDb);
    for (int i = 0; i < 5; i++) {
      await p.setDouble('eq$i', _eqGains[i]);
    }
    await p.setBool('freqShift', _freqShiftEnabled);
  }

  // One-tap karaoke-room sound: short slapback echo with a few repeats + some reverb.
  void _applyKaraokePreset() {
    setState(() {
      _echoDelayMs = _kPresetDelayMs;
      _echoFeedback = _kPresetFeedback;
      _reverbMix = _kPresetReverb;
    });
    _engine.setEchoDelay(_echoDelayMs);
    _engine.setEchoFeedback(_echoFeedback);
    _engine.setReverbMix(_reverbMix);
    _savePrefs();
  }

  // Throttled, but the LAST value always goes out (trailing send), so the native
  // value ends equal to what the slider shows.
  void _sendParam(VoidCallback send) {
    const window = Duration(milliseconds: 50);
    final now = DateTime.now();
    _pendingSend?.cancel();
    if (_lastParamSend == null || now.difference(_lastParamSend!) > window) {
      _lastParamSend = now;
      send();
    } else {
      _pendingSend = Timer(window, () {
        _lastParamSend = DateTime.now();
        send();
      });
    }
  }

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_running) {
        await _engine.stop();
        WakelockPlus.disable();
        setState(() {
          _running = false;
          _status = '정지됨';
        });
        final started = _sessionStart;
        if (started != null) {
          StopInterstitial.maybeShow(DateTime.now().difference(started));
        }
      } else {
        final PermissionStatus mic = await Permission.microphone.request();
        if (!mic.isGranted) {
          setState(() => _status = '마이크 권한이 필요합니다');
          if (mic.isPermanentlyDenied && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('설정에서 마이크 권한을 허용해 주세요'),
                action: SnackBarAction(label: '설정 열기', onPressed: openAppSettings),
              ),
            );
          }
          return;
        }

        // 스피커 경고
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  '🎧 이어폰 사용을 권장합니다 — 스피커 사용 시 하울링이 발생할 수 있습니다'),
              duration: Duration(seconds: 3),
            ),
          );
        }

        await _engine.setBoost(_boostEnabled);
        await _engine.setGain(_gain);
        await _engine.setEchoDelay(_echoDelayMs);
        await _engine.setEchoFeedback(_echoFeedback);
        await _engine.setReverbMix(_reverbMix);
        await _engine.setMasterVolume(_masterVolume);
        await _engine.setGateThreshold(_gateThresholdDb);
        for (int i = 0; i < 5; i++) {
          await _engine.setEQBand(i, _eqGains[i]);
        }
        await _engine.setFrequencyShift(_freqShiftEnabled);

        final bool ok = await _engine.start();
        if (ok) {
          WakelockPlus.enable();
          _sessionStart = DateTime.now();
        }
        setState(() {
          _running = ok;
          _status = ok ? '실행 중 (저지연)' : '엔진 시작 실패';
        });
      }
    } catch (e) {
      setState(() => _status = '오류: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('echomic'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
              const SizedBox(height: 8),
              Icon(
                _running ? Icons.mic : Icons.mic_off,
                size: 72,
                color: _running ? cs.primary : cs.onSurfaceVariant,
              ),
              const SizedBox(height: 4),
              Text(
                _status,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              _LevelMeter(level: _rmsLevel),
              const SizedBox(height: 8),
              SwitchListTile(
                title: const Text('증폭'),
                subtitle: Text(_boostEnabled
                    ? '목소리를 키워서 내보냅니다'
                    : '목소리를 원래 크기 그대로 내보냅니다'),
                value: _boostEnabled,
                onChanged: (v) {
                  setState(() => _boostEnabled = v);
                  _engine.setBoost(v);
                  _savePrefs();
                },
                dense: true,
              ),
              _SliderTile(
                label: 'Gain',
                value: _gain,
                min: 1.0,
                max: 8.0,
                valueLabel: _boostEnabled
                    ? '${_gain.toStringAsFixed(2)}x'
                    : '1.00x',
                // Native pins gain to 1.0 while boost is off.
                onChanged: _boostEnabled
                    ? (v) {
                        setState(() => _gain = v);
                        _sendParam(() => _engine.setGain(v));
                      }
                    : null,
                onChangeEnd: (_) => _savePrefs(),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _applyKaraokePreset,
                  icon: const Icon(Icons.mic_external_on),
                  label: const Text('노래방 에코'),
                ),
              ),
              _SliderTile(
                label: 'Echo Delay',
                value: _echoDelayMs,
                min: 0.0,
                max: 500.0,
                valueLabel: '${_echoDelayMs.round()} ms',
                onChanged: (v) {
                  setState(() => _echoDelayMs = v);
                  _sendParam(() => _engine.setEchoDelay(v));
                },
                onChangeEnd: (_) => _savePrefs(),
              ),
              _SliderTile(
                label: 'Echo Feedback',
                value: _echoFeedback,
                min: 0.0,
                max: 0.8,
                valueLabel: _echoFeedback.toStringAsFixed(2),
                onChanged: (v) {
                  setState(() => _echoFeedback = v);
                  _sendParam(() => _engine.setEchoFeedback(v));
                },
                onChangeEnd: (_) => _savePrefs(),
              ),
              _SliderTile(
                label: 'Reverb',
                value: _reverbMix,
                min: 0.0,
                max: 1.0,
                valueLabel: '${(_reverbMix * 100).round()}%',
                onChanged: (v) {
                  setState(() => _reverbMix = v);
                  _sendParam(() => _engine.setReverbMix(v));
                },
                onChangeEnd: (_) => _savePrefs(),
              ),
              _SliderTile(
                label: 'Volume',
                value: _masterVolume,
                min: 0.0,
                max: 1.0,
                valueLabel: '${(_masterVolume * 100).round()}%',
                onChanged: (v) {
                  setState(() => _masterVolume = v);
                  _sendParam(() => _engine.setMasterVolume(v));
                },
                onChangeEnd: (_) => _savePrefs(),
              ),
              _SliderTile(
                label: 'Noise Gate',
                value: _gateThresholdDb,
                min: -60.0,
                max: -10.0,
                valueLabel: '${_gateThresholdDb.round()} dB',
                onChanged: (v) {
                  setState(() => _gateThresholdDb = v);
                  _sendParam(() => _engine.setGateThreshold(v));
                },
                onChangeEnd: (_) => _savePrefs(),
              ),
              _EQStrip(
                gains: _eqGains,
                onChanged: (band, v) {
                  setState(() => _eqGains[band] = v);
                  _sendParam(() => _engine.setEQBand(band, v));
                },
                onChangeEnd: (_) => _savePrefs(),
              ),
              SwitchListTile(
                title: const Text('Anti-Feedback (Freq. Shift)'),
                subtitle: const Text('8 Hz shift — breaks feedback loop'),
                value: _freqShiftEnabled,
                onChanged: (v) {
                  setState(() => _freqShiftEnabled = v);
                  _engine.setFrequencyShift(v);
                  _savePrefs();
                },
                dense: true,
              ),
              const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: SizedBox(
                height: 64,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _toggle,
                  icon: Icon(_running ? Icons.stop : Icons.play_arrow),
                  label: Text(
                    _running ? 'Stop' : 'Start',
                    style: const TextStyle(fontSize: 20),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: _running ? cs.error : cs.primary,
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            const SizedBox(height: 12),
            const AdBanner(),
          ],
        ),
      ),
    );
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.valueLabel,
    required this.onChanged,
    this.onChangeEnd,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String valueLabel;
  final ValueChanged<double>? onChanged; // null = disabled
  final ValueChanged<double>? onChangeEnd; // nullable

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: Theme.of(context).textTheme.titleSmall),
            Text(valueLabel, style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
    );
  }
}

class _LevelMeter extends StatelessWidget {
  const _LevelMeter({required this.level});
  final double level; // 0.0~1.0 선형 RMS

  @override
  Widget build(BuildContext context) {
    // dBFS 변환 (-60~0), 0이면 -60
    final db =
        level > 0 ? (20 * (log(level) / log(10))).clamp(-60.0, 0.0) : -60.0;
    final fraction = ((db + 60) / 60).clamp(0.0, 1.0); // 0~1

    final color = fraction > 0.85
        ? Colors.red
        : fraction > 0.65
            ? Colors.orange
            : Colors.greenAccent;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Level', style: Theme.of(context).textTheme.titleSmall),
              Text('${db.toStringAsFixed(1)} dB',
                  style: Theme.of(context).textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 10,
              backgroundColor:
                  Theme.of(context).colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ],
      ),
    );
  }
}

class _EQStrip extends StatelessWidget {
  const _EQStrip({
    required this.gains,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final List<double> gains;
  final void Function(int band, double value) onChanged;
  final void Function(double) onChangeEnd;

  static const _labels = ['100Hz', '400Hz', '1kHz', '3kHz', '8kHz'];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('EQ', style: Theme.of(context).textTheme.titleSmall),
            Text(
              gains.map((g) => (g >= 0 ? '+' : '') + g.toStringAsFixed(0)).join('  '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: List.generate(5, (i) {
            return Expanded(
              child: Column(
                children: [
                  RotatedBox(
                    quarterTurns: 3,
                    child: Slider(
                      value: gains[i],
                      min: -12,
                      max: 12,
                      onChanged: (v) => onChanged(i, v),
                      onChangeEnd: onChangeEnd,
                    ),
                  ),
                  Text(
                    _labels[i],
                    style: Theme.of(context).textTheme.labelSmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }),
        ),
      ],
    );
  }
}
