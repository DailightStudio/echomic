#ifndef ECHOMIC_COMPRESSOR_H
#define ECHOMIC_COMPRESSOR_H

#include <atomic>
#include <cmath>
#include <algorithm>

class Compressor {
public:
    void prepare(int sampleRate) {
        sampleRate_ = sampleRate;
        float sr = static_cast<float>(sampleRate);
        attackCoeff_  = std::exp(-1.0f / (kAttackMs  * 0.001f * sr));
        releaseCoeff_ = std::exp(-1.0f / (kReleaseMs * 0.001f * sr));
        makeupLinear_ = std::pow(10.0f, kMakeupDb / 20.0f);
        limAttackCoeff_  = std::exp(-1.0f / (kLimAttackMs  * 0.001f * sr));
        limReleaseCoeff_ = std::exp(-1.0f / (kLimReleaseMs * 0.001f * sr));
        limThreshLinear_ = std::pow(10.0f, kLimThreshDb / 20.0f);
        envelope_    = 0.0f;
        limEnvelope_ = 0.0f;
    }

    void reset() {
        envelope_    = 0.0f;
        limEnvelope_ = 0.0f;
    }

    // Call BEFORE EchoEffect. Compresses and applies makeup gain in-place.
    void process(float* samples, int numFrames, int numChannels) {
        for (int f = 0; f < numFrames; ++f) {
            float peak = 0.0f;
            int base = f * numChannels;
            for (int ch = 0; ch < numChannels; ++ch)
                peak = std::max(peak, std::abs(samples[base + ch]));

            if (peak > envelope_)
                envelope_ = attackCoeff_  * envelope_ + (1.0f - attackCoeff_)  * peak;
            else
                envelope_ = releaseCoeff_ * envelope_ + (1.0f - releaseCoeff_) * peak;

            float gainDb = computeGain(envelope_);
            float linearGain = std::pow(10.0f, gainDb / 20.0f) * makeupLinear_;

            // Soft gate: -50 dBFS 이하 신호는 makeup gain을 줄여 노이즈 증폭 방지
            static constexpr float kGateThresh = 0.003162f;  // -50 dBFS
            float gateScale = (envelope_ > kGateThresh)
                ? 1.0f
                : (envelope_ / kGateThresh);  // 0..1 선형 페이드
            linearGain *= gateScale;

            for (int ch = 0; ch < numChannels; ++ch)
                samples[base + ch] *= linearGain;
        }
    }

    // Call AFTER EchoEffect. Hard-limits to prevent clipping.
    void limit(float* samples, int numSamples) {
        for (int i = 0; i < numSamples; ++i) {
            float abs = std::abs(samples[i]);
            if (abs > limEnvelope_)
                limEnvelope_ = limAttackCoeff_  * limEnvelope_ + (1.0f - limAttackCoeff_)  * abs;
            else
                limEnvelope_ = limReleaseCoeff_ * limEnvelope_ + (1.0f - limReleaseCoeff_) * abs;

            if (limEnvelope_ > limThreshLinear_)
                samples[i] *= limThreshLinear_ / limEnvelope_;
        }
    }

private:
    static constexpr float kThresholdDb = -24.0f;
    static constexpr float kRatio       =   4.0f;
    static constexpr float kKneeDb      =   6.0f;
    static constexpr float kAttackMs    =   3.0f;
    static constexpr float kReleaseMs   = 100.0f;
    static constexpr float kMakeupDb    =  12.0f;
    static constexpr float kLimThreshDb =  -1.0f;
    static constexpr float kLimAttackMs =   0.1f;
    static constexpr float kLimReleaseMs = 10.0f;

    float computeGain(float envelopeLinear) const {
        float xDb   = 20.0f * std::log10(envelopeLinear + 1e-8f);
        float overDb = xDb - kThresholdDb;
        if (2.0f * overDb < -kKneeDb)
            return 0.0f;
        if (2.0f * std::abs(overDb) <= kKneeDb) {
            float t = overDb + kKneeDb * 0.5f;
            return (1.0f / kRatio - 1.0f) * t * t / (2.0f * kKneeDb);
        }
        return (1.0f / kRatio - 1.0f) * overDb;
    }

    int   sampleRate_      = 48000;
    float attackCoeff_     = 0.0f;
    float releaseCoeff_    = 0.0f;
    float makeupLinear_    = 1.0f;
    float limAttackCoeff_  = 0.0f;
    float limReleaseCoeff_ = 0.0f;
    float limThreshLinear_ = 0.891f;
    float envelope_        = 0.0f;
    float limEnvelope_     = 0.0f;
};

#endif  // ECHOMIC_COMPRESSOR_H
