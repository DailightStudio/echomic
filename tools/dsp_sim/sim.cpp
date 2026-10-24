// Offline measurement of the Android DSP chain (same headers, same order as
// AudioEngine::runDsp) with the app's fresh-install defaults.
//   loud : output vs input level for a voice-like signal
//   howl : closed speaker->mic loop, sweep loop gain, find where it runs away
// Build for the emulator with the NDK clang, run via adb (see run.sh).
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "compressor.h"
#include "echo_effect.h"
#include "eq5band.h"
#include "feedback_suppressor.h"
#include "frequency_shifter.h"
#include "high_pass_filter.h"
#include "noise_gate.h"
#include "reverb.h"

static const int SR = 48000, BLOCK = 192;

static bool g_noSup = false; static float g_max = -200;
struct Chain {
    HighPassFilter hpf; NoiseGate gate; Compressor comp; EchoEffect echo;
    FeedbackSuppressor sup; FrequencyShifter fs; EQ5Band eq; ReverbEffect rev;
    bool boost; float gain, master; bool noSup = g_noSup;
    Chain(bool boost_, float gain_, float delayMs, float fb, float wet, bool shift,
          float gateDb = -40.f) : boost(boost_), gain(gain_), master(1.f) {
        hpf.prepare(SR); gate.prepare(SR); comp.prepare(SR); echo.prepare(SR, 1);
        sup.prepare(SR, 1); fs.prepare(SR); eq.prepare(SR); rev.prepare(SR);
        echo.setDelayMs(delayMs); echo.setFeedback(fb); rev.setWet(wet);
        gate.setThresholdDb(gateDb); fs.enabled.store(shift);
        for (int i = 0; i < 5; ++i) eq.setBandGain(i, 0.f);
    }
    void run(float* b, int n) {   // == AudioEngine::runDsp, mono
        hpf.process(b, n, 1); gate.process(b, n, 1);
        if (boost) comp.process(b, n, 1, true);
        echo.process(b, n, boost ? gain : 1.f);
        if (!noSup) sup.process(b, n, 1); fs.process(b, n, 1); eq.process(b, n, 1);
        rev.process(b, n, 1);
        if (master < 0.9999f) for (int i = 0; i < n; ++i) b[i] *= master;
        comp.limit(b, n);
    }
};

// Sung vowel: 220 Hz with harmonics and vibrato, syllable envelope.
struct Voice {
    double ph = 0, t = 0; float amp; double vib = 0.01; bool melody = false;
    explicit Voice(float a, double vib_ = 0.01, bool melody_ = false) : amp(a), vib(vib_), melody(melody_) {}
    float next() {
        t += 1.0 / SR;
        static const double notes[] = {220, 247, 262, 294, 330, 294, 262, 247};
        double base = melody ? notes[(int)(t / 0.5) % 8] : 220;
        double f = base * (1 + vib * sin(2 * M_PI * 5.5 * t));
        ph += 2 * M_PI * f / SR;
        double s = 0; for (int h = 1; h <= 8; ++h) s += sin(h * ph) / h;
        double env = 0.5 - 0.5 * cos(2 * M_PI * fmod(t, 0.5) / 0.5);  // 2 syll/s
        return (float)(amp * s / 1.5 * env);
    }
};

static float db(double x) { return 20 * log10(x + 1e-12); }

static void loud(const char* name, Chain c, float voicePeak) {
    Voice v(voicePeak); std::vector<float> b(BLOCK);
    double si = 0, so = 0, sdry = 0; long n = 0;
    for (int k = 0; k < SR * 6 / BLOCK; ++k) {
        for (auto& x : b) x = v.next();
        std::vector<float> in = b; c.run(b.data(), BLOCK);
        if (k > SR * 1 / BLOCK) for (int i = 0; i < BLOCK; ++i) { si += in[i]*in[i]; so += b[i]*b[i]; ++n; }
    }
    printf("loud %-28s in %6.1f dBFS  out %6.1f dBFS  out-in %+5.1f dB\n", name,
           db(sqrt(si / n)), db(sqrt(so / n)), db(sqrt(so / si)));
}

// Acoustic loop: output -> speaker/room (2-pole resonance at fr, delay d) -> mic.
// loopDb is the loop gain at the resonance peak. Engine adds its own latency
// (one BLOCK here; real round trip is added as acoustic delay).
struct Room {
    std::vector<float> dl; int w = 0, d; float g; double b0, a1, a2, y1 = 0, y2 = 0;
    Room(float loopDb, float fr, float delayMs) {
        d = (int)(delayMs * SR / 1000); dl.assign(d + 1, 0);
        double r = 0.97, th = 2 * M_PI * fr / SR;
        a1 = -2 * r * cos(th); a2 = r * r; b0 = (1 - r) * sqrt(1 - 2*r*cos(2*th) + r*r);
        // normalise the resonance peak to 0 dB, then apply loop gain
        g = powf(10, loopDb / 20);
        double peak = b0 / ((1 - r) * sqrt(1 - 2 * r * cos(2 * th) + r * r));
        b0 /= peak;
    }
    float push(float out) {   // returns what the mic hears now
        double y = b0 * out - a1 * y1 - a2 * y2; y2 = y1; y1 = y;
        dl[w] = (float)(g * y); w = (w + 1) % (d + 1);
        return dl[w];
    }
};

