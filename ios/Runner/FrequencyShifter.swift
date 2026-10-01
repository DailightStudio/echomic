import Foundation

/// SSB (single-sideband) frequency shifter via an IIR Hilbert transform pair.
///
/// Each path is a cascade of 4 allpass sections (Olli Niemitalo's polyphase
/// design), each realized as y[n] = c^2 * (x[n] + y[n-2]) - x[n-2]. Path A
/// carries one extra sample of delay, which flattens the A/B phase difference
/// to ~90 degrees across the band. Multiplying the quadrature pair by a phasor
/// rotating at shiftHz translates the spectrum by a few Hz, which breaks up
/// acoustic feedback loops on the speaker.
///
/// Same math as android/app/src/main/cpp/frequency_shifter.h — keep the two in
/// lockstep. Measured with android/app/src/main/cpp/frequency_shifter_check.py at
/// 48 kHz: phase diff 90.2/90.3/90.0/90.4/90.5 deg and sideband rejection
/// 56.2/54.2/74.7/48.9/46.8 dB at 100/200/500/1k/5k Hz. (The previous 2-stage
/// version gave 15-70 deg, i.e. an audible 16 Hz warble.)
///
/// Default OFF: only useful on the speaker; with earphones there is no loop.
final class FrequencyShifter {

    private static let kStages = 4
    private static let kMaxChannels = 2
    private static let kCoeffA: [Float] = [0.6923878, 0.9360654322959, 0.9882295226860, 0.9987488452737]
    private static let kCoeffB: [Float] = [0.4021921162426, 0.8561710882420, 0.9722909545651, 0.9952884791278]

    var enabled: Bool = false

    // Per channel, per stage: x1, x2, y1, y2. Raw pointers so the render thread
    // never touches Swift arrays (no ARC / copy-on-write on the hot path).
    private let stateA: UnsafeMutablePointer<Float>
    private let stateB: UnsafeMutablePointer<Float>
    private let aDelay: UnsafeMutablePointer<Float>
    private let c2A: UnsafeMutablePointer<Float>
    private let c2B: UnsafeMutablePointer<Float>
    private static var stateCount: Int { kMaxChannels * kStages * 4 }

    private var cosP: Float = 1
    private var sinP: Float = 0
    private var cosDelta: Float = 1
    private var sinDelta: Float = 0
    private var framesSinceNorm = 0

    init() {
        stateA = .allocate(capacity: FrequencyShifter.stateCount)
        stateB = .allocate(capacity: FrequencyShifter.stateCount)
        aDelay = .allocate(capacity: FrequencyShifter.kMaxChannels)
        c2A = .allocate(capacity: FrequencyShifter.kStages)
        c2B = .allocate(capacity: FrequencyShifter.kStages)
        for k in 0..<FrequencyShifter.kStages {
            c2A[k] = FrequencyShifter.kCoeffA[k] * FrequencyShifter.kCoeffA[k]
            c2B[k] = FrequencyShifter.kCoeffB[k] * FrequencyShifter.kCoeffB[k]
        }
        reset()
    }

    deinit {
        stateA.deallocate()
        stateB.deallocate()
        aDelay.deallocate()
        c2A.deallocate()
        c2B.deallocate()
    }

    func prepare(sampleRate: Float, shiftHz: Float = 8.0) {
        let sr = max(sampleRate, 8_000)
        let phi = 2.0 * Float.pi * shiftHz / sr
        cosDelta = cos(phi)
        sinDelta = sin(phi)
        reset()
    }

    func reset() {
        stateA.update(repeating: 0, count: FrequencyShifter.stateCount)
        stateB.update(repeating: 0, count: FrequencyShifter.stateCount)
        aDelay.update(repeating: 0, count: FrequencyShifter.kMaxChannels)
        cosP = 1
        sinP = 0
        framesSinceNorm = 0
    }

    /// y[n] = c^2 * (x[n] + y[n-2]) - x[n-2]; state layout x1, x2, y1, y2.
    @inline(__always)
    private static func allpassStep(_ s: UnsafeMutablePointer<Float>, _ c2: Float, _ x0: Float) -> Float {
        let y0 = c2 * (x0 + s[3]) - s[1]
        s[1] = s[0]; s[0] = x0
        s[3] = s[2]; s[2] = y0
        return y0
    }

    /// Shift interleaved PCM in place. Realtime-safe: no allocation, no locks.
    func process(_ ptr: UnsafeMutablePointer<Float>, frameCount: Int, channels: Int) {
        guard enabled, frameCount > 0 else { return }
        let chCount = min(channels, FrequencyShifter.kMaxChannels)
        let stages = FrequencyShifter.kStages
        let cd = cosDelta, sd = sinDelta
        let startCp = cosP, startSp = sinP
        var finalCp = cosP, finalSp = sinP

        for ch in 0..<chCount {
            let stA = stateA + ch * stages * 4
            let stB = stateB + ch * stages * 4
            var delayed = aDelay[ch]
            var cp = startCp, sp = startSp

            for f in 0..<frameCount {
                let idx = f * channels + ch
                let x = ptr[idx]

                var yAraw = x
                for k in 0..<stages {
                    yAraw = FrequencyShifter.allpassStep(stA + k * 4, c2A[k], yAraw)
                }
                let yA = delayed      // one-sample delay on path A
                delayed = yAraw

                var yB = x
                for k in 0..<stages {
                    yB = FrequencyShifter.allpassStep(stB + k * 4, c2B[k], yB)
                }

                ptr[idx] = yA * cp - yB * sp

                let nc = cp * cd - sp * sd
                let ns = sp * cd + cp * sd
                cp = nc
                sp = ns
            }

            aDelay[ch] = delayed
            finalCp = cp
            finalSp = sp
        }

        framesSinceNorm += frameCount
        if framesSinceNorm >= 4096 {
            let mag = (finalCp * finalCp + finalSp * finalSp).squareRoot()
            if mag > 0 { finalCp /= mag; finalSp /= mag }
            framesSinceNorm = 0
        }
        cosP = finalCp
        sinP = finalSp
    }
}
