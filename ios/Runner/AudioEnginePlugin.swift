import Flutter
import Foundation

/// Bridges the Dart MethodChannel to the native AVAudioEngine-based engine.
final class AudioEnginePlugin: NSObject {

    private static let channelName = "com.dailightstudio.echomic/audio"

    private let engine = AudioEngine()

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: channelName,
                                           binaryMessenger: messenger)
        let instance = AudioEnginePlugin()
        channel.setMethodCallHandler { call, result in
            instance.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            result(engine.start())
        case "stop":
            engine.stop()
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
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func doubleArg(_ call: FlutterMethodCall, _ key: String) -> Double? {
        guard let args = call.arguments as? [String: Any] else { return nil }
        return args[key] as? Double
    }
}
