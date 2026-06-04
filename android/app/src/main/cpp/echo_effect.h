#ifndef ECHOMIC_ECHO_EFFECT_H
#define ECHOMIC_ECHO_EFFECT_H

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <vector>

/**
 * Circular-buffer based echo.
 *
 * For every input sample:
 *   delayed = buffer[readPos]
 *   out     = in * gain + delayed * feedback
 *   buffer[writePos] = out          // store the wet output so it feeds back
 *
 * The buffer is sized for the maximum delay (500 ms) so that changing the
 * delay at runtime never reallocates on the audio thread.
 */
class EchoEffect {
public:
    EchoEffect() = default;

    // Allocate the delay line. Called from the control thread before the
    // stream starts (not on the audio callback).
    void prepare(int sampleRate, int channelCount) {
        sampleRate_ = sampleRate;
        channelCount_ = channelCount < 1 ? 1 : channelCount;
        const int maxFrames = static_cast<int>((kMaxDelayMs / 1000.0f) * sampleRate_) + 1;
        buffer_.assign(static_cast<size_t>(maxFrames) * channelCount_, 0.0f);
        maxFrames_ = maxFrames;
        writeIndex_ = 0;
        setDelayMs(delayMs_.load());
    }

    void setDelayMs(float delayMs) {
        if (delayMs < 0.0f) delayMs = 0.0f;
        if (delayMs > kMaxDelayMs) delayMs = kMaxDelayMs;
        delayMs_.store(delayMs);
        int frames = static_cast<int>((delayMs / 1000.0f) * sampleRate_);
        if (frames < 1) frames = 1;
        if (frames >= maxFrames_) frames = maxFrames_ - 1;
        delayFrames_.store(frames);
    }

    void setFeedback(float feedback) {
        if (feedback < 0.0f) feedback = 0.0f;
        if (feedback > 0.95f) feedback = 0.95f;  // keep the loop stable
        feedback_.store(feedback);
    }

    void reset() {
        std::fill(buffer_.begin(), buffer_.end(), 0.0f);
        writeIndex_ = 0;
    }

    /**
     * Processes interleaved float samples in place.
     * gain is applied to the dry signal; the delayed (wet) signal is mixed in
     * at the current feedback amount.
     */
    void process(float *samples, int numFrames, float gain) {
        if (maxFrames_ <= 0) return;
        const int channels = channelCount_;
        const int delayFrames = delayFrames_.load();
        const float feedback = feedback_.load();

        for (int frame = 0; frame < numFrames; ++frame) {
            int readIndex = writeIndex_ - delayFrames;
            if (readIndex < 0) readIndex += maxFrames_;

            const size_t writeBase = static_cast<size_t>(writeIndex_) * channels;
            const size_t readBase = static_cast<size_t>(readIndex) * channels;

            for (int ch = 0; ch < channels; ++ch) {
                const size_t idx = static_cast<size_t>(frame) * channels + ch;
                const float dry = samples[idx] * gain;
                const float delayed = buffer_[readBase + ch];
                const float wet = dry + delayed * feedback;
                buffer_[writeBase + ch] = wet;
                samples[idx] = wet;
            }

            if (++writeIndex_ >= maxFrames_) writeIndex_ = 0;
        }
    }

    static constexpr float kMaxDelayMs = 500.0f;

private:
    std::vector<float> buffer_;
    int sampleRate_ = 48000;
    int channelCount_ = 1;
    int maxFrames_ = 0;
    int writeIndex_ = 0;

    std::atomic<int> delayFrames_{1};
    std::atomic<float> delayMs_{150.0f};
    std::atomic<float> feedback_{0.3f};
};

#endif  // ECHOMIC_ECHO_EFFECT_H
