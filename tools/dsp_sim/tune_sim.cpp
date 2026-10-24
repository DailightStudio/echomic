// PitchCorrector (pitch_corrector.h) check: SRC=tune_sim.cpp tools/dsp_sim/run.sh
//   a accuracy : steady 226 Hz (A3 +47c), hold on -> output within +-10c of 220 Hz
//   b melody   : notes[] sweep, 1 % vibrato -> output within +-15c of a semitone
//   c crossfade: hold toggled every 300 ms -> no step larger than the dry signal's
//   d latency  : hold off is bit-exact bypass; hold on impulse lag < 600 samples
//   e cpu      : us per 192-frame block (informational)
#include <chrono>
#include <cmath>
#include <cstdio>
#include <vector>

#include "pitch_corrector.h"

static const int SR = 48000, BLOCK = 192;

// Sung vowel (copy of sim.cpp Voice + base pitch and envelope switch).
struct Voice {
    double ph = 0, t = 0; float amp; double vib = 0.01; bool melody = false;
    double f0 = 220; bool env = true;
    Voice(float a, double vib_, bool melody_, double f0_, bool env_)
        : amp(a), vib(vib_), melody(melody_), f0(f0_), env(env_) {}
    float next() {
        t += 1.0 / SR;
        static const double notes[] = {220, 247, 262, 294, 330, 294, 262, 247};
        double base = melody ? notes[(int)(t / 0.5) % 8] : f0;
        double f = base * (1 + vib * sin(2 * M_PI * 5.5 * t));
        ph += 2 * M_PI * f / SR;
        double s = 0; for (int h = 1; h <= 8; ++h) s += sin(h * ph) / h;
        double e = env ? 0.5 - 0.5 * cos(2 * M_PI * fmod(t, 0.5) / 0.5) : 1.0;  // 2 syll/s
        return (float)(amp * s / 1.5 * e);
    }
};

static double cents(double f, double ref) { return 1200.0 * log2(f / ref); }
static double centsFromSemitone(double f) {
    double m = 69 + 12 * log2(f / 440.0);
    return 100.0 * (m - std::round(m));
}

static int g_fail = 0;
static void report(bool ok, const char* name, const char* fmt, double a, double b) {
    printf("%s %-10s ", ok ? "PASS" : "FAIL", name);
    printf(fmt, a, b);
    printf("\n");
    if (!ok) ++g_fail;
}

// Run `seconds` of voice through the corrector with hold on; return the output.
static std::vector<float> runHeld(Voice v, double seconds, std::vector<float>* dryOut,
                                  double* usPerBlock = nullptr, double* usMax = nullptr) {
    PitchCorrector pc; pc.prepare(SR, 1); pc.setHold(true);
    const int blocks = (int)(seconds * SR / BLOCK);
    std::vector<float> out(blocks * BLOCK), dry(blocks * BLOCK);
    double tot = 0, mx = 0;
    for (int k = 0; k < blocks; ++k) {
        float* b = out.data() + k * BLOCK;
        for (int i = 0; i < BLOCK; ++i) dry[k * BLOCK + i] = b[i] = v.next();
        auto t0 = std::chrono::steady_clock::now();
        pc.process(b, BLOCK, 1);
        double us = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - t0).count();
        tot += us; if (us > mx) mx = us;
    }
    if (usPerBlock) *usPerBlock = tot / blocks;
    if (usMax) *usMax = mx;
    if (dryOut) *dryOut = dry;
    return out;
}

// Pitch per hop measured with the header's own detector (voiced hops only).
static std::vector<double> measure(const std::vector<float>& x, double fromSec, int* totalHops) {
    YinDetector d; d.prepare(SR);
    std::vector<double> hz; int total = 0;
    for (size_t n = 0; n < x.size(); ++n) {
        d.push(x[n]);
        if (d.tick() && n >= fromSec * SR) {
            d.analyze(); ++total;
            if (d.voiced()) hz.push_back(d.hz());
        }
    }
    if (totalHops) *totalHops = total;
    return hz;
}

// Independent estimate: low-passed upward zero crossings.
static double zeroCrossHz(const std::vector<float>& x, double fromSec) {
    double k = tan(M_PI * 260.0 / SR), q = 0.7071, nrm = 1 / (1 + k / q + k * k);
    double b0 = k * k * nrm, b1 = 2 * b0, b2 = b0, a1 = 2 * (k * k - 1) * nrm, a2 = (1 - k / q + k * k) * nrm;
    double z[2][2] = {{0, 0}, {0, 0}}, prev = 0, first = -1, last = -1; int cnt = 0;
    for (size_t n = 0; n < x.size(); ++n) {
        double y = x[n];
        for (int s = 0; s < 2; ++s) {
            double o = b0 * y + z[s][0];
            z[s][0] = b1 * y - a1 * o + z[s][1];
            z[s][1] = b2 * y - a2 * o;
            y = o;
        }
        if (n >= fromSec * SR && prev < 0 && y >= 0) {
            double tc = n - 1 + prev / (prev - y);
            if (first < 0) first = tc; else ++cnt;
            last = tc;
        }
        prev = y;
    }
    return cnt > 0 ? SR * cnt / (last - first) : 0;
}

