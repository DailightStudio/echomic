#ifndef ECHOMIC_FEEDBACK_SUPPRESSOR_H
#define ECHOMIC_FEEDBACK_SUPPRESSOR_H

#include <cmath>
#include <algorithm>
#include <cstdlib>
#include <cstring>

// FFT-based dynamic notch feedback suppressor.
//
// A mono sum of the input is fed into a ring buffer. Every kAnalysisInterval
// samples the most recent kFFTSize samples are Hann-windowed and transformed
// with a self-contained radix-2 Cooley-Tukey FFT. Spectral peaks that exceed
// the median magnitude by kPeakThreshMult become howl *candidates*; a notch
// is only armed once a candidate also passes multi-criteria validation that
// separates feedback from voiced speech/music:
//   - IPMP: persists for kMinHitCount consecutive analysis cycles,
//   - growth: latest magnitude at/above the candidate's running average,
//   - PHPR: no comparable energy at the 2nd/3rd harmonic (voice has both).
// Notches are refreshed while the peak persists and retired after a
// time-based hold (kHoldSeconds). The active notch bank is applied to every
// channel via Direct Form I.
//
// All working storage is pre-allocated as fixed arrays; process() performs no
// heap allocation. Port of the iOS Swift FeedbackSuppressor.
class FeedbackSuppressor {
public:
    static constexpr int   kFFTSize          = 1024;
    static constexpr int   kAnalysisInterval = 256;
    static constexpr int   kMaxNotches       = 12;
    static constexpr float kPeakThreshMult   = 5.0f;
    static constexpr float kHoldSeconds      = 0.7f;
    static constexpr int   kMaxChannels      = 2;
    static constexpr int   kMaxCandidates    = 24;
    static constexpr int   kMinHitCount      = 6;     // IPMP: ~32 ms persistence
    static constexpr float kGrowthMinRatio   = 1.0f;  // latest >= running average
    static constexpr float kHarmonic2Ratio   = 0.6f;  // PHPR thresholds (power)
    static constexpr float kHarmonic3Ratio   = 0.4f;

    // Constant absolute notch bandwidth (Hz) -> Q varies with frequency, so
    // low howls get a proportionally wide notch and high howls stay surgical.
    static constexpr float kNotchBandwidthHz = 50.0f;
    static constexpr float kMinNotchQ        = 8.0f;
    static constexpr float kMaxNotchQ        = 60.0f;
    // Staged depth: a new notch starts as a gentle peaking cut and deepens on
    // every re-detection (1: -7 dB, 2: -14 dB, 3: full band-reject).
    static constexpr float kStage1GainDb     = -7.0f;
    static constexpr float kStage2GainDb     = -14.0f;
    static constexpr float kMinNotchHz       = 100.0f;
    static constexpr float kMaxNotchFraction = 0.45f;
    static constexpr int   kBinDedupRadius   = 2;

    FeedbackSuppressor() {
        // Precompute Hann window.
        for (int i = 0; i < kFFTSize; i++)
            window_[i] = 0.5f * (1.0f - cosf(2.0f * (float)M_PI * i / kFFTSize));
        memset(ring_, 0, sizeof(ring_));
        memset(notches_, 0, sizeof(notches_));
        memset(candidates_, 0, sizeof(candidates_));
        memset(x1_, 0, sizeof(x1_));
        memset(x2_, 0, sizeof(x2_));
        memset(y1_, 0, sizeof(y1_));
        memset(y2_, 0, sizeof(y2_));
    }

    void prepare(float sampleRate, int /*channelCount*/) {
        // Channel count is taken per-block from process(); the parameter is
        // kept for signature parity with the iOS implementation.
        sampleRate_ = (sampleRate > 0) ? sampleRate : 48000.0f;
        // Sample-rate independent hold: a notch is retired kHoldSeconds after
        // its peak was last seen, regardless of the analysis cadence.
        holdCycles_ = (int)(kHoldSeconds * sampleRate_ / kAnalysisInterval + 0.5f);
        reset();
    }

