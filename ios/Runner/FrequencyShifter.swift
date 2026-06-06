import Foundation

/// Single-sideband (SSB) frequency shifter via IIR Hilbert transform pair.
///
/// Shifts all frequencies upward by `shiftHz` (default 8 Hz).  Even a small
/// shift breaks acoustic feedback: feedback requires a stable phase loop, but a
/// continuously shifting frequency can never maintain the constant phase
/// relationship needed for oscillation to build up.
///
/// Implementation: two parallel 2-stage first-order all-pass IIR chains that
/// approximate a 90° phase difference across the audio band (Regalia-Mitra
/// design), followed by quadrature mixing using a phasor that advances
/// `shiftHz` cycles per second.  No per-sample trig calls — the phasor is
/// rotated by complex multiplication each frame.
///
/// Frequency accuracy: ±< 1 Hz drift (phasor normalized every 4096 frames).
final class FrequencyShifter {

    // MARK: - Hilbert IIR all-pass coefficients
    // Two 2-stage all-pass paths tuned for ~90° phase difference from
    // 300 Hz to 16 kHz at 48 kHz sample rate.
    private static let kA: (Float, Float) = (0.4021921162, 0.8561710882)
    private static let kB: (Float, Float) = (0.6923878,    0.9360654   )

    // MARK: - Per-channel all-pass state [ch = 0|1][stage = 0|1]
    private var xA0: [Float] = [0, 0], yA0: [Float] = [0, 0]
    private var xA1: [Float] = [0, 0], yA1: [Float] = [0, 0]
    private var xB0: [Float] = [0, 0], yB0: [Float] = [0, 0]
    private var xB1: [Float] = [0, 0], yB1: [Float] = [0, 0]

    // MARK: - Phasor (shared across channels within the same frame)
    private var cosP: Float = 1.0
    private var sinP: Float = 0.0
    private var cosDelta: Float = 1.0
    private var sinDelta: Float = 0.0

    private var framesSinceNorm: Int = 0

    // MARK: - Config

    var enabled: Bool = true

    func prepare(sampleRate: Float, shiftHz: Float = 8.0) {
        let sr = max(sampleRate, 8_000)
        let phi = 2.0 * Float.pi * shiftHz / sr
        cosDelta = cos(phi)
        sinDelta = sin(phi)
        reset()
    }

    func reset() {
        xA0 = [0,0]; yA0 = [0,0]
        xA1 = [0,0]; yA1 = [0,0]
        xB0 = [0,0]; yB0 = [0,0]
        xB1 = [0,0]; yB1 = [0,0]
        cosP = 1.0; sinP = 0.0
        framesSinceNorm = 0
    }

    // MARK: - Realtime processing (hot path, no allocations)

    /// Shift the frequency of interleaved PCM audio in-place.
    ///
    /// Channel-outer / frame-inner layout: all filter state is extracted into
    /// local scalars before the inner loop and written back once per channel,
    /// reducing class-property array accesses from O(frameCount*channels) to
    /// O(channels) and eliminating per-sample ARC overhead.
    func process(_ ptr: UnsafeMutablePointer<Float>, frameCount: Int, channels: Int) {
        guard enabled, frameCount > 0 else { return }

        let chCount = min(channels, 2)
        let (a0c, a1c) = FrequencyShifter.kA
        let (b0c, b1c) = FrequencyShifter.kB
        let cd = cosDelta, sd = sinDelta
        let startCp = cosP, startSp = sinP
        var finalCp = cosP, finalSp = sinP

        for ch in 0..<chCount {
            // Pull state into locals — zero array subscripts inside the hot loop.
            var lxA0 = xA0[ch], lyA0 = yA0[ch]
            var lxA1 = xA1[ch], lyA1 = yA1[ch]
            var lxB0 = xB0[ch], lyB0 = yB0[ch]
            var lxB1 = xB1[ch], lyB1 = yB1[ch]
            // All channels get the same phasor value at each frame position.
            var cp = startCp, sp = startSp

            for frame in 0..<frameCount {
                let idx = frame * channels + ch
                let x = ptr[idx]

                // Path A – two cascaded first-order all-pass sections
                // y(n) = -a·x(n) + x(n-1) + a·y(n-1)
                let outA0 = -a0c * x     + lxA0 + a0c * lyA0
                let outA1 = -a1c * outA0 + lxA1 + a1c * lyA1
                lxA0 = x;     lyA0 = outA0
                lxA1 = outA0; lyA1 = outA1

                // Path B (~90° from A)
                let outB0 = -b0c * x     + lxB0 + b0c * lyB0
                let outB1 = -b1c * outB0 + lxB1 + b1c * lyB1
                lxB0 = x;     lyB0 = outB0
                lxB1 = outB0; lyB1 = outB1

                // Quadrature mix: upper sideband only
                ptr[idx] = outA1 * cp - outB1 * sp

                // Advance phasor (complex multiply — no trig per sample)
                let nc = cp * cd - sp * sd
                let ns = sp * cd + cp * sd
                cp = nc; sp = ns
            }

            // Write state back (once per channel, not per sample)
            xA0[ch] = lxA0; yA0[ch] = lyA0
            xA1[ch] = lxA1; yA1[ch] = lyA1
            xB0[ch] = lxB0; yB0[ch] = lyB0
            xB1[ch] = lxB1; yB1[ch] = lyB1
            finalCp = cp; finalSp = sp
        }

        // Renormalize phasor every 4096 frames to prevent floating-point drift.
        framesSinceNorm += frameCount
        if framesSinceNorm >= 4096 {
            let mag = (finalCp * finalCp + finalSp * finalSp).squareRoot()
            if mag > 0 { finalCp /= mag; finalSp /= mag }
            framesSinceNorm = 0
        }

        cosP = finalCp; sinP = finalSp
    }
}
