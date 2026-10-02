import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'ads.dart';
import 'audio_engine.dart';

// Karaoke preset — also the fresh-install default, so the first Start already sounds like one.
const double _kPresetDelayMs = 120.0;
const double _kPresetFeedback = 0.35;
const double _kPresetReverb = 0.25;

// EQ bands, low to high: 100 Hz, 400 Hz, 1 kHz, 3 kHz, 8 kHz (native order).
const List<String> _kEqBands = ['저음', '중저음', '중음', '중고음', '고음'];

// Round first, then sign: 0.3 dB is '0 dB', not '+0 dB'.
String _signedDb(double db) {
  final r = db.round();
  return '${r > 0 ? '+' : ''}$r dB';
}

const String _kStartFailed =
    '마이크를 시작하지 못했습니다. 마이크를 쓰는 다른 앱을 닫고 다시 시작해 주세요.';
const String _kBackgroundHint = '앱 화면을 연 채로 시작을 눌러 주세요.';
const String _kRestartHint = '오디오 상태를 받지 못했습니다. 앱을 닫았다가 다시 열어 주세요.';

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
  // Short state for the stage header; _hint carries the sentence that says
  // what to do, below it, where it can wrap at any font size.
  String _status = '대기 중';
  String? _hint;

  bool _boostEnabled = false;
  double _gain = 2.0;
  double _echoDelayMs = _kPresetDelayMs;
  double _echoFeedback = _kPresetFeedback;
  double _reverbMix = _kPresetReverb;
  double _masterVolume = 1.0;
  double _gateThresholdDb = -40.0;
  final List<double> _eqGains = [0.0, 0.0, 0.0, 0.0, 0.0]; // dB per band
  bool _freqShiftEnabled = false;
  double _rmsLevel = 0.0; // 0.0~1.0 선형
  StreamSubscription? _eventSub;

  final Map<String, DateTime> _lastParamSend = {};
  final Map<String, Timer> _pendingSend = {};

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
            final rms = (event['rms'] as double? ?? 0.0).clamp(0.0, 1.0);
            if ((rms - _rmsLevel).abs() > 0.005) setState(() => _rmsLevel = rms);
          } else if (type == 'state') {
            final running = event['running'] as bool? ?? false;
            final reason = event['reason'] as String?;
            // 정지 in the notification. No interstitial for it: the app may
            // be in the background, and a full-screen ad there breaks policy.
            final byUser = reason == 'user';
            if (running && !_running) {
              WakelockPlus.enable();
              _sessionStart ??= DateTime.now();
              setState(() {
                _running = true;
                _status = '실행 중';
                _hint = null;
              });
            } else if (!running && _running) {
              _engine.stop(); // make sure nothing is left capturing
              WakelockPlus.disable();
              setState(() {
                _running = false;
                _sessionStart = null;
                _status = byUser ? '정지됨' : '멈춤';
                _hint = byUser
                    ? null
                    : reason == 'background'
                        ? _kBackgroundHint
                        : '이어폰 연결이나 전화 때문에 멈췄습니다. 다시 시작해 주세요.';
              });
            }
          }
        },
        onError: (Object error) {
          debugPrint('audioEvents error: $error');
          if (!mounted) return;
          setState(() {
            _status = '연결 오류';
            _hint = _kRestartHint;
          });
        },
      );
    } catch (e) {
      // 네이티브 이벤트 채널이 아직 준비되지 않았더라도 UI는 계속 렌더링한다.
      debugPrint('audioEvents init failed: $e');
      _status = '연결 오류';
      _hint = _kRestartHint;
    }
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    for (final t in _pendingSend.values) {
      t.cancel();
    }
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _boostEnabled = p.getBool('boost') ?? false;
      _gain = (p.getDouble('gain') ?? 2.0).clamp(1.0, 4.0);
      _echoDelayMs = p.getDouble('echoDelayMs') ?? _kPresetDelayMs;
      _echoFeedback = p.getDouble('echoFeedback') ?? _kPresetFeedback;
      _reverbMix = p.getDouble('reverbMix') ?? _kPresetReverb;
      _masterVolume = p.getDouble('masterVolume') ?? 1.0;
      _gateThresholdDb = p.getDouble('gateThresholdDb') ?? -40.0;
      const eqDefaults = [0.0, 0.0, 0.0, 0.0, 0.0];
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
  void _sendParam(String key, VoidCallback send) {
    const window = Duration(milliseconds: 50);
    final now = DateTime.now();
    _pendingSend.remove(key)?.cancel();
    final last = _lastParamSend[key];
    if (last == null || now.difference(last) > window) {
      _lastParamSend[key] = now;
      send();
    } else {
      _pendingSend[key] = Timer(window, () {
        _lastParamSend[key] = DateTime.now();
        _pendingSend.remove(key);
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
          _hint = null;
        });
        final started = _sessionStart;
        _sessionStart = null;
        if (started != null) {
          StopInterstitial.maybeShow(DateTime.now().difference(started));
        }
      } else {
        final PermissionStatus mic = await Permission.microphone.request();
        if (!mic.isGranted) {
          setState(() {
            _status = '권한 필요';
            _hint = '마이크 권한을 허용해야 시작할 수 있습니다.';
          });
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

        // The microphone FGS notification (with its 정지 button) only shows if
        // this is granted. Asked here, at Start, so the reason is obvious.
        // Android stops showing the dialog by itself after two denials.
        if (Platform.isAndroid) await Permission.notification.request();

        // 스피커 경고
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('스피커로 쓰면 하울링이 생길 수 있습니다. 이어폰을 권장합니다.'),
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
          _status = ok ? '실행 중' : '시작 못 함';
          _hint = ok ? null : _kStartFailed;
        });
      }
    } on PlatformException catch (e) when (e.code == 'background') {
      setState(() {
        _status = '시작 못 함';
        _hint = _kBackgroundHint;
      });
    } catch (e) {
      debugPrint('toggle failed: $e');
      setState(() {
        _status = _running ? '연결 오류' : '시작 못 함';
        _hint = _running ? _kRestartHint : _kStartFailed;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('에코마이크'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // App Review 2.5.14: a clear, always-on indicator while the mic is live.
            // It cannot be turned off and stays visible for the whole session.
            if (_running) const _MicLiveBanner(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
              _StageHeader(running: _running, status: _status),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
              if (_hint != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _hint!,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.error),
                  ),
                ),
              _LevelMeter(level: _rmsLevel),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: _applyKaraokePreset,
                icon: const Icon(Icons.mic_external_on),
                label: const Text('노래방 에코로 맞추기'),
              ),
              const SizedBox(height: 8),
              _SliderTile(
                label: '에코 길이',
                value: _echoDelayMs,
                min: 0.0,
                max: 500.0,
                valueLabel: '${_echoDelayMs.round()} ms',
                onChanged: (v) {
                  setState(() => _echoDelayMs = v);
                  _sendParam('echoDelay', () => _engine.setEchoDelay(v));
                },
                onChangeEnd: (_) => _savePrefs(),
              ),
              _SliderTile(
                label: '에코 반복',
                value: _echoFeedback,
                min: 0.0,
                max: 0.8,
                valueLabel: '${(_echoFeedback * 100).round()}%',
                onChanged: (v) {
                  setState(() => _echoFeedback = v);
                  _sendParam('echoFeedback', () => _engine.setEchoFeedback(v));
                },
                onChangeEnd: (_) => _savePrefs(),
              ),
              _SliderTile(
                label: '리버브',
                value: _reverbMix,
                min: 0.0,
                max: 1.0,
                valueLabel: '${(_reverbMix * 100).round()}%',
                onChanged: (v) {
                  setState(() => _reverbMix = v);
                  _sendParam('reverb', () => _engine.setReverbMix(v));
                },
                onChangeEnd: (_) => _savePrefs(),
              ),
              _SliderTile(
                label: '볼륨',
                value: _masterVolume,
                min: 0.0,
                max: 1.0,
                valueLabel: '${(_masterVolume * 100).round()}%',
                onChanged: (v) {
                  setState(() => _masterVolume = v);
                  _sendParam('master', () => _engine.setMasterVolume(v));
                },
                onChangeEnd: (_) => _savePrefs(),
              ),
              // Fine-tuning most singers never need; kept out of the first screen.
              ExpansionTile(
                title: const Text('고급 설정'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                maintainState: true,
                children: [
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
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                  _SliderTile(
                    label: '증폭 크기',
                    value: _gain,
                    min: 1.0,
                    max: 4.0, // native caps gain at 4x (8x clipped through the limiter)
                    valueLabel: _boostEnabled
                        ? '${_gain.toStringAsFixed(1)}배'
                        : '1.0배',
                    // Native pins gain to 1.0 while boost is off.
                    onChanged: _boostEnabled
                        ? (v) {
                            setState(() => _gain = v);
                            _sendParam('gain', () => _engine.setGain(v));
                          }
                        : null,
                    onChangeEnd: (_) => _savePrefs(),
                  ),
                  _SliderTile(
                    label: '노이즈 게이트',
                    value: _gateThresholdDb,
                    min: -60.0,
                    max: -10.0,
                    valueLabel: '${_gateThresholdDb.round()} dB',
                    onChanged: (v) {
                      setState(() => _gateThresholdDb = v);
                      _sendParam('gate', () => _engine.setGateThreshold(v));
                    },
                    onChangeEnd: (_) => _savePrefs(),
                  ),
                  // Horizontal like every other slider: vertical EQ sliders
                  // grabbed the page's scroll drag and silently moved bands.
                  for (int band = 0; band < _kEqBands.length; band++)
                    _SliderTile(
                      label: 'EQ ${_kEqBands[band]}',
                      value: _eqGains[band],
                      min: -12,
                      max: 12,
                      valueLabel: _signedDb(_eqGains[band]),
                      onChanged: (v) {
                        setState(() => _eqGains[band] = v);
                        _sendParam('eq$band', () => _engine.setEQBand(band, v));
                      },
                      onChangeEnd: (_) => _savePrefs(),
                    ),
                  SwitchListTile(
                    title: const Text('하울링 억제'),
                    subtitle: const Text('스피커에서 삐 소리가 나면 켜세요'),
                    value: _freqShiftEnabled,
                    onChanged: (v) {
                      setState(() => _freqShiftEnabled = v);
                      _engine.setFrequencyShift(v);
                      _savePrefs();
                    },
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                ],
              ),
              const SizedBox(height: 8),
                  ],
                ),
              ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: SizedBox(
                height: 64,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _toggle,
                  icon: Icon(_running ? Icons.stop : Icons.play_arrow),
                  label: Text(
                    _running ? '정지' : '시작',
                    style: const TextStyle(fontSize: 20),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: _running ? cs.error : cs.primary,
                  ),
                ),
              ),
            ),
            // AdMob: keep the banner well clear of the Start/Stop button so a
            // thumb aimed at the button cannot land on the ad (~49dp gap).
            const Divider(height: 1),
            const SizedBox(height: 24),
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
          Text('입력 소리', style: Theme.of(context).textTheme.titleSmall),
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

