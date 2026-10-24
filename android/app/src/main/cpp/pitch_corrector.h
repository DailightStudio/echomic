#ifndef ECHOMIC_PITCH_CORRECTOR_H
#define ECHOMIC_PITCH_CORRECTOR_H

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <vector>

// Momentary auto-tune: YIN pitch detection + pitch-synchronous grain shifter.
//
// Detection (YinDetector): YIN (de Cheveigné & Kawahara 2002) on a 2x
// decimated copy of channel 0 — window ~21 ms, hop ~5.3 ms, 80..1000 Hz,
// CMNDF threshold 0.15, parabolic refinement — then the lag is refined on the
// full-rate signal around 2x the decimated lag. Decimation cuts the
// difference-function cost ~4x (armeabi-v7a budget).
//
// Shifting: Lent's method (CMJ 13(4), 1989): Hann grains two input periods
// long are read from a delay line and retriggered every *output* period
// (input period / ratio). Each grain's input start advances by exactly one
// input period, so consecutive grains are phase-aligned; when the read delay
// drifts outside [0, P) it jumps by one whole period (repeat/skip a cycle).
// Latency < 1 input period. Output is normalized by the running window sum.
//
// Retune: ratio = nearest allowed scale note / detected pitch, smoothed by a
// one-pole ("retune speed"); 1.0 when unvoiced. setHold() ramps a wet gain
// over kFadeMs; while the wet gain is 0 and hold is off, process() only
// records history (no analysis, no grains) and leaves the buffer untouched.
//
// Realtime: all buffers are allocated in prepare(); process() does no
// allocation, locking or logging. Control-thread setters are atomics.

class YinDetector {
public:
    void prepare(float sampleRate) {
        sr_ = sampleRate < 8000.f ? 8000.f : sampleRate;
        const float sd = sr_ * 0.5f;                       // decimated rate
        minLag_ = (int)std::floor(sd / 1000.f);
        if (minLag_ < 2) minLag_ = 2;
        maxLag_ = (int)std::ceil(sd / 80.f);
        win_ = (int)std::lround(sd * 0.021333f);           // 512 @ 48 kHz
        if (win_ < maxLag_) win_ = maxLag_;
        hop_ = (int)std::lround(sr_ * 0.0053333f);         // 256 @ 48 kHz
        if (hop_ < 1) hop_ = 1;
        decSize_ = pow2(win_ + maxLag_ + 2);
        fullSize_ = pow2(2 * win_ + 2 * maxLag_ + 8);
        dec_.assign(decSize_, 0.f);
        full_.assign(fullSize_, 0.f);
        lin_.assign(win_ + maxLag_ + 2, 0.f);
        linFull_.assign(2 * win_ + 2 * maxLag_ + 8, 0.f);
        diff_.assign(maxLag_ + 2, 0.f);
        cmnd_.assign(maxLag_ + 2, 0.f);
        // 2nd-order Butterworth low-pass before decimation.
        const float fc = std::fmin(2000.f, 0.2f * sr_);
        const float k = std::tan((float)M_PI * fc / sr_), q = 0.7071f;
        const float norm = 1.f / (1.f + k / q + k * k);
        b0_ = k * k * norm; b1_ = 2.f * b0_; b2_ = b0_;
        a1_ = 2.f * (k * k - 1.f) * norm; a2_ = (1.f - k / q + k * k) * norm;
        reset();
    }

    void reset() {
        std::fill(dec_.begin(), dec_.end(), 0.f);
        std::fill(full_.begin(), full_.end(), 0.f);
        fw_ = dw_ = 0; odd_ = false; hopCount_ = 0;
        z1_ = z2_ = 0.f;
        period_ = 0.f; voiced_ = false;
    }

    // Store one full-rate sample (cheap; call every sample, even when idle).
    inline void push(float x) {
        full_[fw_] = x; fw_ = (fw_ + 1) & (fullSize_ - 1);
        const float y = b0_ * x + z1_;
        z1_ = b1_ * x - a1_ * y + z2_;
        z2_ = b2_ * x - a2_ * y;
        odd_ = !odd_;
        if (odd_) { dec_[dw_] = y; dw_ = (dw_ + 1) & (decSize_ - 1); }
    }

