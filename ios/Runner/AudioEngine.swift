import AVFoundation
import AudioToolbox

enum AudioEngineError: LocalizedError {
    /// Mic permission has never been requested -- caller must call
    /// AVAudioSession.sharedInstance().requestRecordPermission(_:) and
    /// retry start().
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

/// Lock-free single-producer/single-consumer ring buffer for interleaved
/// Float audio.
///
/// The producer (mic input render callback) and consumer (output render
/// callback) can run on different real-time threads -- e.g. the built-in mic
/// and a Bluetooth A2DP speaker do not share a hardware clock -- so no locks
/// are used. `writeFrame` is only ever written by the producer and
/// `readFrame` only by the consumer, with one deliberate exception (the
/// overflow-drop in `writePlanar`, documented below). Plain `Int`
/// loads/stores are used instead of an atomic type: on arm64 an aligned
/// word-sized load/store cannot tear, and any momentary staleness in the
/// other side's cursor only shifts the buffer's apparent fill by a few
/// samples for one render cycle, self-correcting on the next.
final class SPSCRingBuffer {
    private let channelCount: Int
    private let framesCapacity: Int   // power of two
    private let indexMask: Int
    private let storage: UnsafeMutablePointer<Float>

    private var writeFrame: Int = 0   // producer-owned
    private var readFrame: Int = 0    // consumer-owned (see writePlanar note)

    /// Samples above this fill (in frames) are dropped from the tail on the
    /// next write, bounding the latency a backlog can add (e.g. right after
    /// a route change stalls the consumer for a few cycles).
    var maxFillFrames: Int

    init(channelCount: Int, framesCapacity: Int, maxFillFrames: Int) {
        precondition(framesCapacity > 0 && (framesCapacity & (framesCapacity - 1)) == 0,
                     "framesCapacity must be a power of two")
        self.channelCount = max(1, channelCount)
        self.framesCapacity = framesCapacity
        self.indexMask = framesCapacity - 1
        self.maxFillFrames = min(max(maxFillFrames, 1), framesCapacity - 1)
        let sampleCapacity = framesCapacity * self.channelCount
        storage = .allocate(capacity: sampleCapacity)
        storage.initialize(repeating: 0, count: sampleCapacity)
    }

    deinit {
        storage.deallocate()
    }

    /// Producer: interleave `frameCount` frames from a non-interleaved
    /// (planar) source buffer list into the ring.
    func writePlanar(_ bufferList: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        guard frameCount > 0 else { return }
        let nch = min(channelCount, bufferList.count)
        guard nch > 0 else { return }

        // Bound the backlog: drop the oldest unread samples up front so
        // added latency stays capped even after a burst (e.g. a route
        // change stalls the consumer for a cycle or two). readFrame is
        // consumer-owned in the steady state; this is the one place the
        // producer also advances it, and only ever forward -- the worst
        // case from racing the consumer's own advance is a stale fill
        // estimate for one cycle, never a crash or desync (indices are
        // always masked before use).
        let used = writeFrame - readFrame
        let newUsed = used + frameCount
        if newUsed > maxFillFrames {
            readFrame += (newUsed - maxFillFrames)
        }

        for f in 0..<frameCount {
            let dstFrame = (writeFrame + f) & indexMask
            let base = dstFrame * channelCount
            for ch in 0..<channelCount {
                let srcCh = ch < nch ? ch : nch - 1
                guard let raw = bufferList[srcCh].mData else { continue }
                let srcPtr = raw.assumingMemoryBound(to: Float.self)
                storage[base + ch] = srcPtr[f]
            }
        }
        writeFrame += frameCount
    }

