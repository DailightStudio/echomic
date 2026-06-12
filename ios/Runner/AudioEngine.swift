import AVFoundation

enum AudioEngineError: LocalizedError {
    /// Mic permission has never been requested — caller must call
    /// AVCaptureDevice.requestAccess(for: .audio) and retry start().
    case microphoneAccessNotRequested
    case microphoneAccessDenied

    var errorDescription: String? {
        switch self {
        case .microphoneAccessNotRequested:
            return "Microphone access not requested yet"
        case .microphoneAccessDenied:
            return "Microphone access denied"
        }
    }
}

/// Low-latency full-duplex engine on top of AVAudioEngine.
///
/// Routing: AVCaptureSession mic -> (echo applied in capture callback) ->
/// playerNode -> mainMixer -> output. We capture the mic via AVCaptureSession
/// (so the AVAudioSession category can stay `.playback` and route to A2DP BT
/// speakers), run gain + echo on the captured PCM, and immediately schedule the
/// processed buffer on an AVAudioPlayerNode so it reaches the speaker with
/// minimal added latency.
final class AudioEngine: NSObject {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let reverb = AVAudioUnitReverb()
    private let eq = AVAudioUnitEQ(numberOfBands: 5)
    private let echo = EchoEffect()
    private let comp = Compressor()
    private let suppressor = FeedbackSuppressor()
    private let freqShifter = FrequencyShifter()
    private let hpf  = HighPassFilter()
    private let gate = NoiseGate()

    private var gain: Float = 1.0
    private(set) var isRunning = false

    private var processingFormat: AVAudioFormat?

    private var isReconfiguring = false

    private var observers: [NSObjectProtocol] = []

    // AVCaptureSession — mic capture without overriding .playback category
    private var captureSession: AVCaptureSession?
    private let captureQueue = DispatchQueue(label: "echomic.capture", qos: .userInteractive)
    private var audioConverter: AVAudioConverter?

    // Realtime buffer pool: avoid heap allocation on the audio callback.
    private var outputBufferPool: [AVAudioPCMBuffer] = []
    private var poolIndex = 0
    // Free-list for the output pool. Only ever touched on captureQueue
    // (the free-list search in handle() + the scheduleBuffer completion).
    private var bufferFree: [Bool] = []
    private var interleavedScratch: [Float] = []
    // Generation counter guarding the buffer pool across stop()/start() cycles.
    // Only ever read/written on captureQueue (handle(), scheduleBuffer
    // completions, and the sync block in stop()), so no extra locking needed.
    // Stale completions from a previous run see a mismatched generation and
    // must not touch the (re-allocated) bufferFree array.
    private var generation: Int = 0

    // Cached echo params so they survive a prepare()/restart.
    private var lastDelayMs: Float = 150.0
    private var lastFeedback: Float = 0.3

    // Cached EQ/reverb state so they survive a prepare()/restart.
    private var lastEQGains: [Float] = [Float](repeating: 0, count: 5)
    private var lastReverbMix: Float = 0

    private var masterVolume: Float = 1.0

    private(set) var currentRMSLevel: Float = 0.0

    // MARK: - Init

    override init() {
        super.init()
        // Attach nodes exactly once for the engine's lifetime. stop() never
        // detaches them, so a stop() reached via a partial start() failure can
        // never hit the "detach of unattached node" NSException.
        engine.attach(player)
        engine.attach(eq)
        engine.attach(reverb)
    }

    // MARK: - Parameters

    func setGain(_ value: Float) { gain = value }
    func setEchoDelay(_ delayMs: Float) { lastDelayMs = delayMs; echo.setDelayMs(delayMs) }
    func setEchoFeedback(_ value: Float) { lastFeedback = value; echo.setFeedback(value) }

    // wetDryMix: 0.0(dry)~1.0(wet) -> AVAudioUnitReverb expects 0~100.
    func setReverbMix(_ mix: Float) {
        lastReverbMix = min(max(mix, 0), 1)
        reverb.wetDryMix = lastReverbMix * 100
    }

    func setMasterVolume(_ volume: Float) { masterVolume = min(max(volume, 0), 1) }

    func setGateThreshold(_ db: Float) { gate.setThresholdDb(db) }

    func setFrequencyShiftEnabled(_ enabled: Bool) { freqShifter.enabled = enabled }

    func setEQBand(_ band: Int, gainDb: Float) {
        guard band >= 0, band < eq.bands.count else { return }
        let clamped = min(max(gainDb, -12), 12)
        lastEQGains[band] = clamped
        eq.bands[band].gain = clamped
    }

    // MARK: - Lifecycle

