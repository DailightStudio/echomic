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
    private let reverb = AVAudioUnitReverb()
    private let echo = EchoEffect()
    private let comp = Compressor()

    private var gain: Float = 1.0
    private(set) var isRunning = false
    private var tapInstalled = false

    private var processingFormat: AVAudioFormat?

    private var isReconfiguring = false

    private var observers: [NSObjectProtocol] = []

    // Realtime buffer pool: avoid heap allocation on the audio callback.
    private var outputBufferPool: [AVAudioPCMBuffer] = []
    private var poolIndex = 0
    private var interleavedScratch: [Float] = []

    // Cached echo params so they survive a prepare()/restart.
    private var lastDelayMs: Float = 150.0
    private var lastFeedback: Float = 0.3

    private var masterVolume: Float = 1.0

    private(set) var currentRMSLevel: Float = 0.0

    // MARK: - Parameters

    func setGain(_ value: Float) { gain = value }
    func setEchoDelay(_ delayMs: Float) { lastDelayMs = delayMs; echo.setDelayMs(delayMs) }
    func setEchoFeedback(_ value: Float) { lastFeedback = value; echo.setFeedback(value) }

    // wetDryMix: 0.0(dry)~1.0(wet) -> AVAudioUnitReverb expects 0~100.
    func setReverbMix(_ mix: Float) { reverb.wetDryMix = min(max(mix, 0), 1) * 100 }

    func setMasterVolume(_ volume: Float) { masterVolume = min(max(volume, 0), 1) }

    // MARK: - Lifecycle

    func start() -> Bool {
        if isRunning { return true }
        do {
            try configureSession()

            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)

            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                NSLog("echomic: invalid input format sr=\(inputFormat.sampleRate) ch=\(inputFormat.channelCount)")
                return false
            }

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
            echo.setDelayMs(lastDelayMs)
            echo.setFeedback(lastFeedback)

            comp.prepare(sampleRate: Float(format.sampleRate))
            comp.reset()

            engine.attach(player)
            engine.attach(reverb)
            reverb.loadFactoryPreset(.largeHall)
            reverb.wetDryMix = 0  // off by default
            engine.connect(player, to: reverb, format: format)
            engine.connect(reverb, to: engine.mainMixerNode, format: format)

            // Pre-allocate the realtime output buffer pool + scratch so the audio
            // callback never touches the heap.
            let maxFrames = 8192
            let poolSize = 8
            outputBufferPool = (0..<poolSize).compactMap {
                _ in AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maxFrames))
            }
            interleavedScratch = [Float](repeating: 0, count: maxFrames * Int(format.channelCount))
            poolIndex = 0

            engine.prepare()
            try engine.start()
            player.play()

            // Tap must be installed AFTER engine.start()+player.play() so the
            // player is already running when the first captured buffer arrives.
            let bufferSize: AVAudioFrameCount = 256  // ~5 ms @ 48 kHz
            input.installTap(onBus: 0, bufferSize: bufferSize, format: format) {
                [weak self] buffer, _ in
                self?.handle(inputBuffer: buffer, targetFormat: format)
            }
            tapInstalled = true

            registerSessionObservers()

            isRunning = true
            return true
        } catch {
            NSLog("echomic: failed to start engine: \(error)")
            stop()
            return false
        }
    }

    func stop() {
        removeSessionObservers()

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if player.isPlaying { player.stop() }
        if engine.isRunning { engine.stop() }
        engine.disconnectNodeOutput(reverb)
        engine.detach(reverb)
        engine.disconnectNodeOutput(player)
        engine.detach(player)
        try? AVAudioSession.sharedInstance().setActive(
            false, options: [.notifyOthersOnDeactivation])
        isRunning = false
        processingFormat = nil
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

    // MARK: - Session recovery

    private func registerSessionObservers() {
        removeSessionObservers()

        let center = NotificationCenter.default

        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let info = note.userInfo,
                  let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

            switch type {
            case .began:
                // iOS stops the engine for us; nothing to do.
                break
            case .ended:
                if let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                    if options.contains(.shouldResume) {
                        let newSR = AVAudioSession.sharedInstance().sampleRate
                        if let fmt = self.processingFormat, abs(fmt.sampleRate - newSR) > 1.0 {
                            // Sample rate changed during the interruption -- full
                            // reconfigure. Defer off the session callback stack to
                            // avoid re-entrant stop()/start() crashes.
                            guard !self.isReconfiguring else { return }
                            self.isReconfiguring = true
                            DispatchQueue.main.async {
                                self.stop()
                                _ = self.start()
                                self.isReconfiguring = false
                            }
                        } else {
                            self.resumeEngine()
                        }
                    }
                }
            @unknown default:
                break
            }
        }

        let routeChange = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let info = note.userInfo,
                  let rawReason = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }

            if reason == .oldDeviceUnavailable || reason == .newDeviceAvailable {
                let newSampleRate = AVAudioSession.sharedInstance().sampleRate
                if let fmt = self.processingFormat, abs(fmt.sampleRate - newSampleRate) > 1.0 {
                    // Format changed -- full reconfigure. Defer off the session
                    // callback stack to avoid re-entrant stop()/start() crashes.
                    guard !self.isReconfiguring else { return }
                    self.isReconfiguring = true
                    DispatchQueue.main.async {
                        self.stop()
                        _ = self.start()
                        self.isReconfiguring = false
                    }
                } else {
                    self.resumeEngine()
                }
            }
        }

        observers = [interruption, routeChange]
    }

    private func removeSessionObservers() {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        observers.removeAll()
    }

    private func resumeEngine() {
        try? engine.start()
        player.play()
    }

    /// Runs gain + echo over the captured buffer and schedules it for playback.
    private func handle(inputBuffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard !outputBufferPool.isEmpty else { return }

        let outBuffer = outputBufferPool[poolIndex % outputBufferPool.count]
        poolIndex &+= 1

        let frameCount = Int(inputBuffer.frameLength)
        let channels   = Int(targetFormat.channelCount)
        guard frameCount > 0,
              frameCount <= Int(outBuffer.frameCapacity),
              frameCount * channels <= interleavedScratch.count else { return }

        outBuffer.frameLength = inputBuffer.frameLength

        guard let src = inputBuffer.floatChannelData,
              let dst = outBuffer.floatChannelData else { return }

        let inChCount = Int(inputBuffer.format.channelCount)

        // Echo operates on interleaved data, so pack -> process -> unpack using
        // the reusable scratch buffer (no heap allocation here).
        if inChCount == channels {
            for ch in 0..<channels {
                let srcCh = src[ch]
                for frame in 0..<frameCount {
                    interleavedScratch[frame * channels + ch] = srcCh[frame]
                }
            }
        } else if inChCount > channels {
            // Input has more channels than output -- downmix (average).
            for ch in 0..<channels {
                for frame in 0..<frameCount {
                    var sum: Float = 0
                    for inCh in 0..<inChCount {
                        sum += src[inCh][frame]
                    }
                    interleavedScratch[frame * channels + ch] = sum / Float(inChCount)
                }
            }
        } else {
            // Input has fewer channels than output -- replicate channel 0
            // (e.g. mono mic feeding a stereo pipeline).
            let srcCh = src[0]
            for ch in 0..<channels {
                for frame in 0..<frameCount {
                    interleavedScratch[frame * channels + ch] = srcCh[frame]
                }
            }
        }

        interleavedScratch.withUnsafeMutableBufferPointer { ptr in
            comp.process(ptr.baseAddress!, frameCount: frameCount, channels: channels)
            echo.process(ptr.baseAddress!, frameCount: frameCount, gain: gain)
            comp.limit(ptr.baseAddress!, count: frameCount * channels)
        }

        // Apply master volume.
        for i in 0..<(frameCount * channels) {
            interleavedScratch[i] *= masterVolume
        }

        // RMS level (non-atomic, but adequate for UI polling).
        var sumSq: Float = 0
        for i in 0..<(frameCount * channels) {
            let s = interleavedScratch[i]
            sumSq += s * s
        }
        currentRMSLevel = sqrt(sumSq / Float(frameCount * channels))

        for ch in 0..<channels {
            let dstCh = dst[ch]
            for frame in 0..<frameCount {
                dstCh[frame] = interleavedScratch[frame * channels + ch]
            }
        }

        player.scheduleBuffer(outBuffer, completionHandler: nil)
    }
}