    /// Consumer: pull up to `frameCount` interleaved frames into `dst`
    /// (capacity >= frameCount*channelCount). Zero-fills the shortfall on
    /// underrun instead of leaving stale data.
    func readInterleaved(into dst: UnsafeMutablePointer<Float>, frameCount: Int) {
        let available = max(0, writeFrame - readFrame)
        let toRead = max(0, min(available, frameCount))

        for f in 0..<toRead {
            let srcFrame = (readFrame + f) & indexMask
            let base = srcFrame * channelCount
            let dstBase = f * channelCount
            for ch in 0..<channelCount {
                dst[dstBase + ch] = storage[base + ch]
            }
        }
        if toRead < frameCount {
            for i in (toRead * channelCount)..<(frameCount * channelCount) {
                dst[i] = 0
            }
        }
        readFrame += toRead
    }
}

/// Low-latency full-duplex engine on top of AVAudioEngine.
///
/// Routing: engine.inputNode -> AVAudioSinkNode (captures into a
/// preallocated lock-free ring buffer) ... AVAudioSourceNode (reads the
/// ring, runs the DSP chain) -> AVAudioUnitEQ -> AVAudioUnitReverb ->
/// AVAudioUnitEffect (system peak limiter) -> mainMixer -> output.
///
/// The session stays in `.playAndRecord` (not voice-chat/voice-processing)
/// with `.mixWithOthers` so the other app's MR track keeps playing, and
/// `.allowBluetoothA2DP` + `.defaultToSpeaker` for BT speaker / speakerphone
/// output. Sink/source nodes are Apple's standard low-latency producer /
/// consumer primitives for exactly this "process my own mic in real time"
/// use case (as opposed to routing the mic through a player node, which
/// forces at least one extra IO buffer of latency and a stale-backlog risk
/// after route changes).
final class AudioEngine: NSObject {

    private var engine = AVAudioEngine()
    private let reverb = AVAudioUnitReverb()
    private let eq = AVAudioUnitEQ(numberOfBands: 5)
    // Output limiter: the LAST stage that can clip. EQ boosts and the reverb's
    // wet tail can both push samples over 0 dBFS, so the limiter must run
    // after both -- not between the DSP chain and EQ, which is where the old
    // per-sample limiter ran. AVAudioUnitEQ/AVAudioUnitReverb are opaque
    // AudioUnits wired directly into the AVAudioEngine graph (not something
    // our own AVAudioSourceNode render block can intercept), so the
    // straightforward way to put a limiter after them is another AudioUnit in
    // the same graph: Apple's built-in Peak Limiter effect
    // (kAudioUnitSubType_PeakLimiter), wrapped as an AVAudioUnitEffect and
    // connected as reverb -> limiter -> mainMixer.
    private let limiter: AVAudioUnitEffect = {
        let desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        return AVAudioUnitEffect(audioComponentDescription: desc)
    }()
    private let echo = EchoEffect()
    private let comp = Compressor()
    private let suppressor = FeedbackSuppressor()
    private let freqShifter = FrequencyShifter()
    private let hpf  = HighPassFilter()
    private let gate = NoiseGate()

    // eq/reverb/limiter are attached once per `engine` instance and never
    // detached (only disconnected) across stop()/start() cycles, to avoid the
    // "detach of unattached node" NSException on a partial-start failure
    // path. A fresh `engine` (media services reset) needs them re-attached.
    private var persistentNodesAttached = false

    private var sinkNode: AVAudioSinkNode?
    private var sourceNode: AVAudioSourceNode?
    private var ringBuffer: SPSCRingBuffer?

    private static let ringFrameCapacity = 8192   // power of two
    private static let dspScratchCapacity = 8192  // frames

    private var dspScratch: UnsafeMutablePointer<Float>?
    private var dspScratchCapacityFrames: Int = 0
    private var channelCount: Int = 1

    private var gain: Float = 1.0
    // false = no amplification: input gain pinned to 1.0 and the compressor
    // is bypassed entirely (not called at all -- no makeup, no 4:1 ratio).
    private var boostEnabled = true
    private(set) var isRunning = false

    private var processingFormat: AVAudioFormat?

    private var isReconfiguring = false
    // Set when the engine was torn down automatically (interruption/route
    // change) rather than by an explicit stop() call, so the matching
    // "resume" notification knows whether it is allowed to restart.
    private var autoStoppedPendingResume = false

    private var observers: [NSObjectProtocol] = []

