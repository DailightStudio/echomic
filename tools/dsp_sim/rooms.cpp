// Multi-resonance rooms: sing 2 s, then silence; "tail rms" is the output
// at 8-10 s (-240 = howl suppressed). Regression for the suppressor's voice
// test: 2026-10-24, of the 20 SUP cells, 2f/3f PHPR silenced 9, one-sided
// harmonic test 6, two-sided harmonic test (current) 13.
// Run: SRC=rooms.cpp sh run.sh
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
static bool g_noSup = false;
struct Chain {
    HighPassFilter hpf; NoiseGate gate; Compressor comp; EchoEffect echo;
    FeedbackSuppressor sup; FrequencyShifter fs; EQ5Band eq; ReverbEffect rev;
    bool boost; float gain, master; bool noSup = g_noSup;
    Chain(bool boost_, float gain_, float delayMs, float fb, float wet, bool shift, float gateDb = -40.f)
        : boost(boost_), gain(gain_), master(1.f) {
        hpf.prepare(SR); gate.prepare(SR); comp.prepare(SR); echo.prepare(SR, 1);
        sup.prepare(SR, 1); fs.prepare(SR); eq.prepare(SR); rev.prepare(SR);
        echo.setDelayMs(delayMs); echo.setFeedback(fb); rev.setWet(wet);
        gate.setThresholdDb(gateDb); fs.enabled.store(shift);
        for (int i = 0; i < 5; ++i) eq.setBandGain(i, 0.f);
    }
    void run(float* b, int n) {
        hpf.process(b, n, 1); gate.process(b, n, 1);
        if (boost) comp.process(b, n, 1, true);
        echo.process(b, n, boost ? gain : 1.f);
        if (!noSup) sup.process(b, n, 1); fs.process(b, n, 1); eq.process(b, n, 1);
        rev.process(b, n, 1);
        comp.limit(b, n);
    }
};
struct Voice {
    double ph = 0, t = 0; float amp; double vib; double base; int nh;
    Voice(float a, double vib_, double base_, int nh_ = 8) : amp(a), vib(vib_), base(base_), nh(nh_) {}
    float next() {
        t += 1.0 / SR;
        double f = base * (1 + vib * sin(2 * M_PI * 5.5 * t));
        ph += 2 * M_PI * f / SR;
        double s = 0; for (int h = 1; h <= nh; ++h) s += sin(h * ph) / h;
        double env = 0.5 - 0.5 * cos(2 * M_PI * fmod(t, 0.5) / 0.5);
        return (float)(amp * s / 1.5 * env);
    }
};
static float db(double x) { return 20 * log10(x + 1e-12); }
struct Res { double b0, a1, a2, y1 = 0, y2 = 0;
    Res(float fr) { double r = 0.97, th = 2 * M_PI * fr / SR; a1 = -2*r*cos(th); a2 = r*r;
        b0 = (1 - r) * sqrt(1 - 2*r*cos(2*th) + r*r); double peak = b0 / ((1-r)*sqrt(1-2*r*cos(2*th)+r*r)); b0 /= peak; }
    double push(double x) { double y = b0*x - a1*y1 - a2*y2; y2 = y1; y1 = y; return y; } };
struct Room {
    std::vector<float> dl; int w = 0, d; float g; std::vector<Res> res;
    Room(float loopDb, std::vector<float> frs, float delayMs) {
        d = (int)(delayMs * SR / 1000); dl.assign(d + 1, 0); g = powf(10, loopDb / 20);
        for (float f : frs) res.emplace_back(f);
    }
    float push(float out) { double y = 0; for (auto& r : res) y += r.push(out);
        dl[w] = (float)(g * y); w = (w + 1) % (d + 1); return dl[w]; }
};
// Goertzel band power at f over samples
struct Goertzel { Res r; double acc=0; long n=0; Goertzel(double f): r(f) { double rr=0.995, th=2*M_PI*f/SR; r.a1=-2*rr*cos(th); r.a2=rr*rr; r.b0=(1-rr)*sqrt(1-2*rr*cos(2*th)+rr*rr); }
    void add(float x){ double y = r.push(x); acc += y*y; ++n; }
    float dbfs(){ return db(sqrt(acc/n)); } };
