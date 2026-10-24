// Recorder (recorder.h) check: SRC=rec_sim.cpp tools/dsp_sim/run.sh
// Pushes 1.5 s of a sine in 192-frame blocks at real-time pace into a 1 s
// cap, then verifies the WAV header, the sample count and the stop reason.
// Then a poller race check (cap and user stop): any reader that observes
// isRecording()==false must already see the final reason and duration.
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "recorder.h"

#include <atomic>

// Polls like the UI (tight loop here, to widen the window); returns the
// number of violations: saw !isRecording() with empty reason or a duration
// that later changed.
static int raceRun(Recorder &rec, const char *path, bool userStop, std::string &why) {
    if (!rec.start(path, 48000, 1, 1)) { why = "start"; return 1; }
    std::atomic<bool> done{false};
    int64_t seenDur = -1;
    std::string seenReason;
    std::thread poller([&] {
        // done is set only after isRecording() went false, so checking
        // isRecording() first guarantees one sample of the false state.
        for (;;) {
            if (!rec.isRecording()) {
                seenReason = rec.lastReason();
                seenDur = rec.durationMs();
                return;
            }
            if (done.load()) return;
        }
    });
    std::vector<float> buf(192, 0.25f);
    // userStop: ~0.5 s then stop("user"); else push past the 1 s cap.
    const int blocks = userStop ? 125 : 300;
    for (int b = 0; b < blocks; ++b) {
        rec.push(buf.data(), 192);
        std::this_thread::sleep_for(std::chrono::microseconds(4000));
        if (!userStop && !rec.isRecording()) break;
    }
    if (userStop) rec.stop("user");
    else while (rec.isRecording()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    done.store(true);
    poller.join();
    rec.stop("user");  // join the writer (no-op reason-wise after cap)
    const char *want = userStop ? "user" : "cap";
    int bad = 0;
    if (seenReason != want) { why += " reason=" + seenReason; ++bad; }
    if (seenDur != rec.durationMs()) { why += " dur=" + std::to_string(seenDur) + "!=" + std::to_string(rec.durationMs()); ++bad; }
    if (rec.lastReason() != want) { why += " final=" + rec.lastReason(); ++bad; }
    return bad;
}

static uint32_t rd32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

int main() {
    const char *path = "/data/local/tmp/rec_sim.wav";
    const int rate = 48000, block = 192;
    Recorder rec;
    if (!rec.start(path, rate, 1, 1)) { std::puts("FAIL start"); return 1; }
    std::vector<float> buf(block);
    for (int b = 0, n = 0; b < rate * 3 / 2 / block; ++b) {
        for (int i = 0; i < block; ++i, ++n) buf[i] = 0.5f * std::sin(2 * 3.14159265f * 440.0f * n / rate);
        rec.push(buf.data(), block);
        std::this_thread::sleep_for(std::chrono::microseconds(4000));
    }
    rec.stop("user");

    FILE *f = std::fopen(path, "rb");
    uint8_t h[44] = {};
    const bool hdr = f && std::fread(h, 1, 44, f) == 44;
    if (f) std::fclose(f);
    const uint32_t data = rd32(h + 40);
    const bool ok = hdr && !std::memcmp(h, "RIFF", 4) && !std::memcmp(h + 8, "WAVEfmt ", 8) &&
                    rd32(h + 24) == (uint32_t)rate && data == (uint32_t)rate * 2 &&
                    rd32(h + 4) == 36 + data && rec.lastReason() == "cap" && !rec.isRecording() &&
                    rec.durationMs() == 1000 && rec.overruns() == 0;
    std::printf("%s data=%u reason=%s durMs=%lld overruns=%u\n", ok ? "PASS" : "FAIL", data,
                rec.lastReason().c_str(), (long long)rec.durationMs(), rec.overruns());

    int bad = 0;
    const int kIters = 20;
    std::string why;
    for (int i = 0; i < kIters; ++i) {
        bad += raceRun(rec, path, false, why);
        bad += raceRun(rec, path, true, why);
    }
    std::printf("%s race: %d cap + %d user runs, violations=%d%s\n", bad ? "FAIL" : "PASS", kIters,
                kIters, bad, why.c_str());
    return ok && !bad ? 0 : 1;
}