    // Cached echo params so they survive a prepare()/restart.
    private var lastDelayMs: Float = 150.0
    private var lastFeedback: Float = 0.3

    // Cached EQ/reverb state so they survive a prepare()/restart.
    private var lastEQGains: [Float] = [Float](repeating: 0, count: 5)
    private var lastReverbMix: Float = 0

    private var masterVolume: Float = 1.0

    private(set) var currentRMSLevel: Float = 0.0

    // MARK: - Parameters

    func setGain(_ value: Float) { gain = value }
    func setBoost(_ enabled: Bool) { boostEnabled = enabled }
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
            try checkMicPermission()
            try configureSession()
            attachPersistentNodesIfNeeded()

            // .playAndRecord enables both the real inputNode and A2DP/speaker
            // output, so the processing format is derived straight from the
            // negotiated hardware input format -- no separate capture session
            // needed.
            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            let sampleRate = inputFormat.sampleRate > 0 ? inputFormat.sampleRate : 48_000
            let channels = max(1, Int(inputFormat.channelCount))
            channelCount = channels

            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(channels),
                interleaved: false
            ) else { return false }
            processingFormat = format

            echo.prepare(sampleRate: Float(format.sampleRate),
                         channelCount: channels)
            echo.reset()
            echo.setDelayMs(lastDelayMs)
            echo.setFeedback(lastFeedback)

            comp.prepare(sampleRate: Float(format.sampleRate))
            comp.reset()

            suppressor.prepare(sampleRate: Float(format.sampleRate),
                               channelCount: channels)
            freqShifter.prepare(sampleRate: Float(format.sampleRate))

            hpf.prepare(sampleRate: Float(format.sampleRate))
            gate.prepare(sampleRate: Float(format.sampleRate))

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

            // Pre-allocate the realtime ring buffer + DSP scratch so neither
            // audio callback ever touches the heap.
            let ring = SPSCRingBuffer(channelCount: channels,
                                      framesCapacity: AudioEngine.ringFrameCapacity,
                                      maxFillFrames: AudioEngine.ringFrameCapacity / 2)
            ringBuffer = ring

            let scratch = UnsafeMutablePointer<Float>.allocate(
                capacity: AudioEngine.dspScratchCapacity * channels)
            scratch.initialize(repeating: 0, count: AudioEngine.dspScratchCapacity * channels)
            dspScratch = scratch
            dspScratchCapacityFrames = AudioEngine.dspScratchCapacity

            let sink = AVAudioSinkNode { [weak self] _, frameCount, audioBufferList in
                guard let self = self, let ring = self.ringBuffer else { return noErr }
                let abl = UnsafeMutableAudioBufferListPointer(
                    UnsafeMutablePointer(mutating: audioBufferList))
                ring.writePlanar(abl, frameCount: Int(frameCount))
                return noErr
            }
            engine.attach(sink)
            engine.connect(engine.inputNode, to: sink, format: inputFormat)
            sinkNode = sink

            let source = AVAudioSourceNode(format: format) { [weak self] isSilence, _, frameCount, audioBufferList in
                isSilence.pointee = false
                return self?.renderSource(frameCount: frameCount, audioBufferList: audioBufferList) ?? noErr
            }
            engine.attach(source)
            sourceNode = source

            engine.connect(source, to: eq, format: format)
            engine.connect(eq, to: reverb, format: format)
            engine.connect(reverb, to: limiter, format: format)
            engine.connect(limiter, to: engine.mainMixerNode, format: format)

            engine.prepare()
            try engine.start()

            // Bound the ring to ~2 *actual* IO buffers (the preferred 5 ms
            // duration is only a request; Bluetooth routes in particular
            // often force a larger one).
            let session = AVAudioSession.sharedInstance()
            let ioFrames = Int((session.ioBufferDuration * session.sampleRate).rounded())
            ring.maxFillFrames = min(max(ioFrames, 64) * 2, AudioEngine.ringFrameCapacity - 1)

            registerSessionObservers()

