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
///      that tower over the spectral *median* (robust against loud tonal peaks).
///   3. Each peak becomes a howl candidate that must pass multi-criteria
///      validation before arming a notch — persistence over consecutive cycles
///      (IPMP), magnitude growth, and missing 2nd/3rd harmonics (PHPR), which
///      together separate feedback from voiced speech/music.
///   4. A notch that has not been refreshed within `kHoldSeconds` is released
///      so the affected band reopens once the feedback is gone.
///
/// Everything is sized up front in `prepare(...)`; the audio-callback hot path
/// never allocates (no malloc / array growth / append / removeFirst).
final class FeedbackSuppressor {

    // MARK: - Tunables

    private static let kFFTSize: Int          = 1024   // power of two for vDSP
    private static let kAnalysisInterval: Int = 256    // ~5 ms @ 48 kHz
    private static let kMaxNotches: Int       = 12     // simultaneous notches
    private static let kNotchQ: Float         = 28.0   // slightly wider -> surer kill
    private static let kPeakThreshMult: Float = 5.0    // median * 5 = candidate
    private static let kHoldSeconds: Float    = 0.7    // hold before release
    private static let kMaxChannels: Int      = 2

    // Howl-candidate validation (mirrors the Android C++ implementation).
    private static let kMaxCandidates: Int    = 24
    private static let kMinHitCount: Int      = 6      // IPMP: ~32 ms persistence
    private static let kGrowthMinRatio: Float = 1.0    // latest >= running average
    private static let kHarmonic2Ratio: Float = 0.6    // PHPR thresholds (power)
    private static let kHarmonic3Ratio: Float = 0.4

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

    // Scratch buffer for the in-place median quickselect (no allocation in
    // the audio callback).
    private var medianScratch: [Float]

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
        var freq: Float = 0            // tracked (smoothed) center frequency, Hz
        var cyclesSinceRefresh: Int = 0

