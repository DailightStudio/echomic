# Speaker mode (platform AEC on the built-in speaker) — implementation plan

Repo: C:\Users\Jay-server\Desktop\projects\echomic (1.0.3+11). All anchors below were read on 2026-10-24.
Build/verify commands (every step): `PATH=/c/dev/flutter/bin:$PATH flutter analyze` and
`PATH=/c/dev/flutter/bin:$PATH flutter build apk --release --target-platform android-x64`; emulator smoke = install, Start, watch logcat tag `EchomicEngine`.
iOS compiles only on CI (`.github/workflows/build.yml` job `ios`, `flutter build ios --release --no-codesign`).

## Design (decisions, with reasons)

Mode = `raw` (today's path) | `speaker_aec`. Desired mode = `(policy == auto) && routeIsBuiltInSpeaker`.
Policy (`auto` | `off`) is a SharedPreferences value owned by Dart, pushed to native via a new method `setSpeakerAec(enabled)` before start and whenever the switch changes. Native owns route detection and the mode switch so a mid-session plug/unplug never round-trips through Dart.

Android `speaker_aec`: input `InputPreset::VoiceCommunication` (AAUDIO_INPUT_PRESET_VOICE_COMMUNICATION, Oboe Definitions.h:444 — this is the input source the audio policy attaches the platform AEC preprocessing to). Output stays `Usage::Game`/`ContentType::Music` — the existing comment at audio_engine.cpp:76-85 documents exactly why `Usage::VoiceCommunication` is wrong here (earpiece routing, call-volume stream, ducking other apps' MR). For the same reason do NOT set `MODE_IN_COMMUNICATION` or `setCommunicationDevice` — with the output on the media path there is no earpiece problem to fix, and `MODE_IN_COMMUNICATION` would attenuate YouTube/Melon MR. Platform AEC reference on Android is taken by the HAL from the device output mix, not per-stream (vendor dependent — REAL-DEVICE RISK #1). `android.media.audiofx.AcousticEchoCanceler` on a `SessionId::Allocate` input is kept as a contingency (Step 6) because `setSessionId` is API 28+ (AudioStreamBuilder.h:316) and allocating a session id typically costs the MMAP/low-latency path.

iOS `speaker_aec`: `engine.inputNode.setVoiceProcessingEnabled(true)` before the input format is read (it changes the format), `isVoiceProcessingAGCEnabled = false` (our compressor does gain), on iOS 17+ `voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: true, duckingLevel: .min)` so MR from another app is not ducked. iOS 16 (deployment target 16.0): enable anyway — ducked MR beats howl. Session stays `.playAndRecord` + `.mixWithOthers` + `.defaultToSpeaker` (AudioEngine.swift:510-511). API names above are from Apple docs as remembered, not compile-verified locally — CI compile is the check (RISK #2).

Our echo/reverb under AEC: AEC models mic = h * output; our output (dry + echo tail + shifter) is the far-end reference, so the acoustic return of our tail is cancelled — desired. The dry voice is near-end and should pass, but two effects need a real device (RISK #3): (a) AEC adaptation only converges during gaps because near-end is almost always active; (b) the residual-echo suppressor (NLP) may attenuate the voice while the reference is loud ("half-duplex" pumping on sustained notes). Mitigation already in the plan: output gain caps (the AEC cannot cancel clipped output), shifter + suppressor stay on, and the user override `off`.

Gain caps in `speaker_aec` (both platforms): input gain capped to 2.0x (vs 4.0) and master multiplied by 0.7 after the user's master. Applied in the DSP hot path from an atomic/plain bool, no reconfigure needed.

### State machine (native, per platform)
```
Idle --start(policy)------------------------> Running(mode = desired())
Running(m) --route event, desired()==m-------> Running(m)              (no-op)
Running(m) --route event, desired()!=m-------> Switching --ok--> Running(desired)
                                                        --fail--> Stopped(reason "engine")
Running(raw) --unplug, policy off------------> Stopped(reason "unplug")   (today's behaviour)
Running(raw) --unplug, policy auto-----------> Switching -> Running(speaker_aec)
Running(any) --stop--------------------------> Idle
```
Android `Switching` = detached thread, 300 ms debounce (reuse `kRestartDebounce`), under `lifecycleLock_`, `closeStreams()` then `openStreams()`; `running_` stays true throughout (same contract as the ErrorDisconnected restart at audio_engine.cpp:293-345). `openStreams()` reads the desired-mode atomic, so whichever of the disconnect-restart / mode-switch threads wins reopens correctly; the loser sees `desired == active` and returns. iOS `Switching` = `internalStop(keepObservers: true)` + `start()` on the main queue, exactly the existing `.newDeviceAvailable` path (AudioEngine.swift:593-598).

## Steps

### Step 1 — Android native: mode flag, VoiceCommunication input, caps, switch thread
Files: `android/app/src/main/cpp/audio_engine.h`, `audio_engine.cpp`, `jni_bridge.cpp`.
1. `audio_engine.h`: after `void setFrequencyShiftEnabled(bool en) { ... }` (line 57) add
   `void setSpeakerAecDesired(bool on);` and `bool isSpeakerAecActive() const { return speakerAecActive_.load(); }`.
   Near `std::atomic<bool> boost_{true};` (line 120) add `std::atomic<bool> speakerAecDesired_{false}; std::atomic<bool> speakerAecActive_{false};` and a private `void scheduleModeSwitch();`.
   Next to `static constexpr float kMaxGain = 4.0f;` (line 145) add `kSpeakerMaxGain = 2.0f; kSpeakerMasterCap = 0.7f;`.
2. `audio_engine.cpp` `openStreams()` (line 69): read `const bool aec = speakerAecDesired_.load();` at the top. Change line 111
   `->setInputPreset(oboe::InputPreset::VoicePerformance)` to
   `->setInputPreset(aec ? oboe::InputPreset::VoiceCommunication : oboe::InputPreset::VoicePerformance)`.
   Leave lines 87-88 (`setUsage(Game)`, `setContentType(Music)`) unchanged; extend the comment at 76-85 with one sentence: output stays on the media path even in speaker mode, only the input preset changes.
   After the `LOGI("Streams started: ...` at line 181 set `speakerAecActive_.store(aec);` and include `aec=%d` in the log.
3. `runDsp()` caps: line 239 `echo_.process(buf, numFrames, boost ? gain_.load() : 1.0f);` becomes
   `const bool aec = speakerAecActive_.load(); float g = boost ? gain_.load() : 1.0f; if (aec) g = std::min(g, kSpeakerMaxGain); echo_.process(buf, numFrames, g);`
   Line 246 `const float master = masterGain_.load();` becomes `float master = masterGain_.load(); if (aec) master *= kSpeakerMasterCap;`.
4. New `setSpeakerAecDesired(bool on)`: `speakerAecDesired_.store(on); if (running_.load() && on != speakerAecActive_.load()) scheduleModeSwitch();`
   `scheduleModeSwitch()`: copy the body shape of `handleInputReadFailure()` (lines 348-380): detached thread, `sleep_for(kRestartDebounce)`, `lock_guard(lifecycleLock_)`, `if (!running_) return; if (speakerAecDesired_ == speakerAecActive_) return;` then `generation_++`, `closeStreams(); if (!openStreams()) { closeStreams(); running_.store(false); } else generation_++;`. Guard re-entry with a `std::atomic<bool> modeSwitchPending_` the same way `inputFailurePending_` is used (header line 143).
   Do not touch `start()`/`stop()` (lines 46-67); `start()` already calls `openStreams()` which now honours the flag.
5. `jni_bridge.cpp`: before `}  // extern "C"` (line 133) add
   `Java_com_dailightstudio_echomic_AudioEnginePlugin_nativeSetSpeakerAec(JNIEnv*, jobject, jboolean on)` -> `gEngine->setSpeakerAecDesired(on == JNI_TRUE)` and
   `..._nativeIsSpeakerAecActive(JNIEnv*, jobject) -> jboolean`.
Verify: apk build (x64) compiles; logcat on emulator shows `aec=0` with today's behaviour (Kotlin not yet calling the new JNI). Reviewer: lock order unchanged (only `lifecycleLock_`), no lock taken on the audio thread.

### Step 2 — Android Kotlin: policy, speaker detection, live switching, unplug behaviour
File: `android/app/src/main/kotlin/com/dailightstudio/echomic/AudioEnginePlugin.kt`.
1. Field `private var speakerAecPolicyAuto = true` (next to `stopReason`, line 46). Externals at line 307: add `private external fun nativeSetSpeakerAec(on: Boolean)` and `private external fun nativeIsSpeakerAecActive(): Boolean`.
2. `routeInfo()` (lines 239-260): extract the device loop into `private fun outputKind(): String` (returns "speaker"|"wired"|"bluetooth"); `routeInfo()` adds `info["mode"] = if (nativeIsSpeakerAecActive()) "speaker_aec" else "raw"`. Emulator note: `getDevices(OUTPUT)` on the x86_64 emulator reports only the built-in speaker, so `outputKind()=="speaker"` and AEC mode will be requested — expected.
3. `private fun applyDesiredMode() = nativeSetSpeakerAec(speakerAecPolicyAuto && outputKind() == "speaker")`.
   Call it (a) in `"start" ->` before `val ok = nativeStart()` (line 89); (b) in `pushRoute()` (line 268) before the event is built; (c) in a new method case `"setSpeakerAec" -> { speakerAecPolicyAuto = call.argument<Boolean>("enabled") ?: true; applyDesiredMode(); result.success(null) }` placed after the `"setFrequencyShift"` case (lines 152-156).
4. Noisy receiver (line 216-230): replace `endSession(reason = "unplug")` at line 220 with
   `if (speakerAecPolicyAuto) nativeSetSpeakerAec(true) else endSession(reason = "unplug")`.
   The native ErrorDisconnected restart (audio_engine.cpp:293-345) will also fire for the unplugged stream; both paths reopen with `speakerAecDesired_ == true` (see state machine).
Verify: analyze + x64 apk; emulator: Start -> logcat `aec=1`; `adb shell cmd media.audio_policy`-free check: call `routeInfo` via the UI (Step 4) later. A failed VoiceCommunication open on the emulator would surface as `Failed to open input stream` — if so, fall back is Step 6.

### Step 3 — iOS: voice processing in speaker mode, caps, live switching
Files: `ios/Runner/AudioEngine.swift`, `ios/Runner/AudioEnginePlugin.swift`.
1. `AudioEngine.swift` state (near `private var isReconfiguring = false`, line 201): `var speakerAecPolicyAuto = true`, `private(set) var speakerAecActive = false`.
   Add `private func routeIsBuiltInSpeaker() -> Bool` = `currentRoute.outputs.contains { $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver }` (same port set `routeInfo()` maps to "speaker", line 404) and `private func desiredSpeakerAec() -> Bool { speakerAecPolicyAuto && routeIsBuiltInSpeaker() }`.
2. `start()` (line 267): after `try configureSession()` (line 272) and before `let inputFormat = engine.inputNode.outputFormat(forBus: 0)` (line 279) insert:
   ```swift
   let aec = desiredSpeakerAec()
   if engine.inputNode.isVoiceProcessingEnabled != aec { try engine.inputNode.setVoiceProcessingEnabled(aec) }
   if aec {
       engine.inputNode.isVoiceProcessingAGCEnabled = false
       if #available(iOS 17.0, *) {
           engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
               AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: true, duckingLevel: .min)
       }
   }
   speakerAecActive = aec
   ```
   `setVoiceProcessingEnabled` throws and must run while the engine is stopped — true at this point. The format guard at 285-287 already covers a 0 Hz format after the toggle.
3. `renderSource()` caps: line 676 `echo.process(scratch, frameCount: count, gain: boostEnabled ? gain : 1)` -> `gain: min(boostEnabled ? gain : 1, speakerAecActive ? 2.0 : 4.0)`; line 682 `let vol = masterVolume` -> `let vol = masterVolume * (speakerAecActive ? 0.7 : 1.0)`.
4. Route observer: `.oldDeviceUnavailable` (lines 569-580): keep the stop when `!speakerAecPolicyAuto`; otherwise do the live reconfigure (`isReconfiguring = true; internalStop(keepObservers: true); _ = start(); isReconfiguring = false`, as 593-598). `.newDeviceAvailable` guard (lines 590-592): extend the condition with `|| self.speakerAecActive != self.desiredSpeakerAec()` so plugging in headphones switches back to raw even when the format is unchanged.
   Add `func setSpeakerAec(_ auto: Bool)`: set the policy; if `isRunning && speakerAecActive != desiredSpeakerAec()` run the same reconfigure block on `DispatchQueue.main.async`.
5. `routeInfo()` (line 411): `info["mode"] = speakerAecActive ? "speaker_aec" : "raw"`.
6. `AudioEnginePlugin.swift`: after `case "setFrequencyShift"` (lines 86-90) add `case "setSpeakerAec": if let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool { engine.setSpeakerAec(enabled) }; result(nil)`.
Verify: no local compiler — `git push` triggers the CI `ios` job; a compile error there means an API name above is wrong (check Apple docs for `AVAudioInputNode`). Reviewer: confirm `setVoiceProcessingEnabled` is never called while `engine.isRunning`.

### Step 4 — Dart: channel API, prefs, UI, analytics
Files: `lib/audio_engine.dart`, `lib/analytics.dart`, `lib/home_screen.dart`.
1. `audio_engine.dart`: after `setFrequencyShift` (lines 95-97) add `Future<void> setSpeakerAec(bool enabled)` invoking `'setSpeakerAec', {'enabled': enabled}`. `RouteInfo` (103-121): add `final bool speakerAec;` parsed from `raw['mode'] == 'speaker_aec'` (default false).
2. `analytics.dart` line 36-39: `echoStart(AudioOutput output, double? latencyMs, bool speakerAec)` adds `'mode': speakerAec ? 'speaker_aec' : 'raw'`. Update the call at `home_screen.dart:417` to pass `_speakerAec`.
3. `home_screen.dart`:
   - Constants near `_kFreqShiftKey` (line 44): `const String _kSpeakerAecKey = 'speakerAec'; const bool _kDefaultSpeakerAec = true;`. State next to `_freqShiftEnabled` (97): `bool _speakerAecAuto = _kDefaultSpeakerAec; bool _speakerAec = false;`.
   - `_loadPrefs` (261) / `_savePrefs` (279) / `_resetAdvanced` (308, 316): read/write/reset `_speakerAecAuto` alongside freqShift; `_resetAdvanced` also calls `_engine.setSpeakerAec(_speakerAecAuto)`.
   - `_applyRoute` (190-197): `_speakerAec = info.speakerAec;`.
   - `_runningStatus()` (185-188): prefix `_speakerAec ? '스피커 모드 · ' : ''`.
   - `_showRouteHint()` (210): speaker text becomes `_speakerAec ? '스피커 모드: 하울링을 자동으로 줄입니다. 이어폰을 쓰면 더 또렷합니다.' : '스피커로 쓰면 하울링이 생길 수 있습니다. 이어폰을 권장합니다.'`. First-run guide line 234 and the first-3-sessions snackbar (393): reword to `'스피커로 쓰면 스피커 모드가 자동으로 켜져 하울링을 줄입니다. 이어폰을 쓰면 더 또렷합니다.'`.
   - `_toggle()` setters block (399-409): add `await _engine.setSpeakerAec(_speakerAecAuto);` after `setFrequencyShift`. `_stoppedMessage` (64-68) unchanged — "unplug" now only happens with policy off.
   - 고급 설정: after the `'하울링 억제'` SwitchListTile (614-625) add a SwitchListTile `title: '스피커 모드 자동'`, subtitle `_speakerAecAuto ? '스피커로 쓰면 에코 제거를 자동으로 켭니다' : '항상 끕니다 (하울링 주의)'`, `onChanged: (v) { setState(() => _speakerAecAuto = v); _engine.setSpeakerAec(v); _savePrefs(); }`, same `contentPadding/dense` as the switch above.
Verify: analyze clean; x64 apk; emulator: status reads `스피커 모드 · 실행 중 ...`, toggling the switch mid-session flips the status within ~0.5 s and logcat shows a close/reopen with `aec=0/1`; switch persists across restart.

### Step 5 — Real-device validation checklist (no code; owner runs, reviewer records)
Android phone + iPhone: (1) speaker: no howl at default master, voice not pumping on a held note (RISK #3); (2) plug wired mid-session: status drops `스피커 모드`, latency readout returns to today's value; unplug: engine keeps running, status gains `스피커 모드`, no howl burst > 1 s; (3) YouTube MR volume unchanged when Start is pressed (Android: proves no comm-mode ducking; iOS 17: proves `.min` ducking); (4) Android: output actually on loudspeaker not earpiece with the VoiceCommunication input preset (RISK #1b); (5) logcat `Streams started` burst size in AEC mode vs raw (latency cost of the AEC capture path). Emulator cannot answer any of these.

### Step 6 — Contingency (only if Step 5 (1) shows no cancellation on Android)
`audio_engine.cpp` input builder (line 104-118): add `->setSessionId(aec ? oboe::SessionId::Allocate : oboe::SessionId::None)` (API 28+, minSdk is 24 — guard with `__ANDROID_API__`/runtime SDK check passed from Kotlin). Expose `nativeGetInputSessionId()`; in Kotlin after a successful start and after each `route` event, `if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(id)?.enabled = true`, releasing the previous instance in `endSession()`. Accept the MMAP/latency loss in speaker mode only.