    void reset() {
        memset(ring_, 0, sizeof(ring_));
        ringWrite_ = 0;
        samplesSinceAnalysis_ = 0;
        for (int i = 0; i < kMaxNotches; i++) {
            notches_[i].active = false;
            notches_[i].cyclesSinceRefresh = 0;
        }
        memset(candidates_, 0, sizeof(candidates_));
        memset(x1_, 0, sizeof(x1_));
        memset(x2_, 0, sizeof(x2_));
        memset(y1_, 0, sizeof(y1_));
        memset(y2_, 0, sizeof(y2_));
    }

    void process(float* ptr, int frameCount, int channels) {
        if (frameCount <= 0 || channels <= 0) return;
        const int chCount = std::min(channels, kMaxChannels);
        const float invCh = 1.0f / channels;

        // 1. Feed mono-summed signal into the ring buffer; analyze periodically.
        for (int f = 0; f < frameCount; f++) {
            int base = f * channels;
            float mono = 0;
            for (int ch = 0; ch < channels; ch++) mono += ptr[base + ch];
            mono *= invCh;

            ring_[ringWrite_] = mono;
            ringWrite_++;
            if (ringWrite_ >= kFFTSize) ringWrite_ = 0;

            samplesSinceAnalysis_++;
            if (samplesSinceAnalysis_ >= kAnalysisInterval) {
                samplesSinceAnalysis_ = 0;
                analyze();
            }
        }

        // 2. Apply active notch bank (Direct Form I) to all channels.
        for (int n = 0; n < kMaxNotches; n++) {
            if (!notches_[n].active) continue;
            const float b0 = notches_[n].b0, b1 = notches_[n].b1, b2 = notches_[n].b2;
            const float a1 = notches_[n].a1, a2 = notches_[n].a2;

            for (int ch = 0; ch < chCount; ch++) {
                int s = n * kMaxChannels + ch;
                float lx1 = x1_[s], lx2 = x2_[s], ly1 = y1_[s], ly2 = y2_[s];
                for (int f = 0; f < frameCount; f++) {
                    int idx = f * channels + ch;
                    float x0 = ptr[idx];
                    float y0 = b0 * x0 + b1 * lx1 + b2 * lx2 - a1 * ly1 - a2 * ly2;
                    ptr[idx] = y0;
                    lx2 = lx1; lx1 = x0; ly2 = ly1; ly1 = y0;
                }
                x1_[s] = lx1; x2_[s] = lx2; y1_[s] = ly1; y2_[s] = ly2;
            }
        }
    }

private:
    struct Notch {
        bool  active{false};
        int   bin{0};
        float freq{0};            // tracked (smoothed) center frequency, Hz
        int   cyclesSinceRefresh{0};
        int   depthStage{0};      // 0=off, 1=-7dB, 2=-14dB, 3=full notch
        float b0{1}, b1{0}, b2{0}, a1{0}, a2{0};
    };

    // A spectral peak being tracked across analysis cycles before it is
    // allowed to arm a notch (IPMP / growth bookkeeping).
    struct Candidate {
        int   bin{0};
        int   hitCount{0};        // consecutive-detection streak
        float lastMagnitude{0};
        float magnitudeSum{0};    // running sum for the growth average
        bool  seenThisCycle{false};
    };

    float sampleRate_{48000};
    int   holdCycles_{131};       // recomputed in prepare()

    float window_[kFFTSize];
    float windowed_[kFFTSize];
    float re_[kFFTSize];
    float magnitudes_[kFFTSize / 2];

    float ring_[kFFTSize];
    int   ringWrite_{0};
    int   samplesSinceAnalysis_{0};

    Notch notches_[kMaxNotches];
    Candidate candidates_[kMaxCandidates];
    float x1_[kMaxNotches * kMaxChannels];
    float x2_[kMaxNotches * kMaxChannels];
    float y1_[kMaxNotches * kMaxChannels];
    float y2_[kMaxNotches * kMaxChannels];

