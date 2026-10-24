#ifndef ECHOMIC_RECORDER_H
#define ECHOMIC_RECORDER_H

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

// Records the final (post-limiter) output to a 16-bit PCM WAV file.
//
// Audio thread: push() copies the block into a lock-free SPSC float ring
// (no allocation, no locks, no logging); a full ring drops the whole block
// and bumps overruns(). Writer thread (owned here): every 20 ms drains the
// ring, clip-converts to int16 and fwrite()s; on exit patches the WAV header
// sizes and closes the file. start()/stop() are control-thread only (the
// engine calls them under its lifecycleLock_).
//
// Stop reasons: whatever stop() is given ("user"/"engine"), "cap" when
// maxSeconds is reached, "error" when a write fails (e.g. disk full).
class Recorder {
public:
    Recorder() : ring_(new float[kRingSize]) {}
    ~Recorder() { stop("engine"); }

    Recorder(const Recorder &) = delete;
    Recorder &operator=(const Recorder &) = delete;

    bool start(const char *path, int sampleRate, int channels, int maxSeconds) {
        if (active_.load() || !path || sampleRate <= 0 || channels <= 0 || maxSeconds <= 0)
            return false;
        if (writer_.joinable()) writer_.join();  // previous run ended itself (cap/error)

        FILE *f = std::fopen(path, "wb");
        if (!f) return false;
        uint8_t header[44] = {};
        if (std::fwrite(header, 1, sizeof(header), f) != sizeof(header)) {
            std::fclose(f);
            std::remove(path);
            return false;
        }

        {
            std::lock_guard<std::mutex> lock(infoLock_);
            path_ = path;
            reason_.clear();
        }
        file_ = f;
        sampleRate_ = sampleRate;
        channels_ = channels;
        maxSamples_ = static_cast<int64_t>(maxSeconds) * sampleRate * channels;
        samplesWritten_.store(0);
        overruns_.store(0);
        // Consumer owns tail_: discard anything a stale push left behind.
        tail_.store(head_.load(std::memory_order_acquire), std::memory_order_release);
        active_.store(true, std::memory_order_release);
        writer_ = std::thread(&Recorder::writerLoop, this);
        return true;
    }

    void stop(const char *reason) {
        if (active_.exchange(false)) setReason(reason ? reason : "user");
        if (writer_.joinable()) writer_.join();
    }

    // Audio thread only.
    void push(const float *data, int samples) {
        if (samples <= 0 || !active_.load(std::memory_order_acquire)) return;
        const size_t n = static_cast<size_t>(samples);
        const size_t head = head_.load(std::memory_order_relaxed);
        const size_t tail = tail_.load(std::memory_order_acquire);
        if (n > kRingSize - (head - tail)) {
            overruns_.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        for (size_t i = 0; i < n; ++i) ring_[(head + i) & kRingMask] = data[i];
        head_.store(head + n, std::memory_order_release);
    }

    bool isRecording() const { return active_.load(); }
    int64_t durationMs() const {
        const int64_t frames = samplesWritten_.load() / (channels_ > 0 ? channels_ : 1);
        return sampleRate_ > 0 ? frames * 1000 / sampleRate_ : 0;
    }
    uint32_t overruns() const { return overruns_.load(); }
    std::string lastPath() {
        std::lock_guard<std::mutex> lock(infoLock_);
        return path_;
    }
    std::string lastReason() {
        std::lock_guard<std::mutex> lock(infoLock_);
        return reason_;
    }

private:
    static constexpr size_t kRingSize = size_t{1} << 18;
    static constexpr size_t kRingMask = kRingSize - 1;
    static constexpr size_t kChunk = 4096;

    void setReason(const char *r) {
        std::lock_guard<std::mutex> lock(infoLock_);
        reason_ = r;
    }

    // Ends the recording from the writer thread (cap/error); a concurrent
    // stop() that already flipped active_ keeps its own reason.
    void endSelf(const char *reason) {
        if (active_.exchange(false)) setReason(reason);
    }

    // Returns false on a write error.
    bool drain() {
        int16_t out[kChunk];
        size_t tail = tail_.load(std::memory_order_relaxed);
        const size_t head = head_.load(std::memory_order_acquire);
        while (tail != head) {
            const int64_t room = maxSamples_ - samplesWritten_.load(std::memory_order_relaxed);
            if (room <= 0) break;
            size_t n = std::min(head - tail, kChunk);
            if (static_cast<int64_t>(n) > room) n = static_cast<size_t>(room);
            for (size_t i = 0; i < n; ++i) {
                float s = ring_[(tail + i) & kRingMask];
                s = s > 1.0f ? 1.0f : (s < -1.0f ? -1.0f : s);
                out[i] = static_cast<int16_t>(s * 32767.0f);
            }
            if (std::fwrite(out, sizeof(int16_t), n, file_) != n) {
                tail_.store(head, std::memory_order_release);
                return false;
            }
            tail += n;
            tail_.store(tail, std::memory_order_release);
            samplesWritten_.fetch_add(static_cast<int64_t>(n), std::memory_order_relaxed);
        }
        // Past the cap: discard whatever is left.
        if (samplesWritten_.load(std::memory_order_relaxed) >= maxSamples_)
            tail_.store(head, std::memory_order_release);
        return true;
    }

    void writerLoop() {
        bool ok = true;
        while (active_.load(std::memory_order_acquire)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
            if (!drain()) { ok = false; endSelf("error"); break; }
            if (samplesWritten_.load() >= maxSamples_) { endSelf("cap"); break; }
        }
        if (ok) drain();  // whatever arrived before active_ flipped
        finalize();
    }

    static void put32(uint8_t *p, uint32_t v) {
        p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF; p[2] = (v >> 16) & 0xFF; p[3] = (v >> 24) & 0xFF;
    }
    static void put16(uint8_t *p, uint16_t v) { p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF; }

    void finalize() {
        const uint32_t dataBytes =
            static_cast<uint32_t>(samplesWritten_.load() * static_cast<int64_t>(sizeof(int16_t)));
        uint8_t h[44];
        std::memcpy(h, "RIFF", 4);
        put32(h + 4, 36 + dataBytes);
        std::memcpy(h + 8, "WAVEfmt ", 8);
        put32(h + 16, 16);                                   // fmt chunk size
        put16(h + 20, 1);                                    // PCM
        put16(h + 22, static_cast<uint16_t>(channels_));
        put32(h + 24, static_cast<uint32_t>(sampleRate_));
        put32(h + 28, static_cast<uint32_t>(sampleRate_ * channels_ * 2));  // byte rate
        put16(h + 32, static_cast<uint16_t>(channels_ * 2));               // block align
        put16(h + 34, 16);                                   // bits per sample
        std::memcpy(h + 36, "data", 4);
        put32(h + 40, dataBytes);
        if (std::fseek(file_, 0, SEEK_SET) == 0) std::fwrite(h, 1, sizeof(h), file_);
        std::fclose(file_);
        file_ = nullptr;
    }

    std::unique_ptr<float[]> ring_;
    std::atomic<size_t> head_{0};  // producer (audio thread)
    std::atomic<size_t> tail_{0};  // consumer (writer thread)
    std::atomic<bool> active_{false};
    std::atomic<int64_t> samplesWritten_{0};
    std::atomic<uint32_t> overruns_{0};

    std::thread writer_;
    FILE *file_ = nullptr;
    int sampleRate_ = 0;
    int channels_ = 0;
    int64_t maxSamples_ = 0;

    std::mutex infoLock_;
    std::string path_;
    std::string reason_;
};

#endif  // ECHOMIC_RECORDER_H
