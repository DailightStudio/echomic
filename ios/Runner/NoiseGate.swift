import Foundation

/// Peak-envelope noise gate with adjustable threshold.
/// Soft gain (envelope/threshold) near the threshold to avoid clicking.
final class NoiseGate {

    private var threshold: Float = 0.02   // linear amplitude (~-34 dBFS)
    private var envelope:  Float = 0.0
    private var attackCoeff:  Float = 0.0
    private var releaseCoeff: Float = 0.0

    func prepare(sampleRate: Float) {
        let sr = sampleRate > 0 ? sampleRate : 48_000
        attackCoeff  = exp(-1.0 / (sr * 0.005))   // 5 ms attack
        releaseCoeff = exp(-1.0 / (sr * 0.150))   // 150 ms release
        envelope = 0.0
    }

    func reset() { envelope = 0.0 }

    /// Threshold in dBFS (-80 .. 0). Default -34 dBFS.
    func setThresholdDb(_ db: Float) {
        let clamped = min(max(db, -80.0), 0.0)
        threshold = pow(10.0, clamped / 20.0)
    }

    /// Process interleaved float audio in-place.
    func process(_ ptr: UnsafeMutablePointer<Float>, frameCount: Int, channels: Int) {
        var env  = envelope
        let atk  = attackCoeff
        let rel  = releaseCoeff
        let thr  = threshold

        for frame in 0..<frameCount {
            // Peak across channels
            var peak: Float = 0
            for ch in 0..<channels {
                let s = abs(ptr[frame * channels + ch])
                if s > peak { peak = s }
            }

            // Envelope follower
            env = peak > env ? atk * env + (1.0 - atk) * peak
                             : rel * env + (1.0 - rel) * peak

            // Soft gate: gain = 1 above threshold, env/thr below
            let gain: Float = env >= thr ? 1.0 : (env / thr)
            for ch in 0..<channels {
                ptr[frame * channels + ch] *= gain
            }
        }

        envelope = env
    }
}