    // ---- Iterative in-place Cooley-Tukey radix-2 FFT ----
    // Input: re[] (real signal), im[] (imaginary, pass as zeros for real FFT)
    // Both arrays must have 'n' elements; n must be a power of two.
    static void fft(float* re, float* im, int n) {
        // Bit-reversal permutation.
        for (int i = 1, j = 0; i < n; i++) {
            int bit = n >> 1;
            for (; j & bit; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) { std::swap(re[i], re[j]); std::swap(im[i], im[j]); }
        }
        // Cooley-Tukey butterfly.
        for (int len = 2; len <= n; len <<= 1) {
            float ang = -2.0f * (float)M_PI / len;
            float wRe = cosf(ang), wIm = sinf(ang);
            for (int i = 0; i < n; i += len) {
                float curRe = 1.0f, curIm = 0.0f;
                for (int j = 0; j < len / 2; j++) {
                    float uRe = re[i + j], uIm = im[i + j];
                    float vRe = re[i + j + len / 2] * curRe - im[i + j + len / 2] * curIm;
                    float vIm = re[i + j + len / 2] * curIm + im[i + j + len / 2] * curRe;
                    re[i + j] = uRe + vRe; im[i + j] = uIm + vIm;
                    re[i + j + len / 2] = uRe - vRe; im[i + j + len / 2] = uIm - vIm;
                    float nc = curRe * wRe - curIm * wIm;
                    float ns = curRe * wIm + curIm * wRe;
                    curRe = nc; curIm = ns;
                }
            }
        }
    }

    void analyze() {
        const int half = kFFTSize / 2;
        // Copy ring buffer in chronological order, apply Hann window.
        int start = ringWrite_;
        for (int i = 0; i < kFFTSize; i++) {
            int r = (start + i) % kFFTSize;
            windowed_[i] = ring_[r] * window_[i];
        }

        // Pack into the full-size complex array and run the FFT. The imaginary
        // part is a local stack array (zero-initialized real input).
        float im_full[kFFTSize];
        for (int i = 0; i < kFFTSize; i++) { re_[i] = windowed_[i]; im_full[i] = 0; }
        fft(re_, im_full, kFFTSize);

        // Magnitude-squared spectrum (bins 0..half-1).
        for (int i = 0; i < half; i++)
            magnitudes_[i] = re_[i] * re_[i] + im_full[i] * im_full[i];

        detectAndArm(half);
        ageNotches();
    }

    void detectAndArm(int half) {
        const float binHz = sampleRate_ / kFFTSize;
        int minBin = std::max(1, (int)(kMinNotchHz / binHz + 0.5f));
        float maxHz = sampleRate_ * kMaxNotchFraction;
        int maxBin  = std::min(half - 2, (int)(maxHz / binHz + 0.5f));
        if (minBin > maxBin) return;

        for (int i = 0; i < kMaxCandidates; i++)
            candidates_[i].seenThisCycle = false;

        // Median-based threshold: unlike the mean, the median is not inflated
        // by a few strong tonal peaks, so loud howls cannot mask quieter ones.
        float median = computeMedian(half);
        float threshold = std::max(median * kPeakThreshMult, 1e-6f);

        int bin = minBin;
        while (bin <= maxBin) {
            float m = magnitudes_[bin];
            if (m > threshold && m > magnitudes_[bin - 1] && m >= magnitudes_[bin + 1]) {
                if (isRealHowl(bin, half)) armNotch(bin);
                bin += kBinDedupRadius + 1;
            } else {
                bin++;
            }
        }

        // Candidates not re-detected this cycle lose their streak: howling is
        // sustained, so a single miss resets the persistence counter (IPMP).
        for (int i = 0; i < kMaxCandidates; i++) {
            if (!candidates_[i].seenThisCycle) candidates_[i].hitCount = 0;
        }
    }

    // Median of magnitudes_[1..half-1] (DC excluded) via nth_element on a
    // stack scratch copy. O(n) average; no heap allocation.
    float computeMedian(int half) {
        const int count = half - 1;
        if (count <= 0) return 0;
        float scratch[kFFTSize / 2];
        std::copy(magnitudes_ + 1, magnitudes_ + half, scratch);
        std::nth_element(scratch, scratch + count / 2, scratch + count);
        return scratch[count / 2];
    }