    // True once per hop.
    inline bool tick() {
        if (++hopCount_ >= hop_) { hopCount_ = 0; return true; }
        return false;
    }
    void resetHop() { hopCount_ = 0; }

    // Estimate the period of the most recent window.
    void analyze() {
        voiced_ = false;
        const int n = win_ + maxLag_;
        const int dmask = decSize_ - 1;
        int r = (dw_ - n) & dmask;
        for (int i = 0; i < n; ++i, r = (r + 1) & dmask) lin_[i] = dec_[r];

        double energy = 0;
        for (int j = 0; j < n; ++j) energy += (double)lin_[j] * lin_[j];
        if (energy / n < kSilence) return;

        // Difference function + cumulative mean normalized difference.
        cmnd_[0] = 1.f;
        double run = 0;
        for (int tau = 1; tau <= maxLag_; ++tau) {
            const float* a = lin_.data();
            const float* b = lin_.data() + tau;
            float s = 0;
            for (int j = 0; j < win_; ++j) { const float d = a[j] - b[j]; s += d * d; }
            diff_[tau] = s;
            run += s;
            cmnd_[tau] = run > 0 ? (float)(s * tau / run) : 1.f;
        }
        int best = -1;
        for (int tau = minLag_; tau <= maxLag_; ++tau) {
            if (cmnd_[tau] < kThreshold) {
                while (tau + 1 <= maxLag_ && cmnd_[tau + 1] < cmnd_[tau]) ++tau;
                best = tau;
                break;
            }
        }
        if (best < 0) return;

        float lagDec = (float)best;
        if (best > 1 && best < maxLag_) {
            const float y0 = diff_[best - 1], y1 = diff_[best], y2 = diff_[best + 1];
            const float den = y0 - 2.f * y1 + y2;
            if (den > 1e-12f) lagDec += 0.5f * (y0 - y2) / den;
        }

        // Full-rate refinement around 2x the decimated lag.
        const int wf = 2 * win_;
        const int c = (int)std::lround(2.f * lagDec);
        const int lo = c - 3 < 2 ? 2 : c - 3, hi = c + 3;
        const int nf = wf + hi + 1;
        const int fmask = fullSize_ - 1;
        r = (fw_ - nf) & fmask;
        for (int i = 0; i < nf; ++i, r = (r + 1) & fmask) linFull_[i] = full_[r];
        float dv[8];
        int bi = lo;
        for (int tau = lo; tau <= hi; ++tau) {
            const float* a = linFull_.data();
            const float* b = linFull_.data() + tau;
            float s = 0;
            for (int j = 0; j < wf; ++j) { const float d = a[j] - b[j]; s += d * d; }
            dv[tau - lo] = s;
            if (s < dv[bi - lo]) bi = tau;
        }
        float lag = (float)bi;
        if (bi > lo && bi < hi) {
            const float y0 = dv[bi - lo - 1], y1 = dv[bi - lo], y2 = dv[bi - lo + 1];
            const float den = y0 - 2.f * y1 + y2;
            if (den > 1e-12f) lag += 0.5f * (y0 - y2) / den;
        } else {
            lag = 2.f * lagDec;   // refinement hit its edge: trust the coarse lag
        }
        period_ = lag;
        voiced_ = true;
    }

    bool voiced() const { return voiced_; }
    float period() const { return period_; }       // full-rate samples
    float hz() const { return voiced_ && period_ > 0 ? sr_ / period_ : 0.f; }
    int hop() const { return hop_; }
    int maxPeriod() const { return 2 * maxLag_ + 4; }

private:
    static int pow2(int n) { int p = 1; while (p < n) p <<= 1; return p; }
    static constexpr float kThreshold = 0.15f;
    static constexpr double kSilence = 1e-7;       // ~ -70 dBFS mean square

    float sr_ = 48000.f;
    int minLag_ = 24, maxLag_ = 300, win_ = 512, hop_ = 256;
    int decSize_ = 1024, fullSize_ = 2048;
    std::vector<float> dec_, full_, lin_, linFull_, diff_, cmnd_;
    int fw_ = 0, dw_ = 0, hopCount_ = 0;
    bool odd_ = false;
    float b0_ = 1, b1_ = 0, b2_ = 0, a1_ = 0, a2_ = 0, z1_ = 0, z2_ = 0;
    float period_ = 0.f;
    bool voiced_ = false;
};

