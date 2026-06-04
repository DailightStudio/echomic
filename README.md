# echomic

Low-latency karaoke microphone app: phone mic -> real-time gain + echo -> phone speaker. iOS (AVAudioEngine) and Android (Oboe/AAudio LowLatency).

## Build

```bash
flutter pub get

# Android (minSdk 23, builds the native Oboe engine via CMake)
flutter run -d android

# iOS (open ios/Runner.xcworkspace in Xcode for first signing, then)
cd ios && pod install && cd ..
flutter run -d ios
```

> Use earbuds/headphones to avoid acoustic feedback (mic -> speaker -> mic) when testing.

## Architecture

- `lib/` — Flutter UI shell + `MethodChannel` wrapper (`com.dailightstudio.echomic/audio`).
- `android/app/src/main/cpp/` — Oboe AAudio engine (Float, LowLatency, Exclusive) with a circular-buffer echo.
- `ios/Runner/` — `AVAudioEngine` + `AVAudioSession` (playAndRecord, 5 ms IO buffer) with the same circular-buffer echo.

### Echo algorithm (shared design)

```
delayed   = circularBuffer.read(delaySamples)
out       = in * gain + delayed * feedback
circularBuffer.write(out)
```
