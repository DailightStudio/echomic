import Flutter
import Foundation

/// Bridges the Dart MethodChannel to the native AVAudioEngine-based engine.
final class AudioEnginePlugin: NSObject {

    private static let channelName = "com.dailightstudio.echomic/audio"
    private static let eventChannelName = "com.dailightstudio.echomic/events"

    private let engine = AudioEngine()

    private var eventSink: FlutterEventSink?
    private var pollingTimer: Timer?
    private var expectedRunning = false

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: channelName,
                                           binaryMessenger: messenger)
        let eventChannel = FlutterEventChannel(name: eventChannelName,
                                               binaryMessenger: messenger)
        let instance = AudioEnginePlugin()
        channel.setMethodCallHandler { call, result in
            instance.handle(call, result: result)
        }
        eventChannel.setStreamHandler(instance)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            let ok = engine.start()
            expectedRunning = ok
            result(ok)
        case "stop":
            engine.stop()
            expectedRunning = false
            result(nil)
        case "setGain":
            if let gain = doubleArg(call, "gain") {
                engine.setGain(Float(gain))
            }
            result(nil)
        case "setEchoDelay":
            if let delayMs = doubleArg(call, "delayMs") {
                engine.setEchoDelay(Float(delayMs))
            }
            result(nil)
        case "setEchoFeedback":
            if let feedback = doubleArg(call, "feedback") {
                engine.setEchoFeedback(Float(feedback))
            }
            result(nil)
        case "setReverbMix":
            if let mix = doubleArg(call, "mix") {
                engine.setReverbMix(Float(mix))
            }
            result(nil)
        case "setMasterVolume":
            if let volume = doubleArg(call, "volume") {
                engine.setMasterVolume(Float(volume))
            }
            result(nil)
        case "setGateThreshold":
            if let db = doubleArg(call, "db") {
                engine.setGateThreshold(Float(db))
            }
            result(nil)
        case "setEQBand":
            if let band = (call.arguments as? [String: Any])?["band"] as? Int,
               let gainDb = doubleArg(call, "gainDb") {
                engine.setEQBand(band, gainDb: Float(gainDb))
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func doubleArg(_ call: FlutterMethodCall, _ key: String) -> Double? {
        guard let args = call.arguments as? [String: Any] else { return nil }
        return args[key] as? Double
    }

    // MARK: - Level / state polling

    private func startPolling() {
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let sink = self.eventSink else { return }
            let running = self.engine.isRunning
            // 상태 변화 감지: 시작을 기대했으나 엔진이 멈춘 경우
            if self.expectedRunning && !running {
                sink(["type": "state", "running": false])
                self.expectedRunning = false
            }
            // 레벨 이벤트 (Float -> Double: StandardMessageCodec 는 Double 만 직렬화)
            if running {
                sink(["type": "level", "rms": Double(self.engine.currentRMSLevel)])
            }
        }
    }

    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }
}

// MARK: - FlutterStreamHandler

extension AudioEnginePlugin: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?,
                  eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        startPolling()
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        stopPolling()
        self.eventSink = nil
        return nil
    }
}
