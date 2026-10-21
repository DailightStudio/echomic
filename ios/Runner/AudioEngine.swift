import AVFoundation
import AudioToolbox

enum AudioEngineError: LocalizedError {
    /// Mic permission has never been requested -- caller must call
    /// AVAudioSession.sharedInstance().requestRecordPermission(_:) and
    /// retry start().
    case microphoneAccessNotRequested
    case microphoneAccessDenied
    /// The negotiated hardware input format reports 0 Hz and/or 0 channels
    /// (e.g. mid-interruption, or a route still settling after an accessory
    /// change). Connecting AVAudioEngine nodes with such a format raises an
    /// uncatchable ObjC exception instead of throwing, so this is checked
    /// explicitly before any connect(...) call.
    case invalidInputFormat

    var errorDescription: String? {
        switch self {
        case .microphoneAccessNotRequested:
            return "Microphone access not requested yet"
        case .microphoneAccessDenied:
            return "Microphone access denied"
        case .invalidInputFormat:
            return "Invalid audio input format (0 Hz or 0 channels)"
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

    private var observers: [NSObjectProtocol] = []

    // Cached echo params so they survive a prepare()/restart.
    private var lastDelayMs: Float = 150.0
    private var lastFeedback: Float = 0.3

    // Cached EQ/reverb state so they survive a prepare()/restart.
    private var lastEQGains: [Float] = [Float](repeating: 0, count: 5)
    private var lastReverbMix: Float = 0

    private var masterVolume: Float = 1.0

    private(set) var currentRMSLevel: Float = 0.0

    /// Why the engine last stopped on its own ("unplug" / "interruption"),
    /// nil after a user stop(). Read by the plugin when it reports
    /// running:false so the UI can say what actually happened.
    private(set) var lastStopReason: String?

    // MARK: - Parameters

    // Hard ceiling at 4x: beyond that the compressor makeup + echo feed and
    // the output limiter start fighting each other audibly, and it is well
    // past any legitimate "quiet mic" use case.
    func setGain(_ value: Float) { gain = min(max(value, 0), 4.0) }
    func setBoost(_ enabled: Bool) { boostEnabled = enabled }
    func setEchoDelay(_ delayMs: Float) { lastDelayMs = delayMs; echo.setDelayMs(delayMs) }
    func setEchoFeedback(_ value: Float) { lastFeedback = value; echo.setFeedback(value) }

    // wetDryMix: 0.0(dry)~1.0(wet) -> AVAudioUnitReverb expects 0~100.
    //
    // NOTE: AVAudioUnitReverb.wetDryMix is a true equal-power-ish crossfade
    // on a single node, not an independent dry gain + wet send: at mix=1.0
    // the dry voice is fully silent, and the dry level falls as the mix
    // rises even well below 1.0. There is no parameter on this node that
    // reduces the dry signal less than that mapping dictates. The correct
    // fix -- a parallel topology (source -> dry mixer bus, source -> 100%-
    // wet reverb -> wet mixer bus, both summed before the limiter) would
    // decouple dry level from wetDryMix entirely, but needs a mixer node
    // with per-bus input volumes threaded through the existing
    // attach/detach lifecycle (see persistentNodesAttached) and could not
    // be verified against a real compiler on this machine, so it is left
    // as a documented follow-up rather than risking an unverified graph
    // change.
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
        lastStopReason = nil
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
            // A disconnected/invalid route (e.g. mid-interruption, or an
            // accessory route still settling) can report 0 Hz / 0 channels
            // here. engine.connect(inputNode, ...) below would then raise
            // an uncatchable ObjC exception instead of a Swift error --
            // fail start() cleanly instead.
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw AudioEngineError.invalidInputFormat
            }
            let sampleRate = inputFormat.sampleRate
            let channels = Int(inputFormat.channelCount)
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
            return true
        } catch {
            NSLog("echomic: failed to start engine: \(error)")
            stop()
            return false
        }
    }

    func stop() {
        lastStopReason = nil
        internalStop(keepObservers: false)
    }

    /// Current output route class + round-trip latency estimate for the UI.
    /// `output`: "speaker" | "wired" | "bluetooth" | "other".
    func routeInfo() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        var output = "other"
        for port in session.currentRoute.outputs {
            switch port.portType {
            case .builtInSpeaker, .builtInReceiver: output = "speaker"
            case .headphones, .usbAudio, .lineOut: output = "wired"
            case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: output = "bluetooth"
            default: break
            }
            if output != "other" { break }
        }
        var info: [String: Any] = ["output": output]
        if isRunning {
            // Mic -> our render callback -> speaker: hardware in + out plus
            // the two IO buffers the engine needs to turn a block around.
            let secs = session.inputLatency + session.outputLatency + session.ioBufferDuration * 2
            info["latencyMs"] = secs * 1000.0
        }
        return info
    }

    // MARK: - Internals

    private func attachPersistentNodesIfNeeded() {
        guard !persistentNodesAttached else { return }
        engine.attach(eq)
        engine.attach(reverb)
        engine.attach(limiter)
        persistentNodesAttached = true
    }

    /// Tears down the engine graph and deactivates the session. `keepObservers`
    /// is only `true` for an immediate, synchronous stop+start done by this
    /// class itself while reconfiguring a still-running engine (new device /
    /// configuration change) -- never to let some later notification resume
    /// us; auto-resume from a stopped state is intentionally not implemented
    /// (see the session observers below).
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
                self.lastStopReason = "interruption"
                DispatchQueue.main.async {
                    self.internalStop(keepObservers: false)
                }
            case .ended:
                // Auto-resume is intentionally NOT implemented. Silently
                // restarting after e.g. a phone call would leave the mic
                // live while the UI still shows "stopped" if the user
                // doesn't notice the app resumed on its own (App Review
                // 2.5.14 risk). Once stopped here, the user must tap Start
                // again.
                break
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
                // Auto-resume is intentionally NOT implemented here (see
                // the interruption observer above) -- stays stopped until
                // the user taps Start again.
                guard self.isRunning else { return }
                self.lastStopReason = "unplug"
                DispatchQueue.main.async {
                    self.internalStop(keepObservers: false)
                }
            case .newDeviceAvailable:
                // Only acts while already running, to reconnect onto the
                // new route's format (e.g. a different mic sample rate).
                // This is a live reconfigure, not a resume from stopped --
                // isRunning is true throughout (stop+start happen back to
                // back, synchronously, on the main queue, so the plugin's
                // poll never observes an intermediate `false`).
                guard self.isRunning, !self.isReconfiguring else { return }
                let newFormat = self.engine.inputNode.outputFormat(forBus: 0)
                guard let fmt = self.processingFormat, newFormat.sampleRate > 0,
                      abs(fmt.sampleRate - newFormat.sampleRate) > 1.0
                        || fmt.channelCount != newFormat.channelCount else { return }
                self.isReconfiguring = true
                DispatchQueue.main.async {
                    self.internalStop(keepObservers: true)
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
            // Every existing AVAudioEngine/session object is invalid once
            // media services reset -- drop bookkeeping without touching the
            // now-defunct engine, then build a fresh one. Deliberately does
            // NOT auto-restart even if it was running before (see the
            // interruption observer above) -- the user must tap Start
            // again.
            self.resetLocalState()
            self.engine = AVAudioEngine()
            self.persistentNodesAttached = false
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
