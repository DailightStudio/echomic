#ifndef ECHOMIC_FREQUENCY_SHIFTER_H
#define ECHOMIC_FREQUENCY_SHIFTER_H

#include <cmath>
#include <algorithm>
#include <atomic>

// SSB (single-sideband) frequency shifter via an IIR Hilbert transform pair.
//
// Each path is a cascade of 4 first-order allpass sections (Olli Niemitalo's
// polyphase design); path A carries one extra sample of delay so that the
// A/B phase difference is ~90 degrees across the whole audio band (not just
// near a single design frequency), which is what a 2-stage cascade could not
// achieve (that gave only 15-70 degrees -> audible 16 Hz tremolo instead of a
// clean frequency shift). Multiplying the resulting quadrature pair by a
// phasor that rotates at shiftHz translates the spectrum by a small offset,
// which breaks up acoustic feedback loops in live monitoring.
//
// Same math as ios/Runner/FrequencyShifter.swift — keep the two in lockstep. Channel-outer / frame-inner
// loop with local state extraction. The phasor is shared across channels:
// each channel restarts from the same phase, and the final advanced phase is
// stored once. Phasor is renormalized every 4096 frames to fight drift.
//
// Default OFF: the effect is opt-in (native default matches "off" until a
// setFrequencyShift(true) call arrives from Dart).
class FrequencyShifter {
public:
    std::atomic<bool> enabled{false};  // toggled by control thread, read by audio thread

    void prepare(float sampleRate, float shiftHz = 8.0f) {
        float sr = std::max(sampleRate, 8000.0f);
        float phi = 2.0f * M_PI * shiftHz / sr;
        cosDelta_ = cosf(phi);
        sinDelta_ = sinf(phi);
        reset();
    }

    void reset() {
        for (int ch = 0; ch < 2; ch++) {
            for (int k = 0; k < kStages; k++) {
                stageA_[ch][k] = Stage{};
                stageB_[ch][k] = Stage{};
            }
            aDelay_[ch] = 0.0f;
        }
        cosP_ = 1; sinP_ = 0; framesSinceNorm_ = 0;
    }

    void process(float* samples, int frameCount, int channels) {
        if (!enabled.load(std::memory_order_relaxed) || frameCount <= 0) return;
        const int chCount = std::min(channels, 2);
        const float cd = cosDelta_, sd = sinDelta_;
        const float startCp = cosP_, startSp = sinP_;
        float finalCp = cosP_, finalSp = sinP_;

        for (int ch = 0; ch < chCount; ch++) {
            Stage* stA = stageA_[ch];
            Stage* stB = stageB_[ch];
            float aDelay = aDelay_[ch];
            float cp = startCp, sp = startSp;

            for (int f = 0; f < frameCount; f++) {
                const int idx = f * channels + ch;
                const float x = samples[idx];

                float yAraw = x;
                for (int k = 0; k < kStages; k++) {
                    yAraw = allpassStep(stA[k], kCoeffA[k], yAraw);
                }
                // One-sample delay on the A path: this is what flattens the
                // A/B phase difference to a constant ~90 degrees across the
                // whole band instead of drifting with frequency (verified
                // numerically in frequency_shifter_check.py).
                const float yA = aDelay;
                aDelay = yAraw;

                float yB = x;
                for (int k = 0; k < kStages; k++) {
                    yB = allpassStep(stB[k], kCoeffB[k], yB);
                }

                samples[idx] = yA * cp - yB * sp;

                float nc = cp * cd - sp * sd;
                float ns = sp * cd + cp * sd;
                cp = nc; sp = ns;
            }

            aDelay_[ch] = aDelay;
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
    static constexpr int kStages = 4;
    // Olli Niemitalo's Hilbert-transformer allpass coefficients.
    static constexpr float kCoeffA[kStages] = {
        0.6923878f, 0.9360654322959f, 0.9882295226860f, 0.9987488452737f};
    static constexpr float kCoeffB[kStages] = {
        0.4021921162426f, 0.8561710882420f, 0.9722909545651f, 0.9952884791278f};

    // Direct-form state for one first-order allpass stage, realized as
    // y[n] = c^2 * (x[n] + y[n-2]) - x[n-2]  (a pair of identical first-order
    // allpass sections folded into a single 2-sample-delay recursion).
    struct Stage {
        float x1{0}, x2{0}, y1{0}, y2{0};
    };

    static inline float allpassStep(Stage& s, float c, float x0) {
        const float c2 = c * c;
        const float y0 = c2 * (x0 + s.y2) - s.x2;
        s.x2 = s.x1; s.x1 = x0;
        s.y2 = s.y1; s.y1 = y0;
        return y0;
    }

    Stage stageA_[2][kStages]{};
    Stage stageB_[2][kStages]{};
    float aDelay_[2]{};
    float cosP_{1}, sinP_{0};
    float cosDelta_{1}, sinDelta_{0};
    int framesSinceNorm_{0};
};

#endif  // ECHOMIC_FREQUENCY_SHIFTER_H
