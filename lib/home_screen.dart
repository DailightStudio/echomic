import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'ads.dart';
import 'analytics.dart';
import 'audio_engine.dart';
import 'recordings_screen.dart';
import 'ui_colors.dart';

// Echo/reverb presets. The first one (karaoke) is also the fresh-install
// default, so the first Start already sounds like one.
class _Preset {
  const _Preset(this.name, this.delayMs, this.feedback, this.reverb);
  final String name;
  final double delayMs;
  final double feedback;
  final double reverb;
}

const List<_Preset> _kPresets = [
  _Preset('노래방', 120.0, 0.35, 0.25),
  _Preset('콘서트홀', 220.0, 0.25, 0.6),
  _Preset('동굴', 380.0, 0.55, 0.45),
  _Preset('원음', 0.0, 0.0, 0.0),
];
final _Preset _kDefaultPreset = _kPresets.first;

// Advanced-settings defaults, restored by the reset button.
const bool _kDefaultBoost = false;
const double _kDefaultGain = 2.0;
const double _kDefaultGateDb = -40.0;
// On by default: most phones have no headphone jack, so the first Start is
// on the speaker, and the shifter is what keeps that from howling
// (tools/dsp_sim: stable to +6 dB loop gain vs howl at 0 dB without it).
const bool _kDefaultFreqShift = true;
// 1.0.2 and earlier saved the old off default under 'freqShift' for everyone,
// so the new default needs a new key to reach existing installs.
const String _kFreqShiftKey = 'freqShift2';

// Speaker mode: platform echo cancellation while the built-in speaker plays.
const String _kSpeakerAecKey = 'speakerAec';
const bool _kDefaultSpeakerAec = true;
const String _kSpeakerHint = '스피커로 쓰면 스피커 모드가 자동으로 켜져 하울링을 줄입니다. 이어폰을 쓰면 더 또렷합니다.';

const String _kGuideShownKey = 'guideShown';

// EQ bands, low to high: 100 Hz, 400 Hz, 1 kHz, 3 kHz, 8 kHz (native order).
const List<String> _kEqBands = ['저음', '중저음', '중음', '중고음', '고음'];

// Round first, then sign: 0.3 dB is '0 dB', not '+0 dB'.
String _signedDb(double db) {
  final r = db.round();
  return '${r > 0 ? '+' : ''}$r dB';
}

const String _kStartFailed =
    '마이크를 시작하지 못했습니다. 마이크를 쓰는 다른 앱을 닫고 다시 시작해 주세요.';
const int _kHeadsetHintSessions = 3;
const String _kBackgroundHint = '앱 화면을 연 채로 시작을 눌러 주세요.';
const String _kRestartHint = '오디오 상태를 받지 못했습니다. 앱을 닫았다가 다시 열어 주세요.';

