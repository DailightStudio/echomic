import AVFoundation

/// Low-latency full-duplex engine on top of AVAudioEngine.
///
/// Routing: inputNode -> (echo applied in a tap) -> playerNode -> mainMixer ->
/// output. We tap the input node, run gain + echo on the captured PCM, and
/// immediately schedule the processed buffer on an AVAudioPlayerNode so it
/// reaches the speaker with minimal added latency.
final class AudioEngine {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let echo = EchoEffect()

    private var gain: Float = 1.0
    private var isRunning = false

    private var processingFormat: AVAudioFormat?

    // MARK: - Parameters

    func setGain(_ value: Float) { gain = value }
    func setEchoDelay(_ delayMs: Float) { echo.setDelayMs(delayMs) }
    func setEchoFeedback(_ value: Float) { echo.setFeedback(value) }

    // MARK: - Lifecycle

    func start() -> Bool {
        if isRunning { return true }
        do {
            try configureSession()

            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)

            // Use a non-interleaved float format that matches the hardware rate.
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,
                channels: inputFormat.channelCount,
                interleaved: false
            ) else {
                return false
            }
            processingFormat = format

            echo.prepare(sampleRate: Float(format.sampleRate),
                         channelCount: Int(format.channelCount))
            echo.reset()

            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)

            // Tap the mic. We do the DSP here and forward to the player node.
            let bufferSize: AVAudioFrameCount = 256  // ~5 ms @ 48 kHz
            input.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) {
                [weak self] buffer, _ in
                self?.handle(inputBuffer: buffer, targetFormat: format)
            }

            engine.prepare()
            try engine.start()
            player.play()

            isRunning = true
            return true
        } catch {
            NSLog("echomic: failed to start engine: \(error)")
            stop()
            return false
        }
    }

    func stop() {
        if engine.inputNode.numberOfInputs > 0 {
            engine.inputNode.removeTap(onBus: 0)
        }
        if player.isPlaying { player.stop() }
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(
            false, options: [.notifyOthersOnDeactivation])
        isRunning = false
    }

    // MARK: - Internals

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .measurement,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setPreferredIOBufferDuration(0.005)  // 5 ms
        try session.setPreferredSampleRate(48_000)
        try session.setActive(true)
    }

    /// Runs gain + echo over the captured buffer and schedules it for playback.
    private func handle(inputBuffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: inputBuffer.frameLength
        ) else { return }
        outBuffer.frameLength = inputBuffer.frameLength

        let frameCount = Int(inputBuffer.frameLength)
        let channels = Int(targetFormat.channelCount)

        guard let src = inputBuffer.floatChannelData,
              let dst = outBuffer.floatChannelData else { return }

        // Echo operates on interleaved data, so pack -> process -> unpack.
        var interleaved = [Float](repeating: 0, count: frameCount * channels)
        for ch in 0..<channels {
            let srcCh = src[min(ch, Int(inputBuffer.format.channelCount) - 1)]
            for frame in 0..<frameCount {
                interleaved[frame * channels + ch] = srcCh[frame]
            }
        }

        interleaved.withUnsafeMutableBufferPointer { ptr in
            echo.process(ptr.baseAddress!, frameCount: frameCount, gain: gain)
        }

        for ch in 0..<channels {
            let dstCh = dst[ch]
            for frame in 0..<frameCount {
                dstCh[frame] = interleaved[frame * channels + ch]
            }
        }

        player.scheduleBuffer(outBuffer, completionHandler: nil)
    }
}
