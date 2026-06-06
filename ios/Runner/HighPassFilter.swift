import Foundation

/// RBJ cookbook biquad high-pass filter (Q=0.707, Butterworth).
/// Always-on at a fixed cutoff; no UI needed.
final class HighPassFilter {

    private var b0: Float = 1, b1: Float = 0, b2: Float = 0
    private var a1: Float = 0, a2: Float = 0

    private var x1: [Float] = [0, 0]
    private var x2: [Float] = [0, 0]
    private var y1: [Float] = [0, 0]
    private var y2: [Float] = [0, 0]

    func prepare(sampleRate: Float, cutoffHz: Float = 80.0) {
        let f = min(max(cutoffHz, 10.0), sampleRate * 0.45)
        let w0    = 2.0 * Float.pi * f / sampleRate
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let alpha = sinw0 / (2.0 * 0.707 as Float)

        let b0r: Float =  (1.0 + cosw0) / 2.0
        let b1r: Float = -(1.0 + cosw0)
        let b2r: Float =  (1.0 + cosw0) / 2.0
        let a0:  Float =   1.0 + alpha
        let a1r: Float =  -2.0 * cosw0
        let a2r: Float =   1.0 - alpha

        let inv = 1.0 / a0
        b0 = b0r * inv; b1 = b1r * inv; b2 = b2r * inv
        a1 = a1r * inv; a2 = a2r * inv

        reset()
    }

    func reset() {
        x1 = [0, 0]; x2 = [0, 0]; y1 = [0, 0]; y2 = [0, 0]
    }

    /// Process interleaved float audio in-place.
    func process(_ ptr: UnsafeMutablePointer<Float>, frameCount: Int, channels: Int) {
        let chCount = min(channels, 2)
        for ch in 0..<chCount {
            var lx1 = x1[ch], lx2 = x2[ch], ly1 = y1[ch], ly2 = y2[ch]
            for frame in 0..<frameCount {
                let idx = frame * channels + ch
                let x0  = ptr[idx]
                let y0  = b0*x0 + b1*lx1 + b2*lx2 - a1*ly1 - a2*ly2
                ptr[idx] = y0
                lx2 = lx1; lx1 = x0; ly2 = ly1; ly1 = y0
            }
            x1[ch] = lx1; x2[ch] = lx2; y1[ch] = ly1; y2[ch] = ly2
        }
    }
}
