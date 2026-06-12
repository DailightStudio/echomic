#ifndef ECHOMIC_NOISE_GATE_H
#define ECHOMIC_NOISE_GATE_H

#include <cmath>
#include <algorithm>
#include <cstdlib>

// Peak-envelope soft noise gate.
// 5 ms attack, 150 ms release. Below threshold the gain fades linearly toward
// zero (soft gate) instead of hard-cutting, which avoids chattering artifacts.
class NoiseGate {
public:
    void prepare(float sampleRate) {
        attackCoeff_  = expf(-1.0f / (0.005f * sampleRate));
        releaseCoeff_ = expf(-1.0f / (0.150f * sampleRate));
        envelope_ = 0;
    }

    void setThresholdDb(float db) {
        threshold_ = powf(10.0f, db / 20.0f);
    }

    void process(float* samples, int frameCount, int channels) {
        for (int f = 0; f < frameCount; f++) {
            int base = f * channels;
            float peak = 0;
            for (int ch = 0; ch < channels; ch++)
                peak = std::max(peak, std::abs(samples[base + ch]));

            if (peak > envelope_)
                envelope_ = attackCoeff_  * envelope_ + (1.0f - attackCoeff_)  * peak;
            else
                envelope_ = releaseCoeff_ * envelope_ + (1.0f - releaseCoeff_) * peak;

            float gain = (envelope_ >= threshold_)
                ? 1.0f
                : (envelope_ / (threshold_ + 1e-8f));

            for (int ch = 0; ch < channels; ch++)
                samples[base + ch] *= gain;
        }
    }

private:
    float threshold_{0.02f};
    float envelope_{0};
    float attackCoeff_{0.9f};
    float releaseCoeff_{0.9999f};
};

#endif  // ECHOMIC_NOISE_GATE_H
