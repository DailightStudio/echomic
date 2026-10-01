#include "audio_engine.h"

#include <android/log.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <thread>

#define LOG_TAG "EchomicEngine"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {
// Debounce before reopening streams after ErrorDisconnected (headset/BT
// plug event): gives the audio route a moment to settle so the reopen
// doesn't race the system still tearing down/renegotiating the old route.
constexpr auto kRestartDebounce = std::chrono::milliseconds(300);
}  // namespace

AudioEngine::AudioEngine() : duplex_(this) {}

AudioEngine::~AudioEngine() {
    stop();
}

oboe::DataCallbackResult AudioEngine::DuplexProcessor::onBothStreamsReady(
        const void *inputData, int numInputFrames, void *outputData, int numOutputFrames) {
    return engine_->processBothStreamsReady(inputData, numInputFrames, outputData,
                                             numOutputFrames);
}

oboe::ResultWithValue<int32_t> AudioEngine::DuplexProcessor::readInput(int32_t numFrames) {
    oboe::ResultWithValue<int32_t> result = oboe::FullDuplexStream::readInput(numFrames);
    if (!result) {
        // Audio-thread context (inside the output stream's realtime
        // callback): hand off to handleInputReadFailure(), which stays
        // allocation/lock-free itself and only ever spawns one background
        // thread per failure window.
        engine_->handleInputReadFailure();
    }
    return result;
}

bool AudioEngine::start() {
    std::lock_guard<std::mutex> lock(lifecycleLock_);
    if (running_.load()) return true;
    generation_.fetch_add(1, std::memory_order_relaxed);
    if (!openStreams()) {
        closeStreams();
        return false;
    }
    running_.store(true);
    return true;
}

void AudioEngine::stop() {
    std::lock_guard<std::mutex> lock(lifecycleLock_);
    if (!running_.load() && !inputStream_ && !outputStream_) return;
    // Invalidate any restart thread that might currently be sleeping off a
    // disconnect debounce, and any late error callback from the streams
    // closeStreams() is about to tear down.
    generation_.fetch_add(1, std::memory_order_relaxed);
    running_.store(false);
    closeStreams();
}

