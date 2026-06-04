import Foundation

/// Circular-buffer based echo, matching the Android C++ implementation.
///
/// For every input sample:
///   delayed = buffer[read]
///   out     = in * gain + delayed * feedback
///   buffer[write] = out          // store the wet output so it feeds back
///
/// The buffer is sized for the maximum delay (500 ms) so changing the delay at
/// runtime never reallocates on the audio thread.
final class EchoEffect {

    static let maxDelayMs: Float = 500.0

    private var buffer: [Float] = []
    private var sampleRate: Float = 48_000
    private var channelCount: Int = 1
    private var maxFrames: Int = 0
    private var writeIndex: Int = 0

    // Parameters are read on the realtime render thread; writes come from the UI
    // thread. They are plain scalars, written atomically enough for audio use.
    private var delayFrames: Int = 1
    private var feedback: Float = 0.3

    /// Allocate the delay line. Call before installing the tap (not on the
    /// audio thread).
    func prepare(sampleRate: Float, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = max(1, channelCount)
        maxFrames = Int((EchoEffect.maxDelayMs / 1000.0) * sampleRate) + 1
        buffer = [Float](repeating: 0, count: maxFrames * self.channelCount)
        writeIndex = 0
    }

    func reset() {
        for i in buffer.indices { buffer[i] = 0 }
        writeIndex = 0
    }

    func setDelayMs(_ delayMs: Float) {
        let clamped = min(max(delayMs, 0), EchoEffect.maxDelayMs)
        var frames = Int((clamped / 1000.0) * sampleRate)
        if frames < 1 { frames = 1 }
        if maxFrames > 0 && frames >= maxFrames { frames = maxFrames - 1 }
        delayFrames = frames
    }

    func setFeedback(_ value: Float) {
        feedback = min(max(value, 0), 0.95)  // keep the loop stable
    }

    /// Process interleaved float samples in place.
    func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int, gain: Float) {
        guard maxFrames > 0 else { return }
        let channels = channelCount
        let delay = delayFrames
        let fb = feedback

        for frame in 0..<frameCount {
            var readIndex = writeIndex - delay
            if readIndex < 0 { readIndex += maxFrames }

            let writeBase = writeIndex * channels
            let readBase = readIndex * channels

            for ch in 0..<channels {
                let idx = frame * channels + ch
                let dry = samples[idx] * gain
                let delayed = buffer[readBase + ch]
                let wet = dry + delayed * fb
                buffer[writeBase + ch] = wet
                samples[idx] = wet
            }

            writeIndex += 1
            if writeIndex >= maxFrames { writeIndex = 0 }
        }
    }
}
