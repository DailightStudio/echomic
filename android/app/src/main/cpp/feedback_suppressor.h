#ifndef ECHOMIC_FEEDBACK_SUPPRESSOR_H
#define ECHOMIC_FEEDBACK_SUPPRESSOR_H

#include <cmath>
#include <algorithm>
#include <cstring>

// FFT-based dynamic notch feedback suppressor.
//
// A mono sum of the input is fed into a ring buffer. Every kAnalysisInterval
// samples the most recent kFFTSize samples are Hann-windowed and transformed
// with a self-contained radix-2 Cooley-Tukey FFT. Spectral peaks that exceed
// the mean magnitude by kPeakThreshMult are treated as nascent feedback and a
// narrow RBJ notch biquad is armed at that frequency. Notches are refreshed
// while the peak persists and retired after kHoldCycles analysis cycles. The
// active notch bank is applied to every channel via Direct Form I.
//
// All working storage is pre-allocated as fixed arrays; process() performs no
// heap allocation. Port of the iOS Swift FeedbackSuppressor.
class FeedbackSuppressor {
public:
    static constexpr int   kFFTSize          = 1024;
    static constexpr int   kAnalysisInterval = 256;
    static constexpr int   kMaxNotches       = 12;
    static constexpr float kNotchQ           = 28.0f;
    static constexpr float kPeakThreshMult   = 5.0f;
    static constexpr int   kHoldCycles       = 100;
    static constexpr int   kMaxChannels      = 2;
    static constexpr float kMinNotchHz       = 100.0f;
    static constexpr float kMaxNotchFraction = 0.45f;
    static constexpr int   kBinDedupRadius   = 2;

    FeedbackSuppressor() {
        // Precompute Hann window.
        for (int i = 0; i < kFFTSize; i++)
            window_[i] = 0.5f * (1.0f - cosf(2.0f * (float)M_PI * i / kFFTSize));
        memset(ring_, 0, sizeof(ring_));
        memset(notches_, 0, sizeof(notches_));
        memset(x1_, 0, sizeof(x1_));
        memset(x2_, 0, sizeof(x2_));
        memset(y1_, 0, sizeof(y1_));
        memset(y2_, 0, sizeof(y2_));
    }

    void prepare(float sampleRate, int /*channelCount*/) {
        // Channel count is taken per-block from process(); the parameter is
        // kept for signature parity with the iOS implementation.
        sampleRate_ = (sampleRate > 0) ? sampleRate : 48000.0f;
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
        int   cyclesSinceRefresh{0};
        float b0{1}, b1{0}, b2{0}, a1{0}, a2{0};
    };

    float sampleRate_{48000};

    float window_[kFFTSize];
    float windowed_[kFFTSize];
    float re_[kFFTSize];
    float magnitudes_[kFFTSize / 2];

    float ring_[kFFTSize];
    int   ringWrite_{0};
    int   samplesSinceAnalysis_{0};

    Notch notches_[kMaxNotches];
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

        // Mean magnitude (skip DC bin 0).
        float mean = 0;
        for (int i = 1; i < half; i++) mean += magnitudes_[i];
        mean /= (half - 1);
        if (mean <= 0) return;
        float threshold = mean * kPeakThreshMult;

        int bin = minBin;
        while (bin <= maxBin) {
            float m = magnitudes_[bin];
            if (m > threshold && m > magnitudes_[bin - 1] && m >= magnitudes_[bin + 1]) {
                armNotch(bin);
                bin += kBinDedupRadius + 1;
            } else {
                bin++;
            }
        }
    }

    void armNotch(int bin) {
        // Refresh if an existing notch already covers this bin.
        for (int i = 0; i < kMaxNotches; i++) {
            if (notches_[i].active && std::abs(notches_[i].bin - bin) <= kBinDedupRadius) {
                notches_[i].cyclesSinceRefresh = 0;
                return;
            }
        }
        // Find a free slot.
        int slot = -1;
        for (int i = 0; i < kMaxNotches; i++) {
            if (!notches_[i].active) { slot = i; break; }
        }
        if (slot < 0) return;

        float freq = bin * (sampleRate_ / kFFTSize);
        setNotchCoeffs(slot, freq);
        notches_[slot].active = true;
        notches_[slot].bin = bin;
        notches_[slot].cyclesSinceRefresh = 0;
        for (int ch = 0; ch < kMaxChannels; ch++) {
            int s = slot * kMaxChannels + ch;
            x1_[s] = x2_[s] = y1_[s] = y2_[s] = 0;
        }
    }

    void ageNotches() {
        for (int i = 0; i < kMaxNotches; i++) {
            if (!notches_[i].active) continue;
            notches_[i].cyclesSinceRefresh++;
            if (notches_[i].cyclesSinceRefresh >= kHoldCycles)
                notches_[i].active = false;
        }
    }

    void setNotchCoeffs(int slot, float freq) {
        float f  = std::max(kMinNotchHz, std::min(freq, sampleRate_ * kMaxNotchFraction));
        float w0 = 2.0f * (float)M_PI * f / sampleRate_;
        float cosw0 = cosf(w0), sinw0 = sinf(w0);
        float alpha = sinw0 / (2.0f * kNotchQ);
        float a0inv = 1.0f / (1.0f + alpha);
        notches_[slot].b0 =  1.0f         * a0inv;
        notches_[slot].b1 = -2.0f * cosw0 * a0inv;
        notches_[slot].b2 =  1.0f         * a0inv;
        notches_[slot].a1 = -2.0f * cosw0 * a0inv;
        notches_[slot].a2 = (1.0f - alpha) * a0inv;
    }
};

#endif  // ECHOMIC_FEEDBACK_SUPPRESSOR_H