            isRunning = true
            autoStoppedPendingResume = false
            return true
        } catch {
            NSLog("echomic: failed to start engine: \(error)")
            stop()
            return false
        }
    }

    func stop() {
        internalStop(keepObservers: false)
        autoStoppedPendingResume = false
    }

    // MARK: - Internals

    private func attachPersistentNodesIfNeeded() {
        guard !persistentNodesAttached else { return }
        engine.attach(eq)
        engine.attach(reverb)
        engine.attach(limiter)
        persistentNodesAttached = true
    }

    /// Tears down the engine graph and deactivates the session. When
    /// `keepObservers` is true (interruption/route-change-driven teardown),
    /// the session lifecycle observers are left registered so the matching
    /// "resume" notification can restart us later.
    private func internalStop(keepObservers: Bool) {
        if !keepObservers {
            removeSessionObservers()
        }

        if let s = sinkNode {
            engine.disconnectNodeInput(s)
            engine.detach(s)
            sinkNode = nil
        }
        if let s = sourceNode {
            engine.disconnectNodeOutput(s)
            engine.detach(s)
            sourceNode = nil
        }
        // eq/reverb/limiter stay attached for this `engine` instance's
        // lifetime; only drop connections so start() can reconnect with a
        // new format. Detaching here would NSException-crash when stop()
        // runs on a partial start() failure path.
        engine.disconnectNodeOutput(limiter)
        engine.disconnectNodeOutput(reverb)
        engine.disconnectNodeOutput(eq)

        if engine.isRunning { engine.stop() }

        ringBuffer = nil
        dspScratch?.deallocate()
        dspScratch = nil
        dspScratchCapacityFrames = 0

        try? AVAudioSession.sharedInstance().setActive(
            false, options: [.notifyOthersOnDeactivation])
        isRunning = false
        processingFormat = nil
    }

    /// Drops all local bookkeeping without touching `engine` -- used only
    /// after mediaServicesWereReset, where the existing engine/session
    /// objects are already invalid and must not be called into.
    private func resetLocalState() {
        sinkNode = nil
        sourceNode = nil
        ringBuffer = nil
        dspScratch?.deallocate()
        dspScratch = nil
        dspScratchCapacityFrames = 0
        isRunning = false
        processingFormat = nil
    }

    private func checkMicPermission() throws {
        // AVAudioApplication.shared.recordPermission (iOS 17+) supersedes
        // this, but its exact member names could not be verified against an
        // SDK on this machine; AVAudioSession.recordPermission is the
        // long-standing, guaranteed-available API (iOS 8+) and is only
        // deprecated, not removed, on iOS 17 -- a compile-clean choice at
        // the cost of one deprecation warning on newer SDKs.
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return
        case .undetermined: throw AudioEngineError.microphoneAccessNotRequested
        case .denied: throw AudioEngineError.microphoneAccessDenied
        @unknown default: throw AudioEngineError.microphoneAccessDenied
        }
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .playAndRecord (not voiceChat/voice-processing) + .mixWithOthers
        // keeps the other app's MR track playing under the mic instead of
        // being stopped when we activate. .allowBluetoothA2DP routes output
        // to a BT speaker (mic then falls back to the built-in mic -- A2DP
        // has no input path). .defaultToSpeaker keeps speakerphone use at
        // normal (not earpiece-quiet) volume when no accessory is attached.
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setPreferredIOBufferDuration(0.005)
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
                // Do NOT rely on iOS to have already stopped the engine for
                // us: isRunning must flip to false right away so the
                // plugin's level/state poll reports it (otherwise the UI
                // keeps showing "running" while the engine is dead).
                guard self.isRunning else { return }
                self.autoStoppedPendingResume = true
                DispatchQueue.main.async {
                    self.internalStop(keepObservers: true)
                }
            case .ended:
                guard self.autoStoppedPendingResume,
                      let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                guard options.contains(.shouldResume), !self.isReconfiguring else { return }
                self.isReconfiguring = true
                self.autoStoppedPendingResume = false
                DispatchQueue.main.async {
                    _ = self.start()
                    self.isReconfiguring = false
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

            switch reason {
            case .oldDeviceUnavailable:
                // Headphones unplugged (or similar): never fall through to
                // the built-in speaker+mic combination while running --
                // that is the textbook acoustic-feedback (howl) setup.
                guard self.isRunning else { return }
                self.autoStoppedPendingResume = true
                DispatchQueue.main.async {
                    self.internalStop(keepObservers: true)
                }
            case .newDeviceAvailable:
                if self.isRunning {
                    let newFormat = self.engine.inputNode.outputFormat(forBus: 0)
                    guard let fmt = self.processingFormat, newFormat.sampleRate > 0,
                          abs(fmt.sampleRate - newFormat.sampleRate) > 1.0
                            || fmt.channelCount != newFormat.channelCount,
                          !self.isReconfiguring else { return }
                    self.isReconfiguring = true
                    DispatchQueue.main.async {
                        self.internalStop(keepObservers: true)
                        _ = self.start()
                        self.isReconfiguring = false
                    }
                    return
                }
                guard self.autoStoppedPendingResume, !self.isReconfiguring else { return }
                self.isReconfiguring = true
                self.autoStoppedPendingResume = false
                DispatchQueue.main.async {
                    _ = self.start()
                    self.isReconfiguring = false
                }
            default:
                break
            }
        }

        let mediaReset = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, !self.isReconfiguring else { return }
            self.isReconfiguring = true
            let wasRunning = self.isRunning
            // Every existing AVAudioEngine/session object is invalid once
            // media services reset -- drop bookkeeping without touching the
            // now-defunct engine, then build a fresh one.
            self.resetLocalState()
            self.engine = AVAudioEngine()
            self.persistentNodesAttached = false
            if wasRunning {
                _ = self.start()
            }
            self.isReconfiguring = false
        }

        let configChange = center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isRunning, !self.isReconfiguring else { return }
            self.isReconfiguring = true
            DispatchQueue.main.async {
                self.internalStop(keepObservers: true)
                _ = self.start()
                self.isReconfiguring = false
            }
        }

        observers = [interruption, routeChange, mediaReset, configChange]
    }

    private func removeSessionObservers() {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        observers.removeAll()
    }

    // MARK: - Realtime processing (hot path -- no allocations)

    /// AVAudioSourceNode render callback: pulls from the ring buffer, runs
    /// the DSP chain, and de-interleaves into the node's output buffer list.
    private func renderSource(frameCount: AVAudioFrameCount,
                              audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let count = Int(frameCount)
        let channels = channelCount

        guard let ring = ringBuffer, let scratch = dspScratch,
              count > 0, count <= dspScratchCapacityFrames else {
            // Defensive silence: never let stale/garbage data reach the
            // speaker if a render call ever arrives larger than expected.
            for buffer in abl {
                if let raw = buffer.mData {
                    memset(raw, 0, Int(buffer.mDataByteSize))
                }
            }
            return noErr
        }

        ring.readInterleaved(into: scratch, frameCount: count)

        hpf.process(scratch, frameCount: count, channels: channels)
        gate.process(scratch, frameCount: count, channels: channels)
        if boostEnabled {
            comp.process(scratch, frameCount: count, channels: channels, applyMakeup: true)
        }
        echo.process(scratch, frameCount: count, gain: boostEnabled ? gain : 1)
        suppressor.process(scratch, frameCount: count, channels: channels)
        freqShifter.process(scratch, frameCount: count, channels: channels)

        // Master volume + RMS level (non-atomic, but adequate for UI polling).
        let total = count * channels
        let vol = masterVolume
        var sumSq: Float = 0
        for i in 0..<total {
            scratch[i] *= vol
            sumSq += scratch[i] * scratch[i]
        }
        currentRMSLevel = sqrt(sumSq / Float(total))

        for ch in 0..<min(channels, abl.count) {
            guard let raw = abl[ch].mData else { continue }
            let dst = raw.assumingMemoryBound(to: Float.self)
            for f in 0..<count {
                dst[f] = scratch[f * channels + ch]
            }
        }
        return noErr
    }
}
