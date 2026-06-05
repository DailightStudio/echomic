#ifndef ECHOMIC_AUDIO_ENGINE_H
#define ECHOMIC_AUDIO_ENGINE_H

#include <atomic>
#include <mutex>
#include <vector>

#include <oboe/Oboe.h>

#include "echo_effect.h"
#include "compressor.h"
#include "reverb.h"

/**
 * Full-duplex low-latency engine built on two Oboe streams.
 *
 * The input stream is the master clock: its data callback reads the mic,
 * runs gain + echo, and writes the processed audio into a lock-free FIFO that
 * the output stream drains. Both streams request AAudio LowLatency + Exclusive
 * Float so the framework can pick the fast mixer path.
 */
class AudioEngine : public oboe::AudioStreamDataCallback,
                    public oboe::AudioStreamErrorCallback {
public:
    AudioEngine() = default;
    ~AudioEngine() override;

    bool start();
    void stop();

    void setGain(float gain) { gain_.store(gain); }
    void setEchoDelay(float delayMs) { echo_.setDelayMs(delayMs); }
    void setEchoFeedback(float feedback) { echo_.setFeedback(feedback); }
    void setReverbWet(float wet)      { reverb_.setWet(wet); }
    void setMasterGain(float gain)    { masterGain_.store(gain); }
    float getRmsLevel() const         { return rmsLevel_.load(); }
    bool isRunning() const            { return running_.load(); }

    // oboe::AudioStreamDataCallback
    oboe::DataCallbackResult onAudioReady(oboe::AudioStream *stream,
                                          void *audioData,
                                          int32_t numFrames) override;

    // oboe::AudioStreamErrorCallback
    void onErrorAfterClose(oboe::AudioStream *stream, oboe::Result error) override;

private:
    bool openStreams();
    void closeStreams();

    std::shared_ptr<oboe::AudioStream> inputStream_;
    std::shared_ptr<oboe::AudioStream> outputStream_;

    EchoEffect echo_;
    Compressor comp_;
    ReverbEffect reverb_;
    std::atomic<float> masterGain_{1.0f};
    std::atomic<float> rmsLevel_{0.0f};
    std::atomic<float> gain_{1.0f};

    // Lock-free single-producer/single-consumer ring buffer of float samples
    // carrying processed audio from the input callback to the output callback.
    std::vector<float> fifo_;
    int fifoCapacity_ = 0;          // in samples
    std::atomic<int> fifoWrite_{0};
    std::atomic<int> fifoRead_{0};

    int channelCount_ = 1;
    int sampleRate_ = 48000;

    std::mutex lifecycleLock_;
    std::atomic<bool> running_{false};
};

#endif  // ECHOMIC_AUDIO_ENGINE_H