// Why the engine stopped on its own (native 'reason'), in the user's words.
String _stoppedMessage(String? reason) => switch (reason) {
      'unplug' => '이어폰이 빠져서 멈췄습니다. 다시 꽂고 시작해 주세요.',
      'interruption' => '전화나 다른 앱 소리 때문에 멈췄습니다. 다시 시작해 주세요.',
      _ => '마이크 연결이 끊겨 멈췄습니다. 다시 시작해 주세요.',
    };

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
  bool _recording = false;
  DateTime? _recStart;
  // Momentary auto-tune: on while the pad is pressed or the latch is set.
  bool _tunePressed = false;
  bool _tuneLatched = false;
  DateTime? _tuneStart;
  // Elapsed recording seconds; ticked from the 50 ms level event so only the
  // record button label rebuilds.
  final ValueNotifier<int> _recSeconds = ValueNotifier(0);
  // Short state for the stage header; _hint carries the sentence that says
  // what to do, below it, where it can wrap at any font size.
  String _status = '대기 중';
  String? _hint;
  int _startCount = 0; // sessions started so far, for the one-time headset hint

  bool _boostEnabled = false;
  double _gain = _kDefaultGain;
  double _echoDelayMs = _kDefaultPreset.delayMs;
  double _echoFeedback = _kDefaultPreset.feedback;
  double _reverbMix = _kDefaultPreset.reverb;
  double _masterVolume = 1.0;
  double _gateThresholdDb = _kDefaultGateDb;
  final List<double> _eqGains = [0.0, 0.0, 0.0, 0.0, 0.0]; // dB per band
  bool _freqShiftEnabled = _kDefaultFreqShift;
  bool _speakerAecAuto = _kDefaultSpeakerAec; // user policy
  bool _speakerAec = false; // what the engine is actually running
  // Level updates arrive every 50 ms; only the meter listens so the rest of
  // the screen (header image filter, ten sliders) is not rebuilt each time.
  final ValueNotifier<double> _rmsLevel = ValueNotifier(0.0); // 0.0~1.0 선형
  AudioOutput _output = AudioOutput.other;
  double? _latencyMs;
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
            if ((rms - _rmsLevel.value).abs() > 0.005) _rmsLevel.value = rms;
            final recStart = _recStart;
            if (recStart != null) {
              _recSeconds.value = DateTime.now().difference(recStart).inSeconds;
            }
          } else if (type == 'record') {
            final rec = event['recording'] as bool? ?? false;
            if (!rec && _recording) {
              final reason = event['reason'] as String? ?? 'unknown';
              Analytics.recordStop(
                  reason, (event['durationMs'] as num?)?.toInt() ?? 0);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(reason == 'cap'
                    ? '최대 녹음 시간에 도달하여 녹음을 저장했습니다.'
                    : '녹음을 저장했습니다.'),
                duration: const Duration(seconds: 3),
              ));
            }
            if (rec && !_recording) _recStart = DateTime.now();
            if (!rec) _recStart = null;
            _recSeconds.value = 0;
            setState(() => _recording = rec);
          } else if (type == 'route') {
            _applyRoute(RouteInfo.fromMap(event));
            _refreshRouteAfterSwitch();
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
                _status = _runningStatus();
                _hint = null;
              });
              _refreshRoute();
            } else if (!running && _running) {
              _engine.stop(); // make sure nothing is left capturing
              WakelockPlus.disable();
              _resetLiveState();
              final started = _sessionStart;
              Analytics.echoStop(reason ?? 'unknown',
                  started == null ? null : DateTime.now().difference(started));
              setState(() {
                _running = false;
                _sessionStart = null;
                _latencyMs = null;
                _status = byUser ? '정지됨' : '멈춤';
                _hint = byUser
                    ? null
                    : reason == 'background'
                        ? _kBackgroundHint
                        : _stoppedMessage(reason);
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
    _rmsLevel.dispose();
    _recSeconds.dispose();
    for (final t in _pendingSend.values) {
      t.cancel();
    }
    super.dispose();
  }

  String _runningStatus() {
    final ms = _latencyMs;
    final mode = _speakerAec ? '스피커 모드 · ' : '';
    return ms == null ? '$mode실행 중' : '$mode실행 중 · 지연 약 ${ms.round()}ms';
  }

  void _applyRoute(RouteInfo info) {
    if (!mounted) return;
    setState(() {
      _output = info.output;
      _latencyMs = info.latencyMs;
      _speakerAec = info.speakerAec;
      if (_running) _status = _runningStatus();
    });
  }

  Future<void> _refreshRoute() async {
    try {
      _applyRoute(await _engine.routeInfo());
    } catch (e) {
      debugPrint('routeInfo failed: $e');
    }
  }

  // Native switches speaker mode 300 ms after a route/policy change and sends
  // no event when it is done, so ask again once the reopen has settled.
  void _refreshRouteAfterSwitch() {
    if (!_running) return;
    Future.delayed(const Duration(milliseconds: 700), () {
      if (mounted && _running) _refreshRoute();
    });
  }

  // Speaker: howl risk. Bluetooth: the ear hears itself late. Wired: nothing to say.
  void _showRouteHint() {
    final text = switch (_output) {
      AudioOutput.speaker => _speakerAec
          ? '스피커 모드: 하울링을 자동으로 줄입니다. 이어폰을 쓰면 더 또렷합니다.'
          : '스피커로 쓰면 하울링이 생길 수 있습니다. 이어폰을 권장합니다.',
      AudioOutput.bluetooth => '블루투스 이어폰은 목소리가 늦게 들릴 수 있습니다. 유선 이어폰을 권장합니다.',
      _ => null,
    };
    if (text == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
    );
  }

  // Shown once, on the first launch: how to actually sing with the app.
  Future<void> _showFirstRunGuide(SharedPreferences p) async {
    if (p.getBool(_kGuideShownKey) ?? false) return;
    await p.setBool(_kGuideShownKey, true);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('이렇게 쓰세요'),
        content: const Text(
          '1. 유선 이어폰을 꽂으세요.\n'
          '2. 시작을 누르고 마이크 권한을 허용하세요.\n'
          '3. 유튜브나 멜론으로 MR을 틀고 노래하세요.\n\n'
          '다른 앱으로 넘어가도 목소리는 계속 나옵니다. '
          '스피커로 쓰면 스피커 모드가 자동으로 켜져 하울링을 줄입니다. '
          '이어폰을 쓰면 더 또렷합니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('알겠어요'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _startCount = p.getInt('startCount') ?? 0;
      _boostEnabled = p.getBool('boost') ?? _kDefaultBoost;
      _gain = (p.getDouble('gain') ?? _kDefaultGain).clamp(1.0, 4.0);
      _echoDelayMs = p.getDouble('echoDelayMs') ?? _kDefaultPreset.delayMs;
      _echoFeedback = p.getDouble('echoFeedback') ?? _kDefaultPreset.feedback;
      _reverbMix = p.getDouble('reverbMix') ?? _kDefaultPreset.reverb;
      _masterVolume = p.getDouble('masterVolume') ?? 1.0;
      _gateThresholdDb = p.getDouble('gateThresholdDb') ?? _kDefaultGateDb;
      for (int i = 0; i < 5; i++) {
        _eqGains[i] = p.getDouble('eq$i') ?? 0.0;
      }
      _freqShiftEnabled = p.getBool(_kFreqShiftKey) ?? _kDefaultFreqShift;
      _speakerAecAuto = p.getBool(_kSpeakerAecKey) ?? _kDefaultSpeakerAec;
    });
    _showFirstRunGuide(p);
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('startCount', _startCount);
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
    await p.setBool(_kFreqShiftKey, _freqShiftEnabled);
    await p.setBool(_kSpeakerAecKey, _speakerAecAuto);
  }

  // One tap sets echo length, repeats and reverb together.
  void _applyPreset(_Preset preset) {
    Analytics.presetSelect(preset.name);
    setState(() {
      _echoDelayMs = preset.delayMs;
      _echoFeedback = preset.feedback;
      _reverbMix = preset.reverb;
    });
    _engine.setEchoDelay(_echoDelayMs);
    _engine.setEchoFeedback(_echoFeedback);
    _engine.setReverbMix(_reverbMix);
    _savePrefs();
  }

  bool _isPresetActive(_Preset p) =>
      _echoDelayMs == p.delayMs && _echoFeedback == p.feedback && _reverbMix == p.reverb;

  // Puts every advanced control back where a fresh install has it.
  void _resetAdvanced() {
    setState(() {
      _boostEnabled = _kDefaultBoost;
      _gain = _kDefaultGain;
      _gateThresholdDb = _kDefaultGateDb;
      for (int i = 0; i < _eqGains.length; i++) {
        _eqGains[i] = 0.0;
      }
      _freqShiftEnabled = _kDefaultFreqShift;
      _speakerAecAuto = _kDefaultSpeakerAec;
    });
    _engine.setBoost(_boostEnabled);
    _engine.setGain(_gain);
    _engine.setGateThreshold(_gateThresholdDb);
    for (int i = 0; i < _eqGains.length; i++) {
      _engine.setEQBand(i, _eqGains[i]);
    }
    _engine.setFrequencyShift(_freqShiftEnabled);
    _engine.setSpeakerAec(_speakerAecAuto);
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

  Future<void> _toggleRecording() async {
    // The native side reports start/stop through the 'record' event; the
    // UI follows that event rather than these calls.
    try {
      if (_recording) {
        await _engine.stopRecording();
        return;
      }
      final result = await _engine.startRecording();
      if (!mounted) return;
      if (result == RecordStart.ok) {
        Analytics.recordStart();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result == RecordStart.diskFull
              ? '저장 공간이 부족하여 녹음을 시작할 수 없습니다.'
              : '녹음을 시작하지 못했습니다. 다시 시도해 주세요.'),
          duration: const Duration(seconds: 3),
        ));
      }
    } catch (e) {
      debugPrint('recording toggle failed: $e');
    }
  }

  bool get _tuneOn => _tunePressed || _tuneLatched;

  // Applies a press/latch change and tells native only on an on/off edge, so
  // pressing the pad while latched neither re-sends nor logs a second hold.
  void _setTune({bool? pressed, bool? latched}) {
    final wasOn = _tuneOn;
    setState(() {
      _tunePressed = pressed ?? _tunePressed;
      _tuneLatched = latched ?? _tuneLatched;
    });
    final on = _tuneOn;
    if (on == wasOn) return;
    _engine.setAutotuneHold(on).catchError(
        (Object e) => debugPrint('setAutotuneHold failed: $e'));
    if (on) {
      _tuneStart = DateTime.now();
    } else {
      final started = _tuneStart;
      _tuneStart = null;
      if (started != null) {
        Analytics.autotuneHold(DateTime.now().difference(started).inMilliseconds);
      }
    }
  }

  // Engine stopped (by the user or on its own): drop press/latch so the next
  // session starts dry, and zero the meter so it does not freeze on the last
  // level.
  void _resetLiveState() {
    if (_tuneOn) _setTune(pressed: false, latched: false);
    _rmsLevel.value = 0.0;
  }

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() => _busy = true);
    // Start reached the engine: a later throw is not a start failure.
    bool engineStarted = false;
    try {
      if (_running) {
        await _engine.stop();
        WakelockPlus.disable();
        _resetLiveState();
        setState(() {
          _running = false;
          _speakerAec = false;
          _latencyMs = null;
          _status = '정지됨';
          _hint = null;
        });
        final started = _sessionStart;
        _sessionStart = null;
        Analytics.echoStop(
            'user', started == null ? null : DateTime.now().difference(started));
        if (started != null) {
          StopInterstitial.maybeShow(DateTime.now().difference(started));
        }
      } else {
        final PermissionStatus mic = await Permission.microphone.request();
        if (!mic.isGranted) {
          Analytics.startFailed(
              mic.isPermanentlyDenied ? 'permission_permanent' : 'permission_denied');
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

        // Headset advice for the first few sessions only: after that it is
        // noise at the moment the user wants to sing.
        if (mounted && _startCount < _kHeadsetHintSessions) {
          _startCount++;
          _savePrefs();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(_kSpeakerHint),
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
        await _engine.setSpeakerAec(_speakerAecAuto);

        final bool ok = await _engine.start();
        engineStarted = ok;
        if (ok) {
          WakelockPlus.enable();
          _sessionStart = DateTime.now();
          await _refreshRoute();
          Analytics.echoStart(_output, _latencyMs, _speakerAec);
          _showRouteHint();
        } else {
          Analytics.startFailed('engine');
        }
        setState(() {
          _running = ok;
          _status = ok ? _runningStatus() : '시작 못 함';
          _hint = ok ? null : _kStartFailed;
        });
      }
    } catch (e) {
      debugPrint('toggle failed: $e');
      if (!_running && !engineStarted) {
        Analytics.startFailed(
            e is PlatformException && e.code == 'background' ? 'background' : 'error');
      }
      if (e is PlatformException && e.code == 'background') {
        setState(() {
          _status = '시작 못 함';
          _hint = _kBackgroundHint;
        });
        return;
      }
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
    final TextTheme tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('에코마이크'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.library_music),
            tooltip: '녹음 목록',
            onPressed: _running
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => const RecordingsScreen(),
                    )),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // App Review 2.5.14: a clear, always-on indicator while the mic is live.
            // It cannot be turned off and stays visible for the whole session.
            if (_running) _MicLiveBanner(recording: _recording),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _StageHeader(
                        running: _running, status: _status, level: _rmsLevel),
                    if (_hint != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                        child: Text(
                          _hint!,
                          textAlign: TextAlign.center,
                          style: tt.bodyMedium?.copyWith(color: cs.error),
                        ),
                      ),
                    Card(
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text('효과', style: tt.titleMedium),
                            const SizedBox(height: 10),
                            // Presets as a single-select row; the active one stays
                            // lit until a slider below moves off it.
                            // Wrap, not a side-scroll: a chip cut at the edge
                            // read as broken on 360 dp phones.
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final preset in _kPresets)
                                  ChoiceChip(
                                    showCheckmark: false,
                                    visualDensity: VisualDensity.compact,
                                    padding:
                                        const EdgeInsets.symmetric(horizontal: 6),
                                    labelPadding:
                                        const EdgeInsets.only(left: 2, right: 4),
                                    label: Text(preset.name),
                                    selected: _isPresetActive(preset),
                                    onSelected: (_) => _applyPreset(preset),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            _SliderTile(
                              label: '에코 길이',
                              value: _echoDelayMs,
                              min: 0.0,
                              max: 500.0,
                              valueLabel: '${_echoDelayMs.round()} ms',
                              onChanged: (v) {
                                setState(() => _echoDelayMs = v);
                                _sendParam(
                                    'echoDelay', () => _engine.setEchoDelay(v));
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
                                _sendParam('echoFeedback',
                                    () => _engine.setEchoFeedback(v));
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
                                _sendParam(
                                    'reverb', () => _engine.setReverbMix(v));
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
                                _sendParam(
                                    'master', () => _engine.setMasterVolume(v));
                              },
                              onChangeEnd: (_) => _savePrefs(),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Fine-tuning most singers never need; kept out of the first screen.
                    Card(
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      clipBehavior: Clip.antiAlias,
                      child: ExpansionTile(
                        leading: const Icon(Icons.tune),
                        title: const Text('고급 설정'),
                        shape: const Border(),
                        collapsedShape: const Border(),
                        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                        childrenPadding:
                            const EdgeInsets.fromLTRB(16, 0, 16, 8),
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
                            max:
                                4.0, // native caps gain at 4x (8x clipped through the limiter)
                            valueLabel: _boostEnabled
                                ? '${_gain.toStringAsFixed(1)}배'
                                : '1.0배',
                            // Native pins gain to 1.0 while boost is off.
                            onChanged: _boostEnabled
                                ? (v) {
                                    setState(() => _gain = v);
                                    _sendParam(
                                        'gain', () => _engine.setGain(v));
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
                              _sendParam(
                                  'gate', () => _engine.setGateThreshold(v));
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
                                _sendParam('eq$band',
                                    () => _engine.setEQBand(band, v));
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
                          SwitchListTile(
                            title: const Text('스피커 모드 자동'),
                            subtitle: Text(_speakerAecAuto
                                ? '스피커로 쓰면 에코 제거를 자동으로 켭니다'
                                : '항상 끕니다 (하울링 주의)'),
                            value: _speakerAecAuto,
                            onChanged: (v) {
                              setState(() => _speakerAecAuto = v);
                              _engine.setSpeakerAec(v);
                              _savePrefs();
                              _refreshRouteAfterSwitch();
                            },
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: _resetAdvanced,
                              icon: const Icon(Icons.restart_alt),
                              label: const Text('기본값으로 되돌리기'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _ControlDeck(
              running: _running,
              busy: _busy,
              recording: _recording,
              recSeconds: _recSeconds,
              tuneOn: _tuneOn,
              tuneLatched: _tuneLatched,
              onToggle: _toggle,
              onRecord: _toggleRecording,
              onTunePressed: (down) => _setTune(pressed: down),
              onTuneLatchChanged: (on) => _setTune(latched: on),
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
    final tt = Theme.of(context).textTheme;
    final enabled = onChanged != null;
    // ~64dp: label/value row, then the slider with trimmed vertical padding.
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: tt.bodyMedium)),
              Text(
                valueLabel,
                style: tt.labelLarge?.copyWith(
                  color: enabled ? kNeonA : Theme.of(context).disabledColor,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          // TalkBack otherwise reads a bare "slider, 35%" with no name.
          Semantics(
            label: label,
            value: valueLabel,
            child: SizedBox(
              height: 36,
              child: Slider(
                value: value,
                min: min,
                max: max,
                padding: const EdgeInsets.symmetric(horizontal: 9),
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fixed bottom deck: record (left), start/stop (center), auto-tune pad (right).
class _ControlDeck extends StatelessWidget {
  const _ControlDeck({
    required this.running,
    required this.busy,
    required this.recording,
    required this.recSeconds,
    required this.tuneOn,
    required this.tuneLatched,
    required this.onToggle,
    required this.onRecord,
    required this.onTunePressed,
    required this.onTuneLatchChanged,
  });

  final bool running;
  final bool busy;
  final bool recording;
  final ValueListenable<int> recSeconds;
  final bool tuneOn;
  final bool tuneLatched;
  final VoidCallback onToggle;
  final VoidCallback onRecord;
  final ValueChanged<bool> onTunePressed;
  final ValueChanged<bool> onTuneLatchChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final muted = cs.onSurfaceVariant.withValues(alpha: 0.7);
    // Every control sits in an 84dp slot so the captions line up.
    Widget column(Widget control, Widget caption, String? sub) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: 84, child: Center(child: control)),
            const SizedBox(height: 6),
            caption,
            if (sub != null)
              ExcludeSemantics(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(sub, style: tt.bodySmall?.copyWith(color: muted)),
                ),
              ),
          ],
        );
    Widget label(String text, {bool enabled = true}) => FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: enabled ? cs.onSurface : muted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        );

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        // Flutter only paints a radius with a uniform border; the bottom edge
        // is hidden by the divider below anyway.
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: column(
              _RecordButton(
                enabled: running,
                recording: recording,
                onPressed: onRecord,
              ),
              recording
                  ? ValueListenableBuilder<int>(
                      valueListenable: recSeconds,
                      builder: (_, sec, __) =>
                          label('${(sec ~/ 60).toString().padLeft(2, '0')}:'
                              '${(sec % 60).toString().padLeft(2, '0')}'),
                    )
                  : ExcludeSemantics(child: label('녹음', enabled: running)),
              running ? null : '시작 후 가능',
            ),
          ),
          Expanded(
            child: column(
              _StartButton(running: running, busy: busy, onPressed: onToggle),
              ExcludeSemantics(child: label(running ? '정지' : '시작')),
              null,
            ),
          ),
          Expanded(
            child: column(
              _TunePad(
                enabled: running,
                active: tuneOn,
                latched: tuneLatched,
                onPressed: onTunePressed,
                onLatchChanged: onTuneLatchChanged,
              ),
              ExcludeSemantics(child: label('오토튠', enabled: running)),
              tuneLatched ? '고정됨' : '누르는 동안',
            ),
          ),
        ],
      ),
    );
  }
}

/// 60dp record circle. Muted while the engine is off; filled and pulsing
/// while recording.
class _RecordButton extends StatefulWidget {
  const _RecordButton({
    required this.enabled,
    required this.recording,
    required this.onPressed,
  });

  final bool enabled;
  final bool recording;
  final VoidCallback onPressed;

  @override
  State<_RecordButton> createState() => _RecordButtonState();
}

class _RecordButtonState extends State<_RecordButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  @override
  void initState() {
    super.initState();
    if (widget.recording) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_RecordButton old) {
    super.didUpdateWidget(old);
    if (widget.recording && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!widget.recording && _pulse.isAnimating) {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final recording = widget.recording;
    final dim = !enabled;
    final Widget icon = recording
        ? const Icon(Icons.stop_rounded, color: Colors.white, size: 30)
        : Icon(Icons.fiber_manual_record,
            color: dim ? kRec.withValues(alpha: 0.5) : kRec, size: 26);
    return Semantics(
      button: true,
      enabled: enabled,
      label: recording ? '녹음 정지' : '녹음',
      hint: enabled ? null : '시작한 뒤 녹음할 수 있습니다',
      excludeSemantics: true,
      onTap: enabled ? widget.onPressed : null,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) => Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: recording
                ? [
                    BoxShadow(
                      color: kRec.withValues(alpha: 0.25 + 0.35 * _pulse.value),
                      blurRadius: 8 + 10 * _pulse.value,
                    ),
                  ]
                : null,
          ),
          child: child,
        ),
        child: Material(
          color: recording ? kRec : Colors.transparent,
          shape: CircleBorder(
            side: BorderSide(
              color: dim ? kRec.withValues(alpha: 0.35) : kRec,
              width: 2,
            ),
          ),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: enabled ? widget.onPressed : null,
            child: Center(child: icon),
          ),
        ),
      ),
    );
  }
}