bool AudioEngine::openStreams() {
    // ---- Output stream first so we can match its format for the input. ----
    oboe::AudioStreamBuilder outBuilder;
    outBuilder.setDirection(oboe::Direction::Output)
        ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
        ->setSharingMode(oboe::SharingMode::Exclusive)
        ->setFormat(oboe::AudioFormat::Float)
        ->setChannelCount(oboe::ChannelCount::Mono)
        ->setDataCallback(&duplex_)
        ->setErrorCallback(this)
        // Usage::Game (Android/Oboe's documented low-latency "pro audio"
        // usage) + ContentType::Music, NOT VoiceCommunication:
        // VoiceCommunication puts the stream on the telephony audio path,
        // which (a) routes to the earpiece instead of the loudspeaker when
        // no headset is attached, (b) ties its volume to the call-volume
        // stream instead of the media volume keys, and (c) can duck/pause
        // other apps' playback the way an incoming call would. Game+Music
        // avoids all three while keeping the low-latency fast-mixer path.
        ->setUsage(oboe::Usage::Game)
        ->setContentType(oboe::ContentType::Music);

    oboe::Result result = outBuilder.openStream(outputStream_);
    if (result != oboe::Result::OK) {
        LOGE("Failed to open output stream: %s", oboe::convertToText(result));
        return false;
    }

    sampleRate_ = outputStream_->getSampleRate();
    channelCount_ = outputStream_->getChannelCount();

    // ---- Input stream, matched to the output's rate/channels. ----
    // No data/error callback: under the FullDuplexStream pattern the input
    // stream is read with a non-blocking read() from inside the output
    // stream's callback (see onBothStreamsReady()/FullDuplexStream), so it
    // needs no callback thread of its own.
    oboe::AudioStreamBuilder inBuilder;
    inBuilder.setDirection(oboe::Direction::Input)
        ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
        ->setSharingMode(oboe::SharingMode::Exclusive)
        ->setFormat(oboe::AudioFormat::Float)
        ->setSampleRate(sampleRate_)
        ->setChannelCount(channelCount_)
        ->setInputPreset(oboe::InputPreset::VoicePerformance)
        // BT routes (e.g. HFP mics) may only offer 8/16 kHz PCM16 mono; let
        // Oboe resample/convert to the output format instead of failing start().
        ->setChannelConversionAllowed(true)
        ->setFormatConversionAllowed(true)
        ->setSampleRateConversionQuality(oboe::SampleRateConversionQuality::Medium)
        // Oboe's recommended sizing so the input stream has enough headroom
        // that the output callback's non-blocking reads don't starve it.
        ->setBufferCapacityInFrames(outputStream_->getBufferCapacityInFrames() * 2);

    result = inBuilder.openStream(inputStream_);
    if (result != oboe::Result::OK) {
        LOGE("Failed to open input stream: %s", oboe::convertToText(result));
        return false;
    }

    // With conversion enabled above, Oboe delivers the input already matched
    // to the requested rate/channels, so a mismatch here should be impossible.
    // Keep the check as a safety net since mis-clocked samples would corrupt
    // every filter downstream.
    if (inputStream_->getSampleRate() != sampleRate_ ||
        inputStream_->getChannelCount() != channelCount_) {
        LOGE("Format negotiation failed despite conversion enabled: "
             "in rate=%d ch=%d, out rate=%d ch=%d",
             inputStream_->getSampleRate(), inputStream_->getChannelCount(),
             sampleRate_, channelCount_);
        return false;
    }

    // Prepare the DSP chain for the negotiated format.
    echo_.prepare(sampleRate_, channelCount_);
    echo_.reset();

    comp_.prepare(sampleRate_);
    comp_.reset();

    reverb_.prepare(sampleRate_);
    reverb_.reset();

    hpf_.prepare(sampleRate_);
    gate_.prepare(sampleRate_);
    freqShifter_.prepare(static_cast<float>(sampleRate_));
    eq_.prepare(static_cast<float>(sampleRate_));
    suppressor_.prepare(static_cast<float>(sampleRate_), channelCount_);

    // Scratch buffer the DSP chain processes in place, sized to the same
    // bound FullDuplexStream uses for its own internal input buffer so a
    // single onBothStreamsReady() callback can never see more input frames
    // than this holds. Allocated here (control thread, before streams
    // start), never resized on the audio thread.
    const int scratchCapacityFrames = outputStream_->getBufferCapacityInFrames();
    scratch_.assign(static_cast<size_t>(scratchCapacityFrames) * channelCount_, 0.0f);

    // Tighten the output buffer towards the burst size for minimal latency.
    outputStream_->setBufferSizeInFrames(outputStream_->getFramesPerBurst() * 2);

    duplex_.setInputStream(inputStream_.get());
    duplex_.setOutputStream(outputStream_.get());
    // No cushion, read as soon as any frames are available: minimum latency
    // is a product requirement here (vs. the extra underrun margin a
    // non-zero cushion/threshold would buy).
    duplex_.setNumInputBurstsCushion(0);
    duplex_.setMinimumFramesBeforeRead(0);

    oboe::Result startResult = duplex_.start();
    if (startResult != oboe::Result::OK) {
        LOGE("Failed to start full-duplex streams: %s", oboe::convertToText(startResult));
        return false;
    }

    LOGI("Streams started: rate=%d ch=%d burst=%d", sampleRate_, channelCount_,
         outputStream_->getFramesPerBurst());
    return true;
}

void AudioEngine::closeStreams() {
    if (inputStream_) {
        inputStream_->requestStop();
        inputStream_->close();
        inputStream_.reset();
    }
    if (outputStream_) {
        outputStream_->requestStop();
        outputStream_->close();
        outputStream_.reset();
    }
    // Drop FullDuplexStream's own raw pointers so nothing can dereference a
    // stream we just destroyed.
    duplex_.setInputStream(nullptr);
    duplex_.setOutputStream(nullptr);
}

void AudioEngine::runDsp(float *buf, int numFrames) {
    const int channels = channelCount_;
    const int sampleCount = numFrames * channels;

    // Signal flow: HPF -> Gate -> Comp -> Echo -> Suppressor -> FreqShifter
    // -> EQ -> Reverb -> Master -> Limiter. The limiter runs last (after
    // master gain), per the audio-dsp-review audit, so it is the final
    // safety ceiling on exactly what reaches the output -- nothing after it
    // can reintroduce clipping.
    hpf_.process(buf, numFrames, channels);
    gate_.process(buf, numFrames, channels);

    const bool boost = boost_.load();
    if (boost) {
        // Boost off = bypass the compressor entirely (gain 1.0): skip
        // process() outright rather than merely disabling its makeup gain,
        // so no envelope-follower gain reduction is applied either.
        comp_.process(buf, numFrames, channels, /*applyMakeup=*/true);
    }
    echo_.process(buf, numFrames, boost ? gain_.load() : 1.0f);
    suppressor_.process(buf, numFrames, channels);
    freqShifter_.process(buf, numFrames, channels);
    eq_.process(buf, numFrames, channels);
    reverb_.process(buf, numFrames, channels);

    // 마스터볼륨
    const float master = masterGain_.load();
    if (master < 0.9999f) {
        for (int i = 0; i < sampleCount; ++i) buf[i] *= master;
    }

    // Limiter: always-on safety ceiling, independent of boost.
    comp_.limit(buf, sampleCount);

    // RMS 계산 (UI 폴링용) -- reflects the final, post-limiter signal.
    if (sampleCount > 0) {
        float sumSq = 0.0f;
        for (int i = 0; i < sampleCount; ++i) sumSq += buf[i] * buf[i];
        rmsLevel_.store(std::sqrt(sumSq / static_cast<float>(sampleCount)));
    }
}

