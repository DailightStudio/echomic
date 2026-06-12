#include "audio_engine.h"

#include <android/log.h>

#include <algorithm>
#include <cmath>
#include <cstring>

#define LOG_TAG "EchomicEngine"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

AudioEngine::~AudioEngine() {
    stop();
}

bool AudioEngine::start() {
    std::lock_guard<std::mutex> lock(lifecycleLock_);
    if (running_.load()) return true;
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
        ->setDataCallback(this)
        ->setErrorCallback(this)
        ->setUsage(oboe::Usage::VoiceCommunication);

    oboe::Result result = outBuilder.openStream(outputStream_);
    if (result != oboe::Result::OK) {
        LOGE("Failed to open output stream: %s", oboe::convertToText(result));
        return false;
    }

    sampleRate_ = outputStream_->getSampleRate();
    channelCount_ = outputStream_->getChannelCount();

    // ---- Input stream, matched to the output's rate/channels. ----
    oboe::AudioStreamBuilder inBuilder;
    inBuilder.setDirection(oboe::Direction::Input)
        ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
        ->setSharingMode(oboe::SharingMode::Exclusive)
        ->setFormat(oboe::AudioFormat::Float)
        ->setSampleRate(sampleRate_)
        ->setChannelCount(channelCount_)
        ->setInputPreset(oboe::InputPreset::VoicePerformance)
        ->setDataCallback(this)
        ->setErrorCallback(this);

    result = inBuilder.openStream(inputStream_);
    if (result != oboe::Result::OK) {
        LOGE("Failed to open input stream: %s", oboe::convertToText(result));
        return false;
    }

    // The negotiated input format may differ from what we requested (e.g. on
    // BT routes). A rate/channel mismatch would feed mis-clocked samples into
    // the filters, so treat it as a hard failure.
    if (inputStream_->getSampleRate() != sampleRate_ ||
        inputStream_->getChannelCount() != channelCount_) {
        LOGE("Input/output format mismatch: in rate=%d ch=%d, out rate=%d ch=%d",
             inputStream_->getSampleRate(), inputStream_->getChannelCount(),
             sampleRate_, channelCount_);
        return false;
    }

    // Prepare the echo delay line for the negotiated format.
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

    // FIFO holds ~200 ms of audio; plenty of headroom over the callback size.
    const int frames = std::max(sampleRate_ / 5, 2048);
    fifoCapacity_ = frames * channelCount_;
    fifo_.assign(static_cast<size_t>(fifoCapacity_), 0.0f);
    fifoWrite_.store(0);
    fifoRead_.store(0);

    // Tighten the output buffer towards the burst size for minimal latency.
    outputStream_->setBufferSizeInFrames(outputStream_->getFramesPerBurst() * 2);

    result = outputStream_->requestStart();
    if (result != oboe::Result::OK) {
        LOGE("Failed to start output stream: %s", oboe::convertToText(result));
        return false;
    }
    result = inputStream_->requestStart();
    if (result != oboe::Result::OK) {
        LOGE("Failed to start input stream: %s", oboe::convertToText(result));
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
}

oboe::DataCallbackResult AudioEngine::onAudioReady(oboe::AudioStream *stream,
                                                   void *audioData,
                                                   int32_t numFrames) {
    const int channels = channelCount_;
    const int sampleCount = numFrames * channels;

    if (stream->getDirection() == oboe::Direction::Input) {
        // Process mic input then push into the FIFO for the output stream.
        auto *in = static_cast<float *>(audioData);
        // iOS signal flow: HPF -> Gate -> Comp -> Echo -> Limit -> Suppressor -> FreqShifter -> EQ -> Reverb
        hpf_.process(in, numFrames, channels);
        gate_.process(in, numFrames, channels);
        comp_.process(in, numFrames, channels);
        echo_.process(in, numFrames, gain_.load());
        comp_.limit(in, numFrames * channels);
        suppressor_.process(in, numFrames, channels);
        freqShifter_.process(in, numFrames, channels);
        eq_.process(in, numFrames, channels);
        reverb_.process(in, numFrames, channels);

        // 마스터볼륨
        const float master = masterGain_.load();
        if (master < 0.9999f) {
            for (int i = 0; i < sampleCount; ++i) in[i] *= master;
        }

        // RMS 계산 (UI 폴링용)
        if (sampleCount > 0) {
            float sumSq = 0.0f;
            for (int i = 0; i < sampleCount; ++i) sumSq += in[i] * in[i];
            rmsLevel_.store(std::sqrt(sumSq / static_cast<float>(sampleCount)));
        }

        int writeIdx = fifoWrite_.load(std::memory_order_relaxed);
        const int readIdx = fifoRead_.load(std::memory_order_acquire);
        for (int i = 0; i < sampleCount; ++i) {
            const int next = (writeIdx + 1) % fifoCapacity_;
            if (next == readIdx) break;  // FIFO full: drop to avoid blocking
            fifo_[static_cast<size_t>(writeIdx)] = in[i];
            writeIdx = next;
        }
        fifoWrite_.store(writeIdx, std::memory_order_release);
        return oboe::DataCallbackResult::Continue;
    }

    // Output direction: drain the FIFO, zero-fill on underrun.
    auto *out = static_cast<float *>(audioData);
    int readIdx = fifoRead_.load(std::memory_order_relaxed);
    const int writeIdx = fifoWrite_.load(std::memory_order_acquire);
    for (int i = 0; i < sampleCount; ++i) {
        if (readIdx == writeIdx) {
            out[i] = 0.0f;  // underrun
        } else {
            out[i] = fifo_[static_cast<size_t>(readIdx)];
            readIdx = (readIdx + 1) % fifoCapacity_;
        }
    }
    fifoRead_.store(readIdx, std::memory_order_release);
    return oboe::DataCallbackResult::Continue;
}

void AudioEngine::onErrorAfterClose(oboe::AudioStream *stream,
                                    oboe::Result error) {
    LOGE("Stream error after close: %s", oboe::convertToText(error));
    std::lock_guard<std::mutex> lock(lifecycleLock_);
    running_.store(false);
    // The errored stream is already closed by Oboe; stop and close the partner
    // stream too so it does not keep running against a dead counterpart.
    if (inputStream_ && inputStream_.get() != stream) {
        inputStream_->requestStop();
        inputStream_->close();
    }
    if (outputStream_ && outputStream_.get() != stream) {
        outputStream_->requestStop();
        outputStream_->close();
    }
    inputStream_.reset();
    outputStream_.reset();
}
