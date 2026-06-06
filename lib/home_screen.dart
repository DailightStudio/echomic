import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'audio_engine.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final AudioEngine _engine = AudioEngine.instance;

  bool _running = false;
  bool _busy = false;
  String _status = 'Idle';

  double _gain = 1.0;
  double _echoDelayMs = 150.0;
  double _echoFeedback = 0.3;
  double _reverbMix = 0.0;
  double _masterVolume = 1.0;
  double _gateThresholdDb = -34.0;
  final List<double> _eqGains = [0.0, 0.0, 0.0, 0.0, 0.0]; // dB per band
  bool _freqShiftEnabled = true;
  double _rmsLevel = 0.0; // 0.0~1.0 선형
  StreamSubscription? _eventSub;

  DateTime? _lastParamSend;

  @override
  void initState() {
    super.initState();
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
              setState(() {
                _running = false;
                _status = '오디오 장치 연결 끊김';
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
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _gain = p.getDouble('gain') ?? 1.0;
      _echoDelayMs = p.getDouble('echoDelayMs') ?? 150.0;
      _echoFeedback = p.getDouble('echoFeedback') ?? 0.3;
      _reverbMix = p.getDouble('reverbMix') ?? 0.0;
      _masterVolume = p.getDouble('masterVolume') ?? 1.0;
      _gateThresholdDb = p.getDouble('gateThresholdDb') ?? -34.0;
      for (int i = 0; i < 5; i++) {
        _eqGains[i] = p.getDouble('eq$i') ?? 0.0;
      }
      _freqShiftEnabled = p.getBool('freqShift') ?? true;
    });
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
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

  void _sendParam(VoidCallback send) {
    final now = DateTime.now();
    if (_lastParamSend == null ||
        now.difference(_lastParamSend!) > const Duration(milliseconds: 50)) {
      _lastParamSend = now;
      send();
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
      } else {
        final PermissionStatus mic = await Permission.microphone.request();
        if (!mic.isGranted) {
          setState(() => _status = '마이크 권한이 필요합니다');
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
        if (ok) WakelockPlus.enable();
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
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Icon(
                _running ? Icons.mic : Icons.mic_off,
                size: 96,
                color: _running ? cs.primary : cs.onSurfaceVariant,
              ),
              const SizedBox(height: 8),
              Text(
                _status,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              _LevelMeter(level: _rmsLevel),
              const SizedBox(height: 16),
              _SliderTile(
                label: 'Gain',
                value: _gain,
                min: 1.0,
                max: 8.0,
                valueLabel: '${_gain.toStringAsFixed(2)}x',
                onChanged: (v) {
                  setState(() => _gain = v);
                  _sendParam(() => _engine.setGain(v));
                },
                onChangeEnd: (_) => _savePrefs(),
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
              const Spacer(),
              SizedBox(
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
              const SizedBox(height: 8),
            ],
          ),
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
  final ValueChanged<double> onChanged;
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
