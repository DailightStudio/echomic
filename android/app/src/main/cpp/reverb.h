#ifndef ECHOMIC_REVERB_H
#define ECHOMIC_REVERB_H

#include <atomic>
#include <cmath>
#include <vector>
#include <algorithm>
#include <numeric>

class ReverbEffect {
public:
    void prepare(int sampleRate) {
        float scale = static_cast<float>(sampleRate) / 44100.0f;
        // 44100Hz 기준 Freeverb 딜레이 (samples): 1116,1188,1277,1356 / 556,441
        static constexpr int kCombBase[4] = {1116, 1188, 1277, 1356};
        static constexpr int kApBase[2]   = {556,  441};
        for (int i = 0; i < 4; ++i) {
            combs_[i].prepare(static_cast<int>(kCombBase[i] * scale));
        }
        for (int i = 0; i < 2; ++i) {
            allpass_[i].prepare(static_cast<int>(kApBase[i] * scale));
        }
    }

    void reset() {
        for (auto& c : combs_)   c.reset();
        for (auto& a : allpass_) a.reset();
    }

    void setWet(float wet) {
        wet_.store(std::min(std::max(wet, 0.0f), 1.0f));
    }

    // in-place, interleaved. 리버브 wet/dry 믹스 적용.
    void process(float* samples, int numFrames, int numChannels) {
        const float wet = wet_.load();
        if (wet < 1e-4f) return;
        const float dry = 1.0f - wet;

        for (int f = 0; f < numFrames; ++f) {
            int base = f * numChannels;
            // 모노 다운믹스
            float mono = 0.0f;
            for (int ch = 0; ch < numChannels; ++ch) mono += samples[base + ch];
            mono /= static_cast<float>(numChannels);

            // 콤 필터 병렬
            float combOut = 0.0f;
            for (auto& c : combs_) combOut += c.process(mono);
            combOut *= 0.25f;  // 4개 평균

            // 올패스 직렬
            float out = combOut;
            for (auto& a : allpass_) out = a.process(out);

            // wet/dry 믹스
            for (int ch = 0; ch < numChannels; ++ch) {
                samples[base + ch] = samples[base + ch] * dry + out * wet;
            }
        }
    }

private:
    struct CombFilter {
        std::vector<float> buf;
        int writePos = 0;
        float filterStore = 0.0f;
        static constexpr float kFeedback = 0.84f;
        static constexpr float kDamp     = 0.20f;

        void prepare(int n) { buf.assign(n, 0.0f); writePos = 0; filterStore = 0.0f; }
        void reset()        { std::fill(buf.begin(), buf.end(), 0.0f); filterStore = 0.0f; }

        float process(float input) {
            float output = buf[writePos];
            filterStore  = output * (1.0f - kDamp) + filterStore * kDamp;
            buf[writePos] = input + filterStore * kFeedback;
            if (++writePos >= static_cast<int>(buf.size())) writePos = 0;
            return output;
        }
    };

    struct AllpassFilter {
        std::vector<float> buf;
        int writePos = 0;
        static constexpr float kFeedback = 0.5f;

        void prepare(int n) { buf.assign(n, 0.0f); writePos = 0; }
        void reset()        { std::fill(buf.begin(), buf.end(), 0.0f); }

        float process(float input) {
            float bufOut = buf[writePos];
            buf[writePos] = input + bufOut * kFeedback;
            if (++writePos >= static_cast<int>(buf.size())) writePos = 0;
            return bufOut - input;
        }
    };

    CombFilter   combs_[4];
    AllpassFilter allpass_[2];
    std::atomic<float> wet_{0.0f};
};

#endif  // ECHOMIC_REVERB_H
