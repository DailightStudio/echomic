// Recorder (recorder.h) check: SRC=rec_sim.cpp tools/dsp_sim/run.sh
// Pushes 1.5 s of a sine in 192-frame blocks at real-time pace into a 1 s
// cap, then verifies the WAV header, the sample count and the stop reason.
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "recorder.h"

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
    return ok ? 0 : 1;
}