/// 84dp start/stop circle: neon gradient when stopped, error red when running.
class _StartButton extends StatelessWidget {
  const _StartButton({
    required this.running,
    required this.busy,
    required this.onPressed,
  });

  final bool running;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      enabled: !busy,
      label: running ? '정지' : '시작',
      excludeSemantics: true,
      onTap: busy ? null : onPressed,
      child: Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          // Running: dark disc with a neon ring, so it does not read as a
          // second red record button next to it.
          color: running ? cs.surfaceContainerHighest : null,
          border: running ? Border.all(color: kNeonB, width: 2) : null,
          gradient: running
              ? null
              : const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [kNeonA, kNeonB],
                ),
          boxShadow: [
            BoxShadow(
                color: kNeonB.withValues(alpha: running ? 0.3 : 0.45),
                blurRadius: 18),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: busy ? null : onPressed,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  running ? Icons.stop_rounded : Icons.play_arrow_rounded,
                  color: Colors.white.withValues(alpha: busy ? 0.5 : 1),
                  size: 40,
                ),
                if (busy)
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Press-and-hold auto-tune DJ pad. Lit while held or latched; the lock badge
/// keeps it on hands-free (and is the screen-reader path, since a long press
/// is awkward there).
class _TunePad extends StatelessWidget {
  const _TunePad({
    required this.enabled,
    required this.active,
    required this.latched,
    required this.onPressed,
    required this.onLatchChanged,
  });

