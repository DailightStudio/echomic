import Foundation

final class Compressor {
    private static let kThresholdDb: Float = -24.0
    private static let kRatio: Float       =   4.0
    private static let kKneeDb: Float      =   6.0
    private static let kAttackMs: Float    =   3.0
    private static let kReleaseMs: Float   = 100.0
    private static let kMakeupDb: Float    =  12.0

    private var attackCoeff: Float     = 0
    private var releaseCoeff: Float    = 0
    private var makeupLinear: Float    = 1
    private var envelope: Float        = 0

    func prepare(sampleRate: Float) {
        let sr = sampleRate
        attackCoeff      = exp(-1.0 / (Compressor.kAttackMs   * 0.001 * sr))
        releaseCoeff     = exp(-1.0 / (Compressor.kReleaseMs  * 0.001 * sr))
        makeupLinear     = pow(10.0, Compressor.kMakeupDb / 20.0)
        envelope    = 0
    }

    func reset() {
        envelope    = 0
    }

    // Call BEFORE EchoEffect. Operates on interleaved float samples.
    // applyMakeup=false: compress only (no +12 dB boost) — the "no boost" mode.
    func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int, channels: Int,
                 applyMakeup: Bool) {
        let makeup = applyMakeup ? makeupLinear : 1
        for f in 0..<frameCount {
            let base = f * channels
            var peak: Float = 0
            for ch in 0..<channels {
                peak = max(peak, abs(samples[base + ch]))
            }

            if peak > envelope {
                envelope = attackCoeff  * envelope + (1 - attackCoeff)  * peak
            } else {
                envelope = releaseCoeff * envelope + (1 - releaseCoeff) * peak
            }

            let gainDb = computeGain(envelope)
            let linearGain = pow(10.0, gainDb / 20.0) * makeup

            // Soft gate: -50 dBFS 이하 신호는 makeup gain을 페이드
            let kGateThresh: Float = 0.003162  // -50 dBFS
            let gateScale: Float = (envelope > kGateThresh) ? 1.0 : (envelope / kGateThresh)
            let finalGain = linearGain * gateScale

            for ch in 0..<channels {
                samples[base + ch] *= finalGain
            }
        }
    }

    private func computeGain(_ envelopeLinear: Float) -> Float {
        let xDb   = 20.0 * log10(envelopeLinear + 1e-8)
        let overDb = xDb - Compressor.kThresholdDb
        if 2.0 * overDb < -Compressor.kKneeDb { return 0.0 }
        if 2.0 * abs(overDb) <= Compressor.kKneeDb {
            let t = overDb + Compressor.kKneeDb * 0.5
            return (1.0 / Compressor.kRatio - 1.0) * t * t / (2.0 * Compressor.kKneeDb)
        }
        return (1.0 / Compressor.kRatio - 1.0) * overDb
    }
}
