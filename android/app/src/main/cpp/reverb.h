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

    // in-place, interleaved. Send 믹스: dry는 항상 unity로 유지하고 wet을
    // 그 위에 더한다 (크로스페이드 아님) -- 그래야 mix를 올려도 원래 목소리
    // 레벨이 줄지 않는다. 뒤이어 도는 최종 리미터(Compressor::limit())가
    // 합산으로 생기는 피크를 잡아준다.
    void process(float* samples, int numFrames, int numChannels) {
        const float wet = wet_.load();
        if (wet < 1e-4f) return;

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

            // Send: dry 그대로 + wet*mix
            for (int ch = 0; ch < numChannels; ++ch) {
                samples[base + ch] = samples[base + ch] + out * wet;
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