    func start() -> Bool {
        if isRunning { return true }
        do {
            try configureSession()

            // .playback disables AVAudioEngine's inputNode, so derive the
            // processing format from the session sample rate and capture the mic
            // via AVCaptureSession instead.
            let sampleRate = AVAudioSession.sharedInstance().sampleRate > 0
                ? AVAudioSession.sharedInstance().sampleRate : 48_000
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ) else { return false }
            processingFormat = format

            echo.prepare(sampleRate: Float(format.sampleRate),
                         channelCount: Int(format.channelCount))
            echo.reset()
            echo.setDelayMs(lastDelayMs)
            echo.setFeedback(lastFeedback)

            comp.prepare(sampleRate: Float(format.sampleRate))
            comp.reset()

            suppressor.prepare(sampleRate: Float(format.sampleRate),
                               channelCount: Int(format.channelCount))
            freqShifter.prepare(sampleRate: Float(format.sampleRate))

            hpf.prepare(sampleRate: Float(format.sampleRate))
            gate.prepare(sampleRate: Float(format.sampleRate))

            // player/eq/reverb are attached once in init().

            // Configure 5 EQ bands
            let eqConfig: [(Float, AVAudioUnitEQFilterType, Float)] = [
                (100,  .lowShelf,  1.0),
                (400,  .parametric, 1.5),
                (1000, .parametric, 1.5),
                (3000, .parametric, 1.5),
                (8000, .highShelf,  1.0),
            ]
            for (i, (freq, type, bw)) in eqConfig.enumerated() {
                eq.bands[i].frequency  = freq
                eq.bands[i].filterType = type
                eq.bands[i].bandwidth  = bw
                eq.bands[i].gain       = lastEQGains[i]
                eq.bands[i].bypass     = false
            }

            reverb.loadFactoryPreset(.largeHall)
            reverb.wetDryMix = lastReverbMix * 100  // restore cached mix
            engine.connect(player, to: eq, format: format)
            engine.connect(eq, to: reverb, format: format)
            engine.connect(reverb, to: engine.mainMixerNode, format: format)

            // Pre-allocate the realtime output buffer pool + scratch so the audio
            // callback never touches the heap.
            let maxFrames = 8192
            let poolSize = 8
            outputBufferPool = (0..<poolSize).compactMap {
                _ in AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maxFrames))
            }
            bufferFree = [Bool](repeating: true, count: poolSize)
            interleavedScratch = [Float](repeating: 0, count: maxFrames * Int(format.channelCount))
            poolIndex = 0

            engine.prepare()
            try engine.start()
            player.play()

            // Capture session must start AFTER engine.start()+player.play() so the
            // player is already running when the first captured buffer arrives.
            try setupCaptureSession(processingFormat: format)

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

        captureSession?.stopRunning()
        // Wait for any in-flight captureOutput callback AND invalidate the
        // current generation: scheduleBuffer completions that land on
        // captureQueue after this point (e.g. fired by player.stop() below)
        // see a stale generation and leave bufferFree alone.
        captureQueue.sync { generation += 1 }
        captureSession = nil
        audioConverter = nil
        if player.isPlaying { player.stop() }
        if engine.isRunning { engine.stop() }
        // Nodes stay attached for the engine's lifetime (attached in init());
        // only drop the connections so start() can reconnect with a new format.
        // Detaching here would NSException-crash when stop() runs on a partial
        // start() failure path.
        engine.disconnectNodeOutput(reverb)
        engine.disconnectNodeOutput(eq)
        engine.disconnectNodeOutput(player)
        try? AVAudioSession.sharedInstance().setActive(
            false, options: [.notifyOthersOnDeactivation])
        isRunning = false
        processingFormat = nil
    }

    // MARK: - Internals

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .playback enables A2DP BT output; mic is captured via AVCaptureSession instead.
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setPreferredIOBufferDuration(0.005)
        try session.setPreferredSampleRate(48_000)
        try session.setActive(true)
    }

    private func setupCaptureSession(processingFormat: AVAudioFormat) throws {
        // Fail fast (and cleanly) if mic permission is missing instead of
        // letting startRunning() spin up a session that never delivers audio.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            // Distinct error so the caller can requestAccess and retry start()
            // rather than treating a never-asked state as a hard denial.
            throw AudioEngineError.microphoneAccessNotRequested
        case .denied, .restricted:
            throw AudioEngineError.microphoneAccessDenied
        @unknown default:
            throw AudioEngineError.microphoneAccessDenied
        }

        let cs = AVCaptureSession()
        cs.automaticallyConfiguresApplicationAudioSession = false

        guard let mic = AVCaptureDevice.default(for: .audio) else {
            throw NSError(domain: "echomic", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No mic found"])
        }
        let micInput = try AVCaptureDeviceInput(device: mic)
        guard cs.canAddInput(micInput) else {
            throw NSError(domain: "echomic", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add mic input"])
        }
        cs.addInput(micInput)

        let audioOut = AVCaptureAudioDataOutput()
        audioOut.setSampleBufferDelegate(self, queue: captureQueue)
        guard cs.canAddOutput(audioOut) else {
            throw NSError(domain: "echomic", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add audio output"])
        }
        cs.addOutput(audioOut)

        captureSession = cs
        cs.startRunning()
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

        // captureSession is non-nil here: registerSessionObservers() runs after
        // setupCaptureSession() succeeds.
        let captureError = center.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: captureSession,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            guard !self.isReconfiguring else { return }
            self.isReconfiguring = true
            DispatchQueue.main.async {
                self.stop()
                _ = self.start()
                self.isReconfiguring = false
            }
        }
        observers.append(captureError)
    }

    private func removeSessionObservers() {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        observers.removeAll()
    }

    private func resumeEngine() {
        try? configureSession()
        try? engine.start()
        guard engine.isRunning else {
            // Engine failed to restart -- calling player.play() now would raise
            // an NSException and crash. Fall back to a full reconfigure instead.
            NSLog("echomic: resumeEngine failed to restart engine, reconfiguring")
            guard !isReconfiguring else { return }
            isReconfiguring = true
            DispatchQueue.main.async {
                self.stop()
                _ = self.start()
                self.isReconfiguring = false
            }
            return
        }
        player.play()
        if captureSession?.isRunning == false {
            captureSession?.startRunning()
        }
    }

    /// Runs gain + echo over the captured buffer and schedules it for playback.
    private func handle(inputBuffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard !outputBufferPool.isEmpty else { return }

        // Find a free buffer; drop the frame if all are in flight.
        var freeIdx = -1
        for i in 0..<bufferFree.count where bufferFree[i] {
            freeIdx = i
            break
        }
        guard freeIdx >= 0 else { return }
        bufferFree[freeIdx] = false
        let outBuffer = outputBufferPool[freeIdx]

        let frameCount = Int(inputBuffer.frameLength)
        let channels   = Int(targetFormat.channelCount)
        guard frameCount > 0,
              frameCount <= Int(outBuffer.frameCapacity),
              frameCount * channels <= interleavedScratch.count else {
            bufferFree[freeIdx] = true   // return buffer to pool on early exit
            return
        }

        outBuffer.frameLength = inputBuffer.frameLength

        guard let src = inputBuffer.floatChannelData,
              let dst = outBuffer.floatChannelData else {
            bufferFree[freeIdx] = true
            return
        }

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
            hpf.process(ptr.baseAddress!, frameCount: frameCount, channels: channels)
            gate.process(ptr.baseAddress!, frameCount: frameCount, channels: channels)
            comp.process(ptr.baseAddress!, frameCount: frameCount, channels: channels)
            echo.process(ptr.baseAddress!, frameCount: frameCount, gain: gain)
            comp.limit(ptr.baseAddress!, count: frameCount * channels)
            suppressor.process(ptr.baseAddress!, frameCount: frameCount, channels: channels)
            freqShifter.process(ptr.baseAddress!, frameCount: frameCount, channels: channels)
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

        let idx = freeIdx
        let gen = generation  // handle() runs on captureQueue
        player.scheduleBuffer(outBuffer) { [weak self] in
            self?.captureQueue.async {
                guard let self = self, self.generation == gen else { return }
                self.bufferFree[idx] = true
            }
        }
    }
}

