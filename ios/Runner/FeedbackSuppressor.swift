import Accelerate
import Foundation

/// FFT-based dynamic notch feedback suppressor.
///
/// Detects howling (acoustic feedback) that builds up when a speaker and the
/// built-in mic run at the same time, and automatically parks a narrow notch
/// filter on the offending frequency until it dies down.
///
/// Pipeline per `process(...)` call:
///   1. Mono-sum the interleaved input into a circular analysis buffer.
///   2. Every `analysisInterval` accumulated samples, run a Hann-windowed real
///      FFT over the most recent `fftSize` samples and look for spectral peaks
///      that tower over the local mean (a feedback fingerprint).
///   3. Each detected peak grabs (or refreshes) one of `maxNotches` biquad notch
///      filters, which are then applied in-place to every channel.
///   4. A notch that has not been refreshed for `holdCycles` analysis cycles is
///      released so the affected band reopens once the feedback is gone.
///
/// Everything is sized up front in `prepare(...)`; the audio-callback hot path
/// never allocates (no malloc / array growth / append / removeFirst).
final class FeedbackSuppressor {

    // MARK: - Tunables

    private static let kFFTSize: Int          = 1024   // power of two for vDSP
    private static let kAnalysisInterval: Int = 256    // ~5 ms @ 48 kHz
    private static let kMaxNotches: Int       = 12     // simultaneous notches
    private static let kNotchQ: Float         = 28.0   // slightly wider -> surer kill
    private static let kPeakThreshMult: Float = 5.0    // mean * 5 = candidate
    private static let kHoldCycles: Int       = 100    // ~1 s before release
    private static let kMaxChannels: Int      = 2

    private static let kMinNotchHz: Float     = 100.0
    // Upper bound is sampleRate * 0.45 (computed in prepare()).
    private static let kMaxNotchFraction: Float = 0.45

    // A bin already covered by an active notch must move at least this many
    // bins away to be treated as a new feedback tone (avoids re-arming the same
    // notch every cycle on slightly jittered peaks).
    private static let kBinDedupRadius: Int = 2

    // MARK: - Config

    private var sampleRate: Float = 48_000
    private var channelCount: Int = 1

    // MARK: - FFT state (allocated once in prepare)

    private let log2n: vDSP_Length
    private var fftSetup: FFTSetup?

    // Hann window, reused every analysis pass.
    private var window: [Float]

    // Windowed real input (time domain) prior to packing.
    private var windowed: [Float]

    // Split-complex storage for vDSP_fft_zrip (packed real FFT).
    private var realp: [Float]
    private var imagp: [Float]

    // Magnitude-squared spectrum (fftSize/2 bins).
    private var magnitudes: [Float]

    // MARK: - Circular analysis buffer (mono)

    private var ring: [Float]
    private var ringWrite: Int = 0
    private var samplesSinceAnalysis: Int = 0

    // MARK: - Notch bank

    /// One biquad notch shared across channels (same coefficients) but with
    /// per-channel Direct Form I state.
    private struct Notch {
        var active: Bool = false
        var bin: Int = 0
        var cyclesSinceRefresh: Int = 0

        // Biquad coefficients (normalized so a0 == 1).
        var b0: Float = 1, b1: Float = 0, b2: Float = 0
        var a1: Float = 0, a2: Float = 0
    }

    private var notches: [Notch]

    // Per-(notch, channel) Direct Form I delay state.
    // Flat layout: index = notchIndex * kMaxChannels + channel.
    private var x1: [Float]
    private var x2: [Float]
    private var y1: [Float]
    private var y2: [Float]

    // MARK: - Init

    init() {
        let n = FeedbackSuppressor.kFFTSize
        let half = n / 2
        log2n = vDSP_Length(log2(Float(n)).rounded())

        window     = [Float](repeating: 0, count: n)
        windowed   = [Float](repeating: 0, count: n)
        realp      = [Float](repeating: 0, count: half)
        imagp      = [Float](repeating: 0, count: half)
        magnitudes = [Float](repeating: 0, count: half)
        ring       = [Float](repeating: 0, count: n)

        notches = [Notch](repeating: Notch(),
                          count: FeedbackSuppressor.kMaxNotches)

        let stateCount = FeedbackSuppressor.kMaxNotches * FeedbackSuppressor.kMaxChannels
        x1 = [Float](repeating: 0, count: stateCount)
        x2 = [Float](repeating: 0, count: stateCount)
        y1 = [Float](repeating: 0, count: stateCount)
        y2 = [Float](repeating: 0, count: stateCount)

        // Precompute the Hann window once.
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    // MARK: - Lifecycle

    /// Allocate the FFT setup and capture the run format. Call off the audio
    /// thread (e.g. from AudioEngine.start()).
    func prepare(sampleRate: Float, channelCount: Int) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        self.channelCount = min(max(1, channelCount), FeedbackSuppressor.kMaxChannels)

        if fftSetup == nil {
            fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        }

        reset()
    }