        // Biquad coefficients (normalized so a0 == 1).
        var b0: Float = 1, b1: Float = 0, b2: Float = 0
        var a1: Float = 0, a2: Float = 0
    }

    private var notches: [Notch]

    /// A spectral peak being tracked across analysis cycles before it is
    /// allowed to arm a notch (IPMP / growth bookkeeping).
    private struct Candidate {
        var bin: Int = 0
        var hitCount: Int = 0          // consecutive-detection streak
        var lastMagnitude: Float = 0
        var magnitudeSum: Float = 0    // running sum for the growth average
        var seenThisCycle: Bool = false
    }

    private var candidates: [Candidate]

    // Time-based hold converted to analysis cycles in prepare().
    private var holdCycles: Int = 131

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
        medianScratch = [Float](repeating: 0, count: half)
        ring       = [Float](repeating: 0, count: n)

        notches = [Notch](repeating: Notch(),
                          count: FeedbackSuppressor.kMaxNotches)
        candidates = [Candidate](repeating: Candidate(),
                                 count: FeedbackSuppressor.kMaxCandidates)

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

        // Sample-rate independent hold: a notch is retired kHoldSeconds after
        // its peak was last seen, regardless of the analysis cadence.
        holdCycles = Int((FeedbackSuppressor.kHoldSeconds * self.sampleRate
                          / Float(FeedbackSuppressor.kAnalysisInterval)).rounded())

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
        for i in candidates.indices { candidates[i] = Candidate() }
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

    /// Scan the magnitude spectrum for local maxima that exceed median *
    /// threshold within the allowed frequency band, validate each one as real
    /// howling (IPMP / growth / PHPR) and assign survivors to notch filters.
    private func detectAndArm(half: Int) {
        let fftSize = FeedbackSuppressor.kFFTSize
        let binHz = sampleRate / Float(fftSize)

        let minBin = max(1, Int((FeedbackSuppressor.kMinNotchHz / binHz).rounded()))
        let maxHz  = sampleRate * FeedbackSuppressor.kMaxNotchFraction
        let maxBin = min(half - 2, Int((maxHz / binHz).rounded()))
        guard minBin <= maxBin else { return }

        for i in candidates.indices { candidates[i].seenThisCycle = false }

        // Median-based threshold: unlike the mean, the median is not inflated
        // by a few strong tonal peaks, so loud howls cannot mask quieter ones.
        let median = computeMedian(half: half)
        let threshold = max(median * FeedbackSuppressor.kPeakThreshMult, 1e-6)

        var bin = minBin
        while bin <= maxBin {
            let m = magnitudes[bin]
            if m > threshold && m > magnitudes[bin - 1] && m >= magnitudes[bin + 1] {
                if isRealHowl(bin: bin, half: half) {
                    armNotch(forBin: bin)
                }
                // Skip the immediate neighbourhood so a single broad peak
                // does not consume several notches.
                bin += FeedbackSuppressor.kBinDedupRadius + 1
            } else {
                bin += 1
            }
        }

        // Candidates not re-detected this cycle lose their streak: howling is
        // sustained, so a single miss resets the persistence counter (IPMP).
        for i in candidates.indices where !candidates[i].seenThisCycle {
            candidates[i].hitCount = 0
        }
    }

    /// Median of magnitudes[1..<half] (DC excluded) via in-place quickselect
    /// on the preallocated scratch buffer. No heap allocation.
    private func computeMedian(half: Int) -> Float {
        let count = half - 1
        guard count > 0 else { return 0 }

        let k = count / 2
        var result: Float = 0
        medianScratch.withUnsafeMutableBufferPointer { sp in
            magnitudes.withUnsafeBufferPointer { mp in
                for i in 0..<count { sp[i] = mp[i + 1] }
            }
            // Hoare quickselect for the k-th smallest element.
            var lo = 0
            var hi = count - 1
            while lo < hi {
                let pivot = sp[(lo + hi) / 2]
                var i = lo
                var j = hi
                while i <= j {
                    while sp[i] < pivot { i += 1 }
                    while sp[j] > pivot { j -= 1 }
                    if i <= j {
                        sp.swapAt(i, j)
                        i += 1
                        j -= 1
                    }
                }
                if k <= j { hi = j } else if k >= i { lo = i } else { break }
            }
            result = sp[k]
        }
        return result
    }

    /// Multi-criteria validation that separates feedback from voiced content.
    private func isRealHowl(bin: Int, half: Int) -> Bool {
        let idx = candidateIndex(forBin: bin)
        candidates[idx].seenThisCycle = true
        candidates[idx].bin = bin
        candidates[idx].hitCount += 1
        candidates[idx].lastMagnitude = magnitudes[bin]
        candidates[idx].magnitudeSum += magnitudes[bin]
        if candidates[idx].hitCount >= 64 {  // keep the running average finite
            candidates[idx].hitCount /= 2
            candidates[idx].magnitudeSum *= 0.5
        }

        // IPMP: must persist for kMinHitCount consecutive analysis cycles.
        if candidates[idx].hitCount < FeedbackSuppressor.kMinHitCount { return false }

        // Growth: feedback builds up, so the latest magnitude must sit at or
        // above the candidate's running average (transient speech peaks decay).
        let avg = candidates[idx].magnitudeSum / Float(candidates[idx].hitCount)
        if candidates[idx].lastMagnitude < avg * FeedbackSuppressor.kGrowthMinRatio {
            return false
        }

        // PHPR: voiced speech carries strong 2nd/3rd harmonics; a howl is a
        // near-pure sinusoid. Comparable energy at 2f or 3f -> treat as voice.
        let m = candidates[idx].lastMagnitude
        let bin2 = bin * 2
        let bin3 = bin * 3
        if bin2 + 1 < half {
            let h2 = max(magnitudes[bin2 - 1], max(magnitudes[bin2], magnitudes[bin2 + 1]))
            if h2 > m * FeedbackSuppressor.kHarmonic2Ratio { return false }
        }
        if bin3 + 1 < half {
            let h3 = max(magnitudes[bin3 - 1], max(magnitudes[bin3], magnitudes[bin3 + 1]))
            if h3 > m * FeedbackSuppressor.kHarmonic3Ratio { return false }
        }
        return true
    }

    /// Find the candidate tracking this bin (within the dedup radius) or claim
    /// a slot for a fresh streak, evicting the weakest streak when full.
    private func candidateIndex(forBin bin: Int) -> Int {
        var freeSlot = -1
        var weakest = 0
        for i in 0..<FeedbackSuppressor.kMaxCandidates {
            if candidates[i].hitCount > 0 {
                if abs(candidates[i].bin - bin) <= FeedbackSuppressor.kBinDedupRadius {
                    return i
                }
                if candidates[i].hitCount < candidates[weakest].hitCount {
                    weakest = i
                }
            } else if freeSlot < 0 {
                freeSlot = i
            }
        }
        let slot = freeSlot >= 0 ? freeSlot : weakest
        candidates[slot] = Candidate(bin: bin)
        return slot
    }

    /// Refresh an existing notch on this bin (or a near neighbour), or claim a
    /// free slot. Recomputes biquad coefficients only when a slot is (re)bound
    /// to a new frequency.
    private func armNotch(forBin bin: Int) {
        // Already covered? Refresh (and re-center) the existing notch.
        for i in 0..<FeedbackSuppressor.kMaxNotches where notches[i].active {
            if abs(notches[i].bin - bin) <= FeedbackSuppressor.kBinDedupRadius {
                refreshNotch(slot: i, bin: bin)
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

        let freq = interpolateFrequency(bin: bin)
        setNotchCoefficients(slot: slot, freq: freq)

        notches[slot].active = true
        notches[slot].bin = bin
        notches[slot].freq = freq
        notches[slot].cyclesSinceRefresh = 0

        // Zero this notch's filter state so it starts cleanly.
        for ch in 0..<FeedbackSuppressor.kMaxChannels {
            let s = slot * FeedbackSuppressor.kMaxChannels + ch
            x1[s] = 0; x2[s] = 0; y1[s] = 0; y2[s] = 0
        }
    }

    /// Re-detected peak on an active notch: re-estimate the precise frequency
    /// and ease the notch toward it (howls drift as the room/mic geometry
    /// changes), keeping the filter state intact to avoid transients.
    private func refreshNotch(slot: Int, bin: Int) {
        let newFreq = interpolateFrequency(bin: bin)
        let smoothed = 0.7 * notches[slot].freq + 0.3 * newFreq
        setNotchCoefficients(slot: slot, freq: smoothed)
        notches[slot].freq = smoothed
        notches[slot].bin = bin
        notches[slot].cyclesSinceRefresh = 0
    }

    /// Sub-bin peak frequency estimate: fit a parabola through the
    /// log-magnitudes at bin-1/bin/bin+1 and return its vertex. Cuts the worst
    /// case center error from binHz/2 (~23 Hz @ 48 kHz) to a few Hz, which
    /// matters for the narrow notch to actually sit on the howl.
    private func interpolateFrequency(bin: Int) -> Float {
        let binHz = sampleRate / Float(FeedbackSuppressor.kFFTSize)
        let half = FeedbackSuppressor.kFFTSize / 2
        guard bin > 0, bin < half - 1 else { return Float(bin) * binHz }

        let m0 = magnitudes[bin - 1]
        let m1 = magnitudes[bin]
        let m2 = magnitudes[bin + 1]
        guard m0 > 0, m1 > 0, m2 > 0 else { return Float(bin) * binHz }

        let lm0 = log(m0), lm1 = log(m1), lm2 = log(m2)
        let denom = lm0 - 2.0 * lm1 + lm2
        guard abs(denom) > 1e-12 else { return Float(bin) * binHz }

        var fracBin = (lm0 - lm2) / (2.0 * denom)
        fracBin = min(max(fracBin, -0.5), 0.5)
        return (Float(bin) + fracBin) * binHz
    }

    /// Age all active notches; release any that have not been refreshed within
    /// the hold window.
    private func ageNotches() {
        for i in 0..<FeedbackSuppressor.kMaxNotches where notches[i].active {
            notches[i].cyclesSinceRefresh += 1
            if notches[i].cyclesSinceRefresh >= holdCycles {
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