    // Multi-criteria validation that separates feedback from voiced content.
    bool isRealHowl(int bin, int half) {
        Candidate& c = candidateForBin(bin);
        c.seenThisCycle = true;
        c.bin = bin;
        c.hitCount++;
        c.lastMagnitude = magnitudes_[bin];
        c.magnitudeSum += magnitudes_[bin];
        if (c.hitCount >= 64) {  // keep the running average finite on long howls
            c.hitCount /= 2;
            c.magnitudeSum *= 0.5f;
        }

        // IPMP: must persist for kMinHitCount consecutive analysis cycles.
        if (c.hitCount < kMinHitCount) return false;

        // Growth: feedback builds up, so the latest magnitude must sit at or
        // above the candidate's running average (transient speech peaks decay).
        float avg = c.magnitudeSum / c.hitCount;
        if (c.lastMagnitude < avg * kGrowthMinRatio) return false;

        // PHPR: voiced speech carries strong 2nd/3rd harmonics; a howl is a
        // near-pure sinusoid. Comparable energy at 2f or 3f -> treat as voice.
        int bin2 = bin * 2;
        int bin3 = bin * 3;
        if (bin2 + 1 < half) {
            float h2 = std::max(magnitudes_[bin2 - 1],
                                std::max(magnitudes_[bin2], magnitudes_[bin2 + 1]));
            if (h2 > c.lastMagnitude * kHarmonic2Ratio) return false;
        }
        if (bin3 + 1 < half) {
            float h3 = std::max(magnitudes_[bin3 - 1],
                                std::max(magnitudes_[bin3], magnitudes_[bin3 + 1]));
            if (h3 > c.lastMagnitude * kHarmonic3Ratio) return false;
        }
        return true;
    }

    // Find the candidate tracking this bin (within the dedup radius) or claim
    // a slot for a fresh streak, evicting the weakest streak when full.
    Candidate& candidateForBin(int bin) {
        int freeSlot = -1, weakest = 0;
        for (int i = 0; i < kMaxCandidates; i++) {
            if (candidates_[i].hitCount > 0) {
                if (std::abs(candidates_[i].bin - bin) <= kBinDedupRadius)
                    return candidates_[i];
                if (candidates_[i].hitCount < candidates_[weakest].hitCount)
                    weakest = i;
            } else if (freeSlot < 0) {
                freeSlot = i;
            }
        }
        int slot = (freeSlot >= 0) ? freeSlot : weakest;
        candidates_[slot] = Candidate{};
        candidates_[slot].bin = bin;
        return candidates_[slot];
    }

    void armNotch(int bin) {
        // Refresh (and re-center) if an existing notch already covers this bin.
        for (int i = 0; i < kMaxNotches; i++) {
            if (notches_[i].active && std::abs(notches_[i].bin - bin) <= kBinDedupRadius) {
                refreshNotch(i, bin);
                return;
            }
        }
        // Find a free slot.
        int slot = -1;
        for (int i = 0; i < kMaxNotches; i++) {
            if (!notches_[i].active) { slot = i; break; }
        }
        if (slot < 0) return;

        // New notch enters softly (stage 1) and only deepens if the howl is
        // re-detected, limiting damage when the detector is briefly fooled.
        float freq = interpolateFrequency(bin);
        setNotchCoeffs(slot, freq, 1);
        notches_[slot].active = true;
        notches_[slot].bin = bin;
        notches_[slot].freq = freq;
        notches_[slot].cyclesSinceRefresh = 0;
        for (int ch = 0; ch < kMaxChannels; ch++) {
            int s = slot * kMaxChannels + ch;
            x1_[s] = x2_[s] = y1_[s] = y2_[s] = 0;
        }
    }

    // Re-detected peak on an active notch: re-estimate the precise frequency
    // and ease the notch toward it (howls drift as the room/mic geometry
    // changes), keeping the filter state intact to avoid transients.
    void refreshNotch(int slot, int bin) {
        float newFreq = interpolateFrequency(bin);
        float smoothed = 0.7f * notches_[slot].freq + 0.3f * newFreq;
        // Re-detection while already notched -> the cut is not deep enough
        // yet; step the depth up one stage (capped at full notch).
        int stage = std::min(notches_[slot].depthStage + 1, 3);
        setNotchCoeffs(slot, smoothed, stage);
        notches_[slot].freq = smoothed;
        notches_[slot].bin = bin;
        notches_[slot].cyclesSinceRefresh = 0;
    }