    /// Clear the analysis buffer, drop all notches and zero filter state.
    func reset() {
        for i in ring.indices { ring[i] = 0 }
        ringWrite = 0
        samplesSinceAnalysis = 0

        for i in notches.indices {
            notches[i].active = false
            notches[i].cyclesSinceRefresh = 0
        }
        for i in x1.indices { x1[i] = 0; x2[i] = 0; y1[i] = 0; y2[i] = 0 }
    }

    // MARK: - Realtime processing (hot path -- no allocations)

    /// Detect feedback over `ptr` and apply the active notch bank in place.
    /// `ptr` is interleaved float audio with `channels` channels.
    func process(_ ptr: UnsafeMutablePointer<Float>, frameCount: Int, channels: Int) {
        guard fftSetup != nil, frameCount > 0, channels > 0 else { return }

        let chCount = min(channels, FeedbackSuppressor.kMaxChannels)
        let fftSize = FeedbackSuppressor.kFFTSize
        let invCh = 1.0 / Float(channels)

        // 1) Feed the mono-summed signal into the circular buffer and trigger an
        //    analysis pass whenever enough fresh samples have arrived.
        for frame in 0..<frameCount {
            let base = frame * channels
            var mono: Float = 0
            for ch in 0..<channels {
                mono += ptr[base + ch]
            }
            mono *= invCh

            ring[ringWrite] = mono
            ringWrite += 1
            if ringWrite >= fftSize { ringWrite = 0 }

            samplesSinceAnalysis += 1
            if samplesSinceAnalysis >= FeedbackSuppressor.kAnalysisInterval {
                samplesSinceAnalysis = 0
                analyze()
            }
        }

        // 2) Apply every active notch to each (real) channel using Direct Form I.
        for n in 0..<FeedbackSuppressor.kMaxNotches {
            guard notches[n].active else { continue }

            let b0 = notches[n].b0
            let b1 = notches[n].b1
            let b2 = notches[n].b2
            let a1 = notches[n].a1
            let a2 = notches[n].a2

            for ch in 0..<chCount {
                let s = n * FeedbackSuppressor.kMaxChannels + ch
                var lx1 = x1[s], lx2 = x2[s], ly1 = y1[s], ly2 = y2[s]

                for frame in 0..<frameCount {
                    let idx = frame * channels + ch
                    let x0 = ptr[idx]
                    let y0 = b0 * x0 + b1 * lx1 + b2 * lx2 - a1 * ly1 - a2 * ly2
                    ptr[idx] = y0

                    lx2 = lx1; lx1 = x0
                    ly2 = ly1; ly1 = y0
                }

                x1[s] = lx1; x2[s] = lx2; y1[s] = ly1; y2[s] = ly2
            }
        }
    }

    // MARK: - Analysis

