#ifndef ECHOMIC_EQ5BAND_H
#define ECHOMIC_EQ5BAND_H

#include <cmath>
#include <algorithm>
#include <atomic>

// 5-band biquad equalizer.
//   band 0: 100 Hz  low shelf
//   band 1: 400 Hz  parametric (peaking)
//   band 2: 1 kHz   parametric (peaking)
//   band 3: 3 kHz   parametric (peaking)
//   band 4: 8 kHz   high shelf
// RBJ cookbook coefficients, Direct Form I, per-band per-channel state.
// Parametric bands use a fixed bandwidth Q of 1.5 octaves.
//
// Thread safety: setBandGain() may be called from a control (JNI) thread while
// process() runs on the audio thread. Each band keeps its coefficients in a
// 2-slot double buffer published through an atomic index, so the audio thread
// never observes a half-written (torn) coefficient set.
class EQ5Band {
public:
    void prepare(float sampleRate) {
        sampleRate_ = sampleRate;
        static const float kFreqs[5]  = {100, 400, 1000, 3000, 8000};
        static const bool  kShelf[5]  = {true, false, false, false, true};
        static const bool  kIsHigh[5] = {false, false, false, false, true};
        for (int i = 0; i < 5; i++) {
            bands_[i].freq   = kFreqs[i];
            bands_[i].shelf  = kShelf[i];
            bands_[i].isHigh = kIsHigh[i];
            // Restore the cached gain so EQ settings survive a stop()/start().
            computeCoeffs(i, bands_[i].gainDb);
        }
        for (int b = 0; b < 5; b++)
            for (int ch = 0; ch < 2; ch++)
                bands_[b].x1[ch] = bands_[b].x2[ch] = bands_[b].y1[ch] = bands_[b].y2[ch] = 0;
    }

    void setBandGain(int band, float gainDb) {
        if (band < 0 || band >= 5) return;
        gainDb = std::max(-12.0f, std::min(12.0f, gainDb));
        bands_[band].gainDb = gainDb;
        computeCoeffs(band, gainDb);
    }

    void process(float* samples, int frameCount, int channels) {
        const int chCount = std::min(channels, 2);
        for (int b = 0; b < 5; b++) {
            auto& bd = bands_[b];
            const Coeffs& c = bd.coeff[bd.coeffIndex.load(std::memory_order_acquire)];
            const float b0 = c.b0, b1 = c.b1, b2 = c.b2, a1 = c.a1, a2 = c.a2;
            for (int ch = 0; ch < chCount; ch++) {
                float lx1 = bd.x1[ch], lx2 = bd.x2[ch], ly1 = bd.y1[ch], ly2 = bd.y2[ch];
                for (int f = 0; f < frameCount; f++) {
                    int idx = f * channels + ch;
                    float x0 = samples[idx];
                    float y0 = b0 * x0 + b1 * lx1 + b2 * lx2 - a1 * ly1 - a2 * ly2;
                    samples[idx] = y0;
                    lx2 = lx1; lx1 = x0; ly2 = ly1; ly1 = y0;
                }
                bd.x1[ch] = lx1; bd.x2[ch] = lx2; bd.y1[ch] = ly1; bd.y2[ch] = ly2;
            }
        }
    }

private:
    float sampleRate_{48000};

    struct Coeffs {
        float b0{1}, b1{0}, b2{0}, a1{0}, a2{0};
    };

    struct Band {
        float freq{1000};
        float gainDb{0};                 // control-thread cache, restored by prepare()
        Coeffs coeff[2];                 // double buffer; audio thread reads active slot
        std::atomic<int> coeffIndex{0};  // index of the active slot
        float x1[2]{}, x2[2]{}, y1[2]{}, y2[2]{};
        bool shelf{false}, isHigh{false};
    } bands_[5];

    void computeCoeffs(int i, float gainDb) {
        auto& bd = bands_[i];
        float freq = std::clamp(bd.freq, 20.0f, sampleRate_ * 0.45f);
        float w0 = 2.0f * (float)M_PI * freq / sampleRate_;
        float cosW = cosf(w0), sinW = sinf(w0);
        if (fabsf(sinW) < 1e-6f) return;  // stability guard (w0 ~ 0 or ~ pi)
        float A = powf(10.0f, gainDb / 40.0f);

        float b0, b1, b2, a0, a1, a2;

        if (bd.shelf) {
            // Low/high shelf (RBJ cookbook), shelf slope S = 1.
            float S = 1.0f;
            float alpha = sinW / 2.0f * sqrtf((A + 1.0f / A) * (1.0f / S - 1.0f) + 2.0f);
            if (!bd.isHigh) {
                // Low shelf
                b0 =      A * ((A + 1) - (A - 1) * cosW + 2 * sqrtf(A) * alpha);
                b1 =  2 * A * ((A - 1) - (A + 1) * cosW);
                b2 =      A * ((A + 1) - (A - 1) * cosW - 2 * sqrtf(A) * alpha);
                a0 =          (A + 1) + (A - 1) * cosW + 2 * sqrtf(A) * alpha;
                a1 = -2 *    ((A - 1) + (A + 1) * cosW);
                a2 =          (A + 1) + (A - 1) * cosW - 2 * sqrtf(A) * alpha;
            } else {
                // High shelf
                b0 =      A * ((A + 1) + (A - 1) * cosW + 2 * sqrtf(A) * alpha);
                b1 = -2 * A * ((A - 1) + (A + 1) * cosW);
                b2 =      A * ((A + 1) + (A - 1) * cosW - 2 * sqrtf(A) * alpha);
                a0 =          (A + 1) - (A - 1) * cosW + 2 * sqrtf(A) * alpha;
                a1 =  2 *    ((A - 1) - (A + 1) * cosW);
                a2 =          (A + 1) - (A - 1) * cosW - 2 * sqrtf(A) * alpha;
            }
        } else {
            // Peaking EQ (RBJ cookbook), bandwidth = 1.5 octaves.
            float alpha = sinW * sinhf(logf(2.0f) / 2.0f * 1.5f * w0 / sinW);
            b0 =  1.0f + alpha * A;
            b1 = -2.0f * cosW;
            b2 =  1.0f - alpha * A;
            a0 =  1.0f + alpha / A;
            a1 = -2.0f * cosW;
            a2 =  1.0f - alpha / A;
        }

        // Write into the inactive slot, then publish it atomically so the
        // audio thread never reads a torn coefficient set.
        const int next = 1 - bd.coeffIndex.load(std::memory_order_relaxed);
        Coeffs& c = bd.coeff[next];
        float inv = 1.0f / a0;
        c.b0 = b0 * inv; c.b1 = b1 * inv; c.b2 = b2 * inv;
        c.a1 = a1 * inv; c.a2 = a2 * inv;
        bd.coeffIndex.store(next, std::memory_order_release);
    }
};

#endif  // ECHOMIC_EQ5BAND_H