    // Sub-bin peak frequency estimate: fit a parabola through the
    // log-magnitudes at bin-1/bin/bin+1 and return its vertex. Cuts the worst
    // case center error from binHz/2 (~23 Hz @ 48 kHz) to a few Hz, which
    // matters for the narrow notch to actually sit on the howl.
    float interpolateFrequency(int bin) {
        const float binHz = sampleRate_ / kFFTSize;
        if (bin <= 0 || bin >= kFFTSize / 2 - 1) return bin * binHz;

        float m0 = magnitudes_[bin - 1];
        float m1 = magnitudes_[bin];
        float m2 = magnitudes_[bin + 1];
        if (m0 <= 0 || m1 <= 0 || m2 <= 0) return bin * binHz;

        float lm0 = logf(m0), lm1 = logf(m1), lm2 = logf(m2);
        float denom = lm0 - 2.0f * lm1 + lm2;
        if (std::fabs(denom) < 1e-12f) return bin * binHz;

        float fracBin = (lm0 - lm2) / (2.0f * denom);
        fracBin = std::max(-0.5f, std::min(0.5f, fracBin));
        return (bin + fracBin) * binHz;
    }

    // Hold expiry releases the notch gradually: instead of jumping from a
    // full notch straight to 0 dB (click + instant re-howl), the depth steps
    // down one stage (3->2->1->0) per hold period, deactivating only once
    // stage 0 is reached. A re-detection during the ramp steps it back up.
    void ageNotches() {
        for (int i = 0; i < kMaxNotches; i++) {
            if (!notches_[i].active) continue;
            notches_[i].cyclesSinceRefresh++;
            if (notches_[i].cyclesSinceRefresh < holdCycles_) continue;
            if (notches_[i].depthStage > 0) {
                notches_[i].depthStage--;
                setNotchCoeffs(i, notches_[i].freq, notches_[i].depthStage);
                notches_[i].cyclesSinceRefresh = 0;
            } else {
                notches_[i].active = false;
            }
        }
    }

    // Stage 3 is the classic RBJ band-reject notch. Stages 1-2 use the RBJ
    // peaking-cut form instead of scaling the notch's b coefficients (which
    // would attenuate the whole band, not just the notch center).
    void setNotchCoeffs(int slot, float freq, int depthStage = 3) {
        float f  = std::max(kMinNotchHz, std::min(freq, sampleRate_ * kMaxNotchFraction));
        float w0 = 2.0f * (float)M_PI * f / sampleRate_;
        float cosw0 = cosf(w0), sinw0 = sinf(w0);

        // Constant absolute bandwidth -> frequency-proportional Q.
        float Q = std::max(kMinNotchQ, std::min(f / kNotchBandwidthHz, kMaxNotchQ));
        float alpha = sinw0 / (2.0f * Q);

        Notch& n = notches_[slot];
        n.depthStage = std::max(0, std::min(depthStage, 3));
        if (n.depthStage >= 3) {
            // Full RBJ band-reject notch.
            float a0inv = 1.0f / (1.0f + alpha);
            n.b0 =  1.0f         * a0inv;
            n.b1 = -2.0f * cosw0 * a0inv;
            n.b2 =  1.0f         * a0inv;
            n.a1 = -2.0f * cosw0 * a0inv;
            n.a2 = (1.0f - alpha) * a0inv;
        } else if (n.depthStage >= 1) {
            // RBJ peaking EQ cut at the stage gain.
            float gainDb = (n.depthStage == 1) ? kStage1GainDb : kStage2GainDb;
            float A = powf(10.0f, gainDb / 40.0f);
            float a0inv = 1.0f / (1.0f + alpha / A);
            n.b0 = (1.0f + alpha * A) * a0inv;
            n.b1 = -2.0f * cosw0      * a0inv;
            n.b2 = (1.0f - alpha * A) * a0inv;
            n.a1 = -2.0f * cosw0      * a0inv;
            n.a2 = (1.0f - alpha / A) * a0inv;
        } else {
            // Stage 0: transparent pass-through.
            n.b0 = 1.0f; n.b1 = 0.0f; n.b2 = 0.0f;
            n.a1 = 0.0f; n.a2 = 0.0f;
        }
    }
};

#endif  // ECHOMIC_FEEDBACK_SUPPRESSOR_H