    /// Run a Hann-windowed real FFT over the most recent fftSize samples,
    /// find feedback peaks and (re)arm notch filters. No heap allocation.
    private func analyze() {
        guard let setup = fftSetup else { return }

        let fftSize = FeedbackSuppressor.kFFTSize
        let half = fftSize / 2

        // Pull the ring into `windowed` in chronological order (oldest first),
        // applying the Hann window as we go. ringWrite points at the slot that
        // will be written next == the oldest sample currently buffered.
        let start = ringWrite
        windowed.withUnsafeMutableBufferPointer { wptr in
            ring.withUnsafeBufferPointer { rptr in
                window.withUnsafeBufferPointer { hptr in
                    for i in 0..<fftSize {
                        var r = start + i
                        if r >= fftSize { r -= fftSize }
                        wptr[i] = rptr[r] * hptr[i]
                    }
                }
            }
        }

        // Pack the real signal into split-complex form and run the real FFT.
        windowed.withUnsafeBufferPointer { wptr in
            wptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cplx in
                realp.withUnsafeMutableBufferPointer { rp in
                    imagp.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!,
                                                    imagp: ip.baseAddress!)
                        vDSP_ctoz(cplx, 2, &split, 1, vDSP_Length(half))
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                        // Magnitude-squared spectrum. vDSP_zvmags excludes the
                        // packed Nyquist term in imagp[0]; that is fine since we
                        // bound notches well below Nyquist anyway.
                        magnitudes.withUnsafeMutableBufferPointer { mp in
                            vDSP_zvmags(&split, 1, mp.baseAddress!, 1, vDSP_Length(half))
                        }
                    }
                }
            }
        }

        detectAndArm(half: half)
        ageNotches()
    }

    /// Scan the magnitude spectrum for local maxima that exceed mean * threshold
    /// within the allowed frequency band and assign them to notch filters.
    private func detectAndArm(half: Int) {
        let fftSize = FeedbackSuppressor.kFFTSize
        let binHz = sampleRate / Float(fftSize)

        let minBin = max(1, Int((FeedbackSuppressor.kMinNotchHz / binHz).rounded()))
        let maxHz  = sampleRate * FeedbackSuppressor.kMaxNotchFraction
        let maxBin = min(half - 2, Int((maxHz / binHz).rounded()))
        guard minBin <= maxBin else { return }

        // Mean magnitude over the full half-spectrum (DC excluded) as the noise
        // floor reference. magnitudes[0] is DC; skip it.
        var mean: Float = 0
        magnitudes.withUnsafeBufferPointer { mp in
            // vDSP_meanv over bins [1, half).
            vDSP_meanv(mp.baseAddress!.advanced(by: 1), 1, &mean, vDSP_Length(half - 1))
        }
        guard mean > 0 else { return }
        let threshold = mean * FeedbackSuppressor.kPeakThreshMult

        magnitudes.withUnsafeBufferPointer { mp in
            var bin = minBin
            while bin <= maxBin {
                let m = mp[bin]
                if m > threshold && m > mp[bin - 1] && m >= mp[bin + 1] {
                    armNotch(forBin: bin)
                    // Skip the immediate neighbourhood so a single broad peak
                    // does not consume several notches.
                    bin += FeedbackSuppressor.kBinDedupRadius + 1
                } else {
                    bin += 1
                }
            }
        }
    }

    /// Refresh an existing notch on this bin (or a near neighbour), or claim a
    /// free slot. Recomputes biquad coefficients only when a slot is (re)bound
    /// to a new frequency.
    private func armNotch(forBin bin: Int) {
        // Already covered? Refresh its hold counter and bail.
        for i in 0..<FeedbackSuppressor.kMaxNotches where notches[i].active {
            if abs(notches[i].bin - bin) <= FeedbackSuppressor.kBinDedupRadius {
                notches[i].cyclesSinceRefresh = 0
                return
            }
        }

        // Find a free slot.
        var slot = -1
        for i in 0..<FeedbackSuppressor.kMaxNotches where !notches[i].active {
            slot = i
            break
        }
        guard slot >= 0 else { return }  // bank full -> ignore until one frees up

        let binHz = sampleRate / Float(FeedbackSuppressor.kFFTSize)
        let freq = Float(bin) * binHz
        setNotchCoefficients(slot: slot, freq: freq)

        notches[slot].active = true
        notches[slot].bin = bin
        notches[slot].cyclesSinceRefresh = 0

        // Zero this notch's filter state so it starts cleanly.
        for ch in 0..<FeedbackSuppressor.kMaxChannels {
            let s = slot * FeedbackSuppressor.kMaxChannels + ch
            x1[s] = 0; x2[s] = 0; y1[s] = 0; y2[s] = 0
        }
    }

    /// Age all active notches; release any that have not been refreshed within
    /// the hold window.
    private func ageNotches() {
        for i in 0..<FeedbackSuppressor.kMaxNotches where notches[i].active {
            notches[i].cyclesSinceRefresh += 1
            if notches[i].cyclesSinceRefresh >= FeedbackSuppressor.kHoldCycles {
                notches[i].active = false
            }
        }
    }

    /// RBJ cookbook notch (band-reject) biquad, normalized to a0 == 1.
    private func setNotchCoefficients(slot: Int, freq: Float) {
        let f = min(max(freq, FeedbackSuppressor.kMinNotchHz),
                    sampleRate * FeedbackSuppressor.kMaxNotchFraction)
        let w0 = 2.0 * Float.pi * f / sampleRate
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let alpha = sinw0 / (2.0 * FeedbackSuppressor.kNotchQ)

        let b0: Float = 1.0
        let b1 = -2.0 * cosw0
        let b2: Float = 1.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosw0
        let a2 = 1.0 - alpha

        let invA0 = 1.0 / a0
        notches[slot].b0 = b0 * invA0
        notches[slot].b1 = b1 * invA0
        notches[slot].b2 = b2 * invA0
        notches[slot].a1 = a1 * invA0
        notches[slot].a2 = a2 * invA0
    }
}