extension AudioEngine: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let fmt = processingFormat else { return }

        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let nativeFormat = AVAudioFormat(cmAudioFormatDescription: fmtDesc) else { return }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return }

        // Allocate buffer matching the capture device's native format
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: nativeFormat,
                                               frameCapacity: frameCount) else { return }
        srcBuffer.frameLength = frameCount

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount),
            into: srcBuffer.mutableAudioBufferList)
        guard copyStatus == noErr else { return }

        if nativeFormat.isEqual(fmt) {
            handle(inputBuffer: srcBuffer, targetFormat: fmt)
            return
        }

        // Formats differ — use AVAudioConverter
        if audioConverter == nil || !audioConverter!.inputFormat.isEqual(nativeFormat) {
            audioConverter = AVAudioConverter(from: nativeFormat, to: fmt)
        }
        guard let converter = audioConverter else { return }

        let ratio = fmt.sampleRate / nativeFormat.sampleRate
        let outFrames = AVAudioFrameCount(Double(frameCount) * ratio + 1)
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: fmt,
                                               frameCapacity: outFrames) else { return }

        var consumed = false
        var convError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return srcBuffer
        }
        converter.convert(to: dstBuffer, error: &convError, withInputFrom: inputBlock)
        guard convError == nil else { return }

        handle(inputBuffer: dstBuffer, targetFormat: fmt)
    }
}