  final bool enabled;
  final bool active;
  final bool latched;
  final ValueChanged<bool> onPressed;
  final ValueChanged<bool> onLatchChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final lit = enabled && active;
    final iconColor = lit
        ? kStageBg
        : enabled
            ? kTune
            : kTune.withValues(alpha: 0.5);
    final latchTip = latched ? '오토튠 고정 해제' : '오토튠 고정';
    // 92x84 box: the pad is centred and the badge's 32dp hit area stays
    // inside the Stack (hits outside a Stack's bounds are dropped).
    return SizedBox(
      width: 92,
      height: 84,
      child: Stack(
        children: [
          Positioned(
            left: 16,
            top: 16,
            width: 60,
            height: 60,
            child: Semantics(
              button: true,
              enabled: enabled,
              toggled: lit,
              label: '오토튠',
              hint: '누르고 있는 동안 음정이 보정됩니다',
              excludeSemantics: true,
              child: Listener(
                onPointerDown: enabled ? (_) => onPressed(true) : null,
                onPointerUp: (_) => onPressed(false),
                onPointerCancel: (_) => onPressed(false),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 80),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: lit ? kTune : Colors.transparent,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: enabled ? kTune : kTune.withValues(alpha: 0.35),
                      width: 2,
                    ),
                    boxShadow: lit
                        ? [
                            BoxShadow(
                              color: kTune.withValues(alpha: 0.6),
                              blurRadius: 20,
                            ),
                          ]
                        : null,
                  ),
                  child: Icon(Icons.graphic_eq, color: iconColor, size: 30),
                ),
              ),
            ),
          ),
          Positioned(
            left: 60,
            top: 0,
            width: 32,
            height: 32,
            child: Tooltip(
              message: latchTip,
              child: Semantics(
                button: true,
                enabled: enabled,
                toggled: latched,
                label: latchTip,
                excludeSemantics: true,
                onTap: enabled ? () => onLatchChanged(!latched) : null,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: enabled ? () => onLatchChanged(!latched) : null,
                  child: Center(
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: latched && enabled
                            ? kTune
                            : cs.surfaceContainerHighest,
                        border: Border.all(
                          color:
                              enabled ? kTune : kTune.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Icon(
                        latched ? Icons.lock : Icons.lock_open,
                        size: 13,
                        color: latched && enabled
                            ? kStageBg
                            : enabled
                                ? kTune
                                : kTune.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Input level bar inside the stage header: neon gradient with a soft glow.
class _LevelMeter extends StatelessWidget {
  const _LevelMeter({required this.level});
  final ValueListenable<double> level; // 0.0~1.0 선형 RMS

  @override
  Widget build(BuildContext context) {
    final track = Colors.white.withValues(alpha: 0.12);
    return ValueListenableBuilder<double>(
      valueListenable: level,
      builder: (context, level, _) {
        // dBFS 변환 (-60~0), 0이면 -60
        final db =
            level > 0 ? (20 * (log(level) / log(10))).clamp(-60.0, 0.0) : -60.0;
        final fraction = ((db + 60) / 60).clamp(0.0, 1.0); // 0~1
        return Semantics(
          label: '입력 소리',
          value: '${(fraction * 100).round()}%',
          child: Container(
            height: 6,
            decoration: BoxDecoration(
              color: track,
              borderRadius: BorderRadius.circular(3),
            ),
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: fraction,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  gradient: const LinearGradient(colors: [kNeonA, kNeonB]),
                  boxShadow: level > 0
                      ? [
                          BoxShadow(
                            color: kNeonB.withValues(alpha: 0.4),
                            blurRadius: 12,
                          ),
                        ]
                      : null,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Stage photo behind the status line. Grey and dim while idle, full colour
/// once the mic is live, so the state reads at a glance from across the room.
class _StageHeader extends StatelessWidget {
  const _StageHeader({
    required this.running,
    required this.status,
    required this.level,
  });

  final bool running;
  final String status;
  final ValueListenable<double> level;

  // Saturation s and brightness b as a colour matrix (luma weights Rec. 709).
  static List<double> _grade(double s, double b) {
    const r = 0.2126, g = 0.7152, bl = 0.0722;
    final i = 1 - s;
    return [
      b * (i * r + s),
      b * i * g,
      b * i * bl,
      0,
      0,
      b * i * r,
      b * (i * g + s),
      b * i * bl,
      0,
      0,
      b * i * r,
      b * i * g,
      b * (i * bl + s),
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    // 150dp keeps the effect sliders above the fold on a 412x915dp phone.
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
          if (running) const _StageGlow(),
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  status,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: _LevelMeter(level: level),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Soft neon ring pulsing behind the mic while live. Only exists while
/// running, so no ticker runs when idle.
class _StageGlow extends StatefulWidget {
  const _StageGlow();

  @override
  State<_StageGlow> createState() => _StageGlowState();
}

class _StageGlowState extends State<_StageGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: FadeTransition(
        opacity: Tween<double>(begin: 0.15, end: 0.45).animate(_pulse),
        child: const DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.2),
              radius: 0.6,
              colors: [Color(0x00000000), Color(0x669B5CFF), Color(0x00000000)],
              stops: [0.35, 0.6, 1],
            ),
          ),
        ),
      ),
    );
  }
}

/// Red "mic on" bar shown for the whole time the microphone is capturing
/// (App Store guideline 2.5.14 — recording must be clearly indicated).
class _MicLiveBanner extends StatefulWidget {
  const _MicLiveBanner({required this.recording});

  final bool recording;

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
              child: const Icon(Icons.fiber_manual_record,
                  color: Colors.white, size: 18),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.mic, color: Colors.white, size: 20),
            const SizedBox(width: 6),
            // Wraps instead of truncating: whether the voice is being saved
            // must stay visible on narrow phones.
            Flexible(
              child: Text.rich(
                TextSpan(children: [
                  const TextSpan(
                    text: '마이크 사용 중\n',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(
                      text: widget.recording
                          ? '녹음 중입니다. 녹음은 이 기기에만 저장됩니다.'
                          : '녹음 버튼을 누를 때만 저장합니다.'),
                ]),
                style: const TextStyle(
                    color: Colors.white, fontSize: 13, height: 1.3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