class PitchCorrector {
public:
    void prepare(float sampleRate, int channels) {
        sr_ = sampleRate < 8000.f ? 8000.f : sampleRate;
        channels_ = channels < 1 ? 1 : (channels > 2 ? 2 : channels);
        det_.prepare(sr_);
        int need = 4 * det_.maxPeriod() + 16;
        dlSize_ = 1; while (dlSize_ < need) dlSize_ <<= 1;   // 4096 @ 48 kHz
        for (int c = 0; c < 2; ++c) dl_[c].assign(dlSize_, 0.f);
        for (int i = 0; i <= kTable; ++i)
            hann_[i] = 0.5f - 0.5f * std::cos(2.f * (float)M_PI * i / kTable);
        fadeStep_ = 1.f / (kFadeMs * 0.001f * sr_);
        defaultPeriod_ = sr_ / 200.f;
        reset();
    }

    void reset() {
        det_.reset();
        for (int c = 0; c < 2; ++c) std::fill(dl_[c].begin(), dl_[c].end(), 0.f);
        w_ = 0;
        wet_ = 0.f; active_ = false;
        resetShifter();
        lastHz_.store(0.f); lastRatio_.store(1.f);
    }

    void setHold(bool on) { hold_.store(on, std::memory_order_relaxed); }
    void setScaleMask(uint16_t mask12 = 0xFFF) { mask_.store(mask12 & 0xFFF, std::memory_order_relaxed); }
    void setRetuneMs(float ms) { retuneMs_.store(ms < 0.f ? 0.f : ms, std::memory_order_relaxed); }

    float lastDetectedHz() const { return lastHz_.load(std::memory_order_relaxed); }
    float lastRatio() const { return lastRatio_.load(std::memory_order_relaxed); }

    void process(float* buf, int frames, int channels) {
        if (frames <= 0 || channels <= 0) return;
        const bool hold = hold_.load(std::memory_order_relaxed);
        const int nch = channels < channels_ ? channels : channels_;
        const int mask = dlSize_ - 1;

        if (!active_ && !hold) {               // bypass: keep history only
            for (int f = 0; f < frames; ++f) {
                const float* fr = buf + f * channels;
                for (int c = 0; c < nch; ++c) dl_[c][w_] = fr[c];
                w_ = (w_ + 1) & mask;
                det_.push(fr[0]);
            }
            return;
        }
        if (!active_) {                        // press: start fresh
            active_ = true;
            resetShifter();
            det_.analyze();
            det_.resetHop();
            updateTarget();
            ratio_ = targetRatio_;
        }

        const float rms = retuneMs_.load(std::memory_order_relaxed);
        const float a = rms <= 0.f ? 1.f : 1.f - std::exp(-1000.f / (rms * sr_));
        const float wetTarget = hold ? 1.f : 0.f;

        for (int f = 0; f < frames; ++f) {
            float* fr = buf + f * channels;
            for (int c = 0; c < nch; ++c) dl_[c][w_] = fr[c];
            det_.push(fr[0]);
            if (det_.tick()) { det_.analyze(); updateTarget(); }

            ratio_ += (targetRatio_ - ratio_) * a;

            // Trigger grains on the output-period clock.
            untilNext_ -= 1.f;
            while (untilNext_ <= 0.f) startGrain();

            // Sum active grains.
            float acc[2] = {0.f, 0.f};
            float wsum = 0.f;
            int g = 0;
            while (g < nGrains_) {
                Grain& gr = grains_[g];
                const float pos = gr.elapsed * gr.invLen * kTable;
                const int pi = (int)pos;
                const float pf = pos - pi;
                const float win = hann_[pi] + (hann_[pi + 1] - hann_[pi]) * pf;
                const float rp = (float)w_ - gr.delay;
                const float rfl = std::floor(rp);
                const int i0 = (int)rfl & mask, i1 = (i0 + 1) & mask;
                const float rf = rp - rfl;
                for (int c = 0; c < nch; ++c) {
                    const float* d = dl_[c].data();
                    acc[c] += win * (d[i0] + (d[i1] - d[i0]) * rf);
                }
                wsum += win;
                gr.elapsed += 1.f;
                if (gr.elapsed >= gr.len) grains_[g] = grains_[--nGrains_];
                else ++g;
            }
            const float norm = 1.f / (wsum > kMinWsum ? wsum : kMinWsum);

            if (wet_ < wetTarget) { wet_ += fadeStep_; if (wet_ > 1.f) wet_ = 1.f; }
            else if (wet_ > wetTarget) { wet_ -= fadeStep_; if (wet_ < 0.f) wet_ = 0.f; }

            for (int c = 0; c < nch; ++c) fr[c] += (acc[c] * norm - fr[c]) * wet_;
            w_ = (w_ + 1) & mask;
        }

        if (wet_ <= 0.f && !hold) active_ = false;
    }

private:
    struct Grain { float delay, elapsed, len, invLen; };
    static constexpr int kMaxGrains = 8;
    static constexpr int kTable = 1024;
    static constexpr float kFadeMs = 20.f;
    static constexpr float kMinWsum = 0.1f;

