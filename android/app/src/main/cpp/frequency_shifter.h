#ifndef ECHOMIC_FREQUENCY_SHIFTER_H
#define ECHOMIC_FREQUENCY_SHIFTER_H

#include <cmath>
#include <algorithm>
#include <atomic>

// SSB (single-sideband) frequency shifter via an IIR Hilbert transform pair.
// The two all-pass cascades (path A / path B) maintain a ~90-degree phase
// difference across the audio band; multiplying by a complex phasor that
// rotates at shiftHz translates the whole spectrum by a small offset, which
// breaks up acoustic feedback loops in live monitoring.
//
// Direct port from the iOS Swift implementation. Channel-outer / frame-inner
// loop with local state extraction. The phasor is shared across channels:
// each channel restarts from the same phase, and the final advanced phase is
// stored once. Phasor is renormalized every 4096 frames to fight drift.
class FrequencyShifter {
public:
    std::atomic<bool> enabled{true};  // toggled by control thread, read by audio thread

    void prepare(float sampleRate, float shiftHz = 8.0f) {
        float sr = std::max(sampleRate, 8000.0f);
        float phi = 2.0f * M_PI * shiftHz / sr;
        cosDelta_ = cosf(phi);
        sinDelta_ = sinf(phi);
        reset();
    }

    void reset() {
        for (int i = 0; i < 2; i++) {
            xA0_[i] = yA0_[i] = xA1_[i] = yA1_[i] = 0;
            xB0_[i] = yB0_[i] = xB1_[i] = yB1_[i] = 0;
        }
        cosP_ = 1; sinP_ = 0; framesSinceNorm_ = 0;
    }

    void process(float* samples, int frameCount, int channels) {
        if (!enabled.load(std::memory_order_relaxed) || frameCount <= 0) return;
        const int chCount = std::min(channels, 2);
        static constexpr float a0c = 0.4021921162f, a1c = 0.8561710882f;
        static constexpr float b0c = 0.6923878f,    b1c = 0.9360654f;
        const float cd = cosDelta_, sd = sinDelta_;
        const float startCp = cosP_, startSp = sinP_;
        float finalCp = cosP_, finalSp = sinP_;

        for (int ch = 0; ch < chCount; ch++) {
            float lxA0 = xA0_[ch], lyA0 = yA0_[ch];
            float lxA1 = xA1_[ch], lyA1 = yA1_[ch];
            float lxB0 = xB0_[ch], lyB0 = yB0_[ch];
            float lxB1 = xB1_[ch], lyB1 = yB1_[ch];
            float cp = startCp, sp = startSp;

            for (int f = 0; f < frameCount; f++) {
                const int idx = f * channels + ch;
                const float x = samples[idx];

                float outA0 = -a0c * x     + lxA0 + a0c * lyA0;
                float outA1 = -a1c * outA0 + lxA1 + a1c * lyA1;
                lxA0 = x;     lyA0 = outA0;
                lxA1 = outA0; lyA1 = outA1;

                float outB0 = -b0c * x     + lxB0 + b0c * lyB0;
                float outB1 = -b1c * outB0 + lxB1 + b1c * lyB1;
                lxB0 = x;     lyB0 = outB0;
                lxB1 = outB0; lyB1 = outB1;

                samples[idx] = outA1 * cp - outB1 * sp;

                float nc = cp * cd - sp * sd;
                float ns = sp * cd + cp * sd;
                cp = nc; sp = ns;
            }

            xA0_[ch] = lxA0; yA0_[ch] = lyA0;
            xA1_[ch] = lxA1; yA1_[ch] = lyA1;
            xB0_[ch] = lxB0; yB0_[ch] = lyB0;
            xB1_[ch] = lxB1; yB1_[ch] = lyB1;
            finalCp = cp; finalSp = sp;
        }

        framesSinceNorm_ += frameCount;
        if (framesSinceNorm_ >= 4096) {
            float mag = sqrtf(finalCp * finalCp + finalSp * finalSp);
            if (mag > 0) { finalCp /= mag; finalSp /= mag; }
            framesSinceNorm_ = 0;
        }
        cosP_ = finalCp; sinP_ = finalSp;
    }

private:
    float xA0_[2]{}, yA0_[2]{};
    float xA1_[2]{}, yA1_[2]{};
    float xB0_[2]{}, yB0_[2]{};
    float xB1_[2]{}, yB1_[2]{};
    float cosP_{1}, sinP_{0};
    float cosDelta_{1}, sinDelta_{0};
    int framesSinceNorm_{0};
};

#endif  // ECHOMIC_FREQUENCY_SHIFTER_H