// Continuous singing for 12 s with loop. Report: % of 100ms windows > -6 dBFS after 3 s,
// Goertzel level at each resonance over t in [6,12], and the voice fundamental level.
static void sing(const char* tag, Chain c, float L, std::vector<float> frs, float voicePeak, double base, int nh = 8) {
    Room room(L, frs, 30); Voice v(voicePeak, 0.01, base, nh);
    std::vector<float> b(BLOCK), prevOut(BLOCK, 0);
    double win = 0; int wn = 0, hot = 0, tot = 0; const int total = SR * 12 / BLOCK;
    std::vector<Goertzel> gz; for (float f : frs) gz.emplace_back(f); Goertzel gv(base);
    for (int k = 0; k < total; ++k) {
        float t = (float)k * BLOCK / SR;
        for (int i = 0; i < BLOCK; ++i) b[i] = v.next() + room.push(prevOut[i]);
        c.run(b.data(), BLOCK); prevOut = b;
        for (float x : b) { win += x * x; ++wn; }
        if (wn >= SR / 10) { float r = db(sqrt(win / wn)); win = 0; wn = 0; if (t > 3) { ++tot; if (r > -6) ++hot; } }
        if (t > 6) for (float x : b) { for (auto& g : gz) g.add(x); gv.add(x); }
    }
    printf("%-10s L%+3.0f fr", tag, L); for (float f : frs) printf(" %5.0f", f);
    printf(" voice %.2f@%.0fHz | hot %3d%% | howl lvl", voicePeak, base, 100 * hot / std::max(tot, 1));
    for (auto& g : gz) printf(" %6.1f", g.dbfs()); printf(" | f0 lvl %6.1f dBFS\n", gv.dbfs());
}
// Silence case: sing 2 s then silence; tail level at each resonance in [8,10]
static void tail(const char* tag, Chain c, float L, std::vector<float> frs) {
    Room room(L, frs, 30); Voice v(0.1f, 0.02, 220);
    std::vector<float> b(BLOCK), prevOut(BLOCK, 0); const int total = SR * 10 / BLOCK;
    std::vector<Goertzel> gz; for (float f : frs) gz.emplace_back(f); double tl = 0; long tn = 0;
    for (int k = 0; k < total; ++k) {
        float t = (float)k * BLOCK / SR;
        for (int i = 0; i < BLOCK; ++i) b[i] = (t < 2.f ? v.next() : 0.f) + room.push(prevOut[i]);
        c.run(b.data(), BLOCK); prevOut = b;
        if (t > 8) for (float x : b) { for (auto& g : gz) g.add(x); tl += x*x; ++tn; }
    }
    printf("%-10s L%+3.0f fr", tag, L); for (float f : frs) printf(" %5.0f", f);
    printf(" | tail rms %6.1f | per-res", db(sqrt(tl/tn))); for (auto& g : gz) printf(" %6.1f", g.dbfs()); putchar(10);
}
int main() {
    const char* tag = "SUP";
    for (float L : {-4.f, -3.f, -2.f, -1.f}) {
        tail(tag, Chain(false,2,120,.35f,.25f,false), L, {2500});
        tail(tag, Chain(false,2,120,.35f,.25f,false), L, {2000, 3000});
        tail(tag, Chain(false,2,120,.35f,.25f,false), L, {2000, 4000});
        tail(tag, Chain(false,2,120,.35f,.25f,false), L, {1600, 2400, 3200});
        tail(tag, Chain(false,2,120,.35f,.25f,false), L, {2200, 3100});
        g_noSup = true; tail("SUP-OFF", Chain(false,2,120,.35f,.25f,false), L, {2000, 3000}); g_noSup = false;
    }
    return 0;
}