    void resetShifter() {
        nGrains_ = 0;
        untilNext_ = 1.f;                      // first grain on the next sample
        dNext_ = 0.f;
        period_ = defaultPeriod_;
        targetRatio_ = ratio_ = 1.f;
    }

    void updateTarget() {
        if (!det_.voiced()) {
            targetRatio_ = 1.f;
            lastHz_.store(0.f, std::memory_order_relaxed);
            lastRatio_.store(1.f, std::memory_order_relaxed);
            return;
        }
        const float p = det_.period();
        const float hz = sr_ / p;
        period_ = p;
        targetRatio_ = snapRatio(hz);
        lastHz_.store(hz, std::memory_order_relaxed);
        lastRatio_.store(targetRatio_, std::memory_order_relaxed);
    }

    // Ratio that moves hz to the nearest allowed pitch class.
    float snapRatio(float hz) const {
        const uint16_t m = mask_.load(std::memory_order_relaxed);
        if (m == 0) return 1.f;
        const float midi = 69.f + 12.f * std::log2(hz / 440.f);
        const int base = (int)std::lround(midi);
        float best = 0.f, bestDist = 1e9f;
        for (int k = -6; k <= 6; ++k) {
            const int n = base + k;
            const int pc = ((n % 12) + 12) % 12;
            if (!(m & (1u << pc))) continue;
            const float dist = std::fabs((float)n - midi);
            if (dist < bestDist) { bestDist = dist; best = (float)n; }
        }
        return std::exp2((best - midi) / 12.f);
    }

    void startGrain() {
        const float p = period_;
        float d = dNext_;
        while (d < 0.f) d += p;
        while (d >= p) d -= p;
        if (nGrains_ == kMaxGrains) {          // drop the oldest
            int oldest = 0;
            for (int i = 1; i < nGrains_; ++i)
                if (grains_[i].elapsed > grains_[oldest].elapsed) oldest = i;
            grains_[oldest] = grains_[--nGrains_];
        }
        Grain& g = grains_[nGrains_++];
        g.len = 2.f * p;
        g.invLen = 1.f / g.len;
        g.elapsed = -untilNext_;               // fractional start (in [0,1))
        g.delay = d;                           // read at t - (T_k - s_k)
        const float pout = p / ratio_;
        untilNext_ += pout;
        dNext_ = d + pout - p;
    }

    float sr_ = 48000.f;
    int channels_ = 1;
    YinDetector det_;
    std::vector<float> dl_[2];
    int dlSize_ = 4096, w_ = 0;
    float hann_[kTable + 2]{};
    Grain grains_[kMaxGrains]{};
    int nGrains_ = 0;
    float untilNext_ = 0.f, dNext_ = 0.f;
    float period_ = 240.f, defaultPeriod_ = 240.f;
    float ratio_ = 1.f, targetRatio_ = 1.f;
    float wet_ = 0.f, fadeStep_ = 1.f / 960.f;
    bool active_ = false;

    std::atomic<bool> hold_{false};
    std::atomic<uint16_t> mask_{0xFFF};
    std::atomic<float> retuneMs_{5.f};
    std::atomic<float> lastHz_{0.f}, lastRatio_{1.f};
};

#endif  // ECHOMIC_PITCH_CORRECTOR_H