static void testAccuracy() {
    auto out = runHeld(Voice(0.5f, 0.0, false, 226.0, false), 2.0, nullptr);
    int total; auto hz = measure(out, 0.2, &total);
    int ok = 0; for (double f : hz) if (fabs(cents(f, 220.0)) <= 10) ++ok;
    double frac = total ? (double)ok / total : 0;
    report(frac >= 0.90, "accuracy", "%.1f%% of hops within +-10c of 220 Hz (need >= 90%%), voiced %.0f%%",
           100 * frac, total ? 100.0 * hz.size() / total : 0);
    double zc = zeroCrossHz(out, 0.2);
    report(fabs(cents(zc, 220.0)) <= 10, "acc-zc", "zero-crossing %.2f Hz = %+.1f c vs 220 Hz (need +-10c)",
           zc, cents(zc, 220.0));
}

static void testMelody(double* us, double* usMax) {
    auto out = runHeld(Voice(0.5f, 0.01, true, 220.0, true), 8.0, nullptr, us, usMax);
    int total; auto hz = measure(out, 0.2, &total);
    int ok = 0; for (double f : hz) if (fabs(centsFromSemitone(f)) <= 15) ++ok;
    double frac = hz.empty() ? 0 : (double)ok / hz.size();
    bool enough = hz.size() >= total * 0.5;
    report(frac >= 0.85 && enough, "melody", "%.1f%% of voiced hops within +-15c of a semitone (need >= 85%%), voiced %.0f%%",
           100 * frac, total ? 100.0 * hz.size() / total : 0);
}

static void testCrossfade() {
    PitchCorrector pc; pc.prepare(SR, 1);
    Voice v(0.5f, 0.01, false, 226.0, true);
    const int blocks = 3 * SR / BLOCK, toggle = (int)(0.3 * SR);
    std::vector<float> dry(blocks * BLOCK), out(blocks * BLOCK);
    bool hold = false; int n = 0;
    for (int k = 0; k < blocks; ++k) {
        float* b = out.data() + k * BLOCK;
        for (int i = 0; i < BLOCK; ++i) dry[k * BLOCK + i] = b[i] = v.next();
        if (n / toggle != (n + BLOCK) / toggle) { hold = !hold; pc.setHold(hold); }
        pc.process(b, BLOCK, 1);
        n += BLOCK;
    }
    double md = 0, mo = 0;
    for (size_t i = 1; i < dry.size(); ++i) {
        md = fmax(md, fabs(dry[i] - dry[i - 1]));
        mo = fmax(mo, fabs(out[i] - out[i - 1]));
    }
    report(mo <= 1.5 * md, "crossfade", "max step out %.4f vs dry %.4f (need <= 1.5x)", mo, md);
}

static void testLatency() {
    const int len = SR / 2, at = SR / 5;   // impulse at 200 ms (after the 20 ms ramp)
    for (int hold = 0; hold < 2; ++hold) {
        PitchCorrector pc; pc.prepare(SR, 1); pc.setHold(hold);
        std::vector<float> x(len, 0.f); x[at] = 1.f;
        std::vector<float> y = x;
        for (int k = 0; k + BLOCK <= len; k += BLOCK) pc.process(y.data() + k, BLOCK, 1);
        if (!hold) {
            int diff = 0; for (int i = 0; i < len; ++i) diff += (y[i] != x[i]);
            report(diff == 0, "bypass", "hold off: %.0f of %.0f samples differ from input (need 0)", diff, len);
        } else {
            // cross-correlation of impulse with output == output itself
            int best = 0; for (int i = 0; i < len; ++i) if (fabs(y[i]) > fabs(y[best])) best = i;
            int lag = best - at;
            report(lag >= 0 && lag < 600, "latency", "hold on lag %.0f samples (%.2f ms, need < 600)", lag, lag * 1000.0 / SR);
        }
    }
}

int main() {
    testAccuracy();
    double us = 0, usMax = 0;
    testMelody(&us, &usMax);
    testCrossfade();
    testLatency();
    printf("INFO cpu       hold on: %.1f us avg, %.1f us max per %d-frame block (budget %.0f us)\n",
           us, usMax, BLOCK, 1e6 * BLOCK / SR);
    printf(g_fail ? "%d FAILED\n" : "ALL PASS\n", g_fail);
    return g_fail ? 1 : 0;
}