// Returns seconds until output RMS (100 ms window) stays >= -6 dBFS, or -1.
static float howl(Chain c, float loopDb, float fr, float latMs, float* tailDb) {
    Room room(loopDb, fr, latMs); Voice v(0.1f, 0.02, true);
    std::vector<float> b(BLOCK), prevOut(BLOCK, 0);
    double win = 0; int wn = 0; float hot = 0, first = -1;
    const int total = SR * 10 / BLOCK; double tail = 0; long tn = 0;
    for (int k = 0; k < total; ++k) {
        float t = (float)k * BLOCK / SR;
        for (int i = 0; i < BLOCK; ++i) {
            float mic = room.push(prevOut[i]);
            b[i] = (t < 2.0f ? v.next() : 0.f) + mic;   // sing 2 s, then silence
        }
        c.run(b.data(), BLOCK); prevOut = b;
        for (float x : b) { win += x * x; ++wn; }
        if (wn >= SR / 10) {
            float r = db(sqrt(win / wn)); win = 0; wn = 0;
            if (r > g_max) g_max = r;
            if (r > -6) { hot += 0.1f; if (first < 0 && hot >= 0.3f) first = t; } else hot = 0;
        }
        if (t > 8) for (float x : b) { tail += x * x; ++tn; }
    }
    *tailDb = db(sqrt(tail / tn));
    return first;
}


static void stages(float voicePeak, double vib = 0.01, bool melody = false) {
    Chain c(false, 2.f, 120, .35f, .25f, false);
    Voice v(voicePeak, vib, melody); std::vector<float> b(BLOCK);
    const char* names[] = {"input","hpf","gate","echo","suppressor","freqshift","eq","reverb","limiter"};
    double acc[9] = {0};
    for (int k = 0; k < SR * 6 / BLOCK; ++k) {
        for (auto& x : b) x = v.next();
        bool m = k > SR / BLOCK;
        auto add = [&](int s) { if (m) for (float x : b) acc[s] += x * x; };
        add(0); c.hpf.process(b.data(), BLOCK, 1); add(1);
        c.gate.process(b.data(), BLOCK, 1); add(2);
        c.echo.process(b.data(), BLOCK, 1.f); add(3);
        c.sup.process(b.data(), BLOCK, 1); add(4);
        c.fs.process(b.data(), BLOCK, 1); add(5);
        c.eq.process(b.data(), BLOCK, 1); add(6);
        c.rev.process(b.data(), BLOCK, 1); add(7);
        c.comp.limit(b.data(), BLOCK); add(8);
    }
    printf("stages (peak %.2f vib %.0f%% melody %d):", voicePeak, vib * 100, melody);
    for (int s = 1; s < 9; ++s) printf(" %s %+.1f", names[s], 10 * log10(acc[s] / acc[s - 1]));
    putchar(10);
}

int main() {
    stages(0.25f); stages(0.25f, 0.03); stages(0.25f, 0.01, true); stages(0.25f, 0.03, true); stages(0.03f, 0.02, true);
    printf("loop  | def(sup on) | sup off | shift on | sup off+shift | boost | boost+shift"); putchar(10);
    for (float L = -15; L <= 6.01f; L += 3) {
        float t, r[6], mx[6];
        g_max = -200; r[0] = howl(Chain(false, 2.f, 120, .35f, .25f, false), L, 2500, 30, &t); mx[0] = g_max;
        g_max = -200; r[2] = howl(Chain(false, 2.f, 120, .35f, .25f, true), L, 2500, 30, &t); mx[2] = g_max;
        g_noSup = true; g_max = -200; r[1] = howl(Chain(false, 2.f, 120, .35f, .25f, false), L, 2500, 30, &t); mx[1] = g_max;
        g_max = -200; r[3] = howl(Chain(false, 2.f, 120, .35f, .25f, true), L, 2500, 30, &t); mx[3] = g_max; g_noSup = false;
        g_max = -200; r[4] = howl(Chain(true, 2.f, 120, .35f, .25f, false), L, 2500, 30, &t); mx[4] = g_max;
        g_max = -200; r[5] = howl(Chain(true, 2.f, 120, .35f, .25f, true), L, 2500, 30, &t); mx[5] = g_max;
        printf("%+4.0f  |", L); for (int i = 0; i < 6; ++i) printf(" %4.1f %5.1f |", r[i], mx[i]); putchar(10);
    }
    return 0;
    // Fresh install: preset 노래방 (120 ms, 0.35, 0.25), boost off, gain 2.0, gate -40, shift off.
    printf("== loudness (voice peak -12 dBFS, i.e. close-mic singing)\n");
    loud("default (boost off)",      Chain(false, 2.f, 120, .35f, .25f, false), 0.25f);
    loud("boost on, gain 2.0",       Chain(true, 2.f, 120, .35f, .25f, false), 0.25f);
    loud("원음 preset, boost off",    Chain(false, 2.f, 0, 0, 0, false), 0.25f);
    printf("== loudness (voice peak -30 dBFS, phone held at arm's length)\n");
    loud("default (boost off)",      Chain(false, 2.f, 120, .35f, .25f, false), 0.03f);
    loud("boost on, gain 2.0",       Chain(true, 2.f, 120, .35f, .25f, false), 0.03f);

    printf("== howl: loop gain at speaker resonance 2.5 kHz, round trip 30 ms\n");
    printf("   loopDb | default: howl@s tail | freqShift on: howl@s tail | boost on: howl@s tail\n");
    for (float L = -12; L <= 6.01f; L += 3) {
        float t1, t2, t3, a, bq, cq;
        a  = howl(Chain(false, 2.f, 120, .35f, .25f, false), L, 2500, 30, &t1);
        bq = howl(Chain(false, 2.f, 120, .35f, .25f, true ), L, 2500, 30, &t2);
        cq = howl(Chain(true,  2.f, 120, .35f, .25f, false), L, 2500, 30, &t3);
        printf("   %+5.0f  |   %5.1f  %6.1f      |   %5.1f  %6.1f           |   %5.1f  %6.1f\n",
               L, a, t1, bq, t2, cq, t3);
    }
    return 0;
}