oboe::DataCallbackResult AudioEngine::processBothStreamsReady(const void *inputData,
                                                               int numInputFrames,
                                                               void *outputData,
                                                               int numOutputFrames) {
    auto *out = static_cast<float *>(outputData);
    const int outSamples = numOutputFrames * channelCount_;

    if (numInputFrames <= 0) {
        // Priming/underrun: no input yet this callback.
        std::fill(out, out + outSamples, 0.0f);
        return oboe::DataCallbackResult::Continue;
    }

    // inputData is read-only (it is FullDuplexStream's own internal
    // buffer), so copy it into our preallocated scratch buffer to run the
    // DSP chain in place.
    const int frames = numInputFrames;
    const int inSamples = frames * channelCount_;
    const auto *in = static_cast<const float *>(inputData);
    float *buf = scratch_.data();
    std::copy(in, in + inSamples, buf);

    runDsp(buf, frames);

    std::copy(buf, buf + inSamples, out);
    if (numOutputFrames > frames) {
        std::fill(out + inSamples, out + outSamples, 0.0f);
    }
    return oboe::DataCallbackResult::Continue;
}

void AudioEngine::onErrorAfterClose(oboe::AudioStream * /*stream*/,
                                    oboe::Result error) {
    // Under the FullDuplexStream contract this fires only for the output
    // stream, which Oboe has already stopped+closed by the time we get here.
    LOGE("Output stream error after close: %s", oboe::convertToText(error));

    uint64_t myGeneration;
    bool shouldRestart;
    {
        std::lock_guard<std::mutex> lock(lifecycleLock_);
        if (!running_.load()) return;  // already stopped/superseded
        myGeneration = generation_.load();

        outputStream_.reset();
        duplex_.setOutputStream(nullptr);
        // We own stopping/closing the input stream, the errored output's
        // now-dead partner.
        if (inputStream_) {
            inputStream_->requestStop();
            inputStream_->close();
            inputStream_.reset();
        }
        duplex_.setInputStream(nullptr);

        shouldRestart = (error == oboe::Result::ErrorDisconnected);
        if (!shouldRestart) {
            // Not a routing change we can recover from transparently: stop
            // for real so the UI's 'state' running:false event fires.
            running_.store(false);
        }
    }
    if (!shouldRestart) return;

    // Disconnect (headset/BT plug event): restart from a separate thread
    // with a short debounce so the reopen doesn't race a route that's still
    // settling. `running_` is left true throughout so the engine's
    // externally-visible state never flaps for a transparent reconnect --
    // only a real stop()/failed-restart flips it to false.
    std::thread([this, myGeneration]() {
        std::this_thread::sleep_for(kRestartDebounce);
        std::lock_guard<std::mutex> lock(lifecycleLock_);
        // Ignore late/stale restarts: a newer start()/stop() (or this
        // thread losing a race to another one) already moved the engine
        // past this generation.
        if (myGeneration != generation_.load() || !running_.load()) return;
        if (!openStreams()) {
            LOGE("Restart after disconnect failed");
            closeStreams();
            running_.store(false);
        } else {
            generation_.fetch_add(1, std::memory_order_relaxed);
        }
    }).detach();
}

void AudioEngine::handleInputReadFailure() {
    // Called from the audio callback thread (DuplexProcessor::readInput) --
    // stay allocation/lock-free and syscall-free here (no logging on this
    // thread). The one-shot guard keeps a run of consecutive failing
    // callbacks (before AAudio actually stops calling back) from spawning
    // more than one handler thread.
    if (inputFailurePending_.exchange(true)) return;

    std::thread([this]() {
        LOGE("Input read failed; tearing down and scheduling restart");
        // Debounce before touching either stream: besides giving the route
        // a moment to settle like the ErrorDisconnected path above, this
        // also guarantees the triggering callback invocation has long since
        // returned (so closeStreams() below isn't racing a still-running
        // audio callback touching the same stream objects) -- unlike
        // onErrorAfterClose(), Oboe gives no guarantee here that the stream
        // is already stopped.
        std::this_thread::sleep_for(kRestartDebounce);
        std::lock_guard<std::mutex> lock(lifecycleLock_);
        inputFailurePending_.store(false);
        if (!running_.load()) return;  // already stopped by something else (e.g. fix 2)

        generation_.fetch_add(1, std::memory_order_relaxed);
        closeStreams();
        if (!openStreams()) {
            LOGE("Restart after input read failure failed");
            closeStreams();
            running_.store(false);
        } else {
            generation_.fetch_add(1, std::memory_order_relaxed);
        }
    }).detach();
}
