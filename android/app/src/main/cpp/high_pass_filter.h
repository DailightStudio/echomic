#ifndef ECHOMIC_HIGH_PASS_FILTER_H
#define ECHOMIC_HIGH_PASS_FILTER_H

#include <cmath>
#include <algorithm>

// 2-pole Butterworth high-pass filter (RBJ cookbook, Q = 0.7071).
// Removes low-frequency rumble / DC offset before downstream processing.
// Direct Form I, channel-outer / frame-inner loop with local state extraction.
class HighPassFilter {
public:
    void prepare(float sampleRate, float cutoffHz = 80.0f) {
        float w0 = 2.0f * M_PI * cutoffHz / sampleRate;
        float cosW = cosf(w0), sinW = sinf(w0);
        float alpha = sinW / (2.0f * 0.7071f);  // Butterworth Q
        float a0inv = 1.0f / (1.0f + alpha);
        b0_ =  (1.0f + cosW) * 0.5f * a0inv;
        b1_ = -(1.0f + cosW)        * a0inv;
        b2_ = b0_;
        a1_ = -2.0f * cosW          * a0inv;
        a2_ =  (1.0f - alpha)       * a0inv;
        for (int i = 0; i < 2; i++) x1_[i] = x2_[i] = y1_[i] = y2_[i] = 0;
        ready_ = true;
    }

    void process(float* samples, int frameCount, int channels) {
        if (!ready_) return;
        const int ch_count = std::min(channels, 2);
        for (int ch = 0; ch < ch_count; ch++) {
            float lx1 = x1_[ch], lx2 = x2_[ch], ly1 = y1_[ch], ly2 = y2_[ch];
            for (int f = 0; f < frameCount; f++) {
                float x0 = samples[f * channels + ch];
                float y0 = b0_ * x0 + b1_ * lx1 + b2_ * lx2 - a1_ * ly1 - a2_ * ly2;
                samples[f * channels + ch] = y0;
                lx2 = lx1; lx1 = x0; ly2 = ly1; ly1 = y0;
            }
            x1_[ch] = lx1; x2_[ch] = lx2; y1_[ch] = ly1; y2_[ch] = ly2;
        }
    }

private:
    float b0_{1}, b1_{0}, b2_{0}, a1_{0}, a2_{0};
    float x1_[2]{}, x2_[2]{}, y1_[2]{}, y2_[2]{};
    bool ready_{false};
};

#endif  // ECHOMIC_HIGH_PASS_FILTER_H