/// Stage photo behind the status line. Grey and dim while idle, full colour
/// once the mic is live, so the state reads at a glance from across the room.
class _StageHeader extends StatelessWidget {
  const _StageHeader({required this.running, required this.status});

  final bool running;
  final String status;

  // Saturation s and brightness b as a colour matrix (luma weights Rec. 709).
  static List<double> _grade(double s, double b) {
    const r = 0.2126, g = 0.7152, bl = 0.0722;
    final i = 1 - s;
    return [
      b * (i * r + s), b * i * g, b * i * bl, 0, 0,
      b * i * r, b * (i * g + s), b * i * bl, 0, 0,
      b * i * r, b * i * g, b * (i * bl + s), 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    // 150dp keeps the volume slider above the fold on a 412x915dp phone.
    return SizedBox(
      height: 150,
      child: Stack(
        fit: StackFit.expand,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(end: running ? 1 : 0),
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeOut,
            builder: (context, t, child) => ColorFiltered(
              colorFilter: ColorFilter.matrix(_grade(t, 0.55 + 0.45 * t)),
              child: child,
            ),
            child: Image.asset(
              'assets/photos/header_mic.jpg',
              fit: BoxFit.cover,
              alignment: const Alignment(0, -0.3),
              excludeFromSemantics: true,
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [surface.withValues(alpha: 0), surface],
                stops: const [0.45, 1],
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 12,
            child: Text(
              status,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Red "mic on" bar shown for the whole time the microphone is capturing
/// (App Store guideline 2.5.14 — recording must be clearly indicated).
class _MicLiveBanner extends StatefulWidget {
  const _MicLiveBanner();

  @override
  State<_MicLiveBanner> createState() => _MicLiveBannerState();
}

class _MicLiveBannerState extends State<_MicLiveBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: '마이크 사용 중',
      child: Container(
        width: double.infinity,
        color: const Color(0xFFD32F2F),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            FadeTransition(
              opacity: Tween<double>(begin: 0.35, end: 1).animate(_pulse),
              child: const Icon(Icons.fiber_manual_record, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.mic, color: Colors.white, size: 20),
            const SizedBox(width: 6),
            // Wraps instead of truncating: "not recorded" must stay visible on narrow phones.
            const Flexible(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                    text: '마이크 사용 중\n',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(text: '녹음하거나 저장하지 않습니다.'),
                ]),
                style: TextStyle(color: Colors.white, fontSize: 13, height: 1.3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
