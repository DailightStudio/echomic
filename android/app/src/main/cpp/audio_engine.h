#ifndef ECHOMIC_AUDIO_ENGINE_H
#define ECHOMIC_AUDIO_ENGINE_H

#include <atomic>
#include <cstdint>
#include <mutex>
#include <vector>

#include <oboe/Oboe.h>

#include "echo_effect.h"
#include "compressor.h"
#include "reverb.h"
#include "high_pass_filter.h"
#include "noise_gate.h"
#include "frequency_shifter.h"
#include "eq5band.h"
#include "feedback_suppressor.h"

/**
 * Full-duplex low-latency engine built on Oboe's FullDuplexStream helper.
 *
 * The output stream is the master clock: oboe::FullDuplexStream's own
 * onAudioReady() drives the whole thing -- it drains/primes the input
 * stream's internal buffer against the output callback's cadence and then
 * hands both buffers to onBothStreamsReady(), which is where the DSP chain
 * runs in place before the result is copied to the output buffer. The input
 * stream itself has no data callback; FullDuplexStream reads it with a
 * non-blocking read() from inside the output callback.
 *
 * Both streams request AAudio LowLatency + Exclusive Float so the framework
 * can pick the fast mixer path, with Oboe's built-in automatic fallback to
 * Shared mode if Exclusive isn't available on the device.
 */
class AudioEngine : public oboe::AudioStreamErrorCallback {
public:
    AudioEngine();
    ~AudioEngine() override;

    bool start();
    void stop();

    void setGain(float gain) { gain_.store(gain); }
    void setBoost(bool enabled)       { boost_.store(enabled); }
    void setEchoDelay(float delayMs) { echo_.setDelayMs(delayMs); }
    void setEchoFeedback(float feedback) { echo_.setFeedback(feedback); }
    void setReverbWet(float wet)      { reverb_.setWet(wet); }
    void setMasterGain(float gain)    { masterGain_.store(gain); }
    void setGateThreshold(float db)         { gate_.setThresholdDb(db); }
    void setEQBand(int band, float gainDb)   { eq_.setBandGain(band, gainDb); }
    void setFrequencyShiftEnabled(bool en)   { freqShifter_.enabled.store(en); }
    float getRmsLevel() const         { return rmsLevel_.load(); }
    bool isRunning() const            { return running_.load(); }

    // oboe::AudioStreamErrorCallback (registered on the output stream only;
    // FullDuplexStream's contract is that the caller stops/closes the input
    // stream and, for ErrorDisconnected, reopens both streams).
    void onErrorAfterClose(oboe::AudioStream *stream, oboe::Result error) override;

private:
    // oboe::FullDuplexStream itself declares virtual start()/stop() methods
    // (returning oboe::Result) that would collide with AudioEngine's own
    // differently-typed, JNI-facing start()/stop() if AudioEngine inherited
    // it directly (same name+params, incompatible return type -> a hard
    // compile error, not just shadowing). So it is held as a member instead,
    // the same composition Google's own LiveEffect sample uses
    // (LiveEffectEngine holds a FullDuplexPass rather than inheriting it).
    class DuplexProcessor : public oboe::FullDuplexStream {
    public:
        explicit DuplexProcessor(AudioEngine *engine) : engine_(engine) {}
        oboe::DataCallbackResult onBothStreamsReady(const void *inputData,
                                                     int numInputFrames,
                                                     void *outputData,
                                                     int numOutputFrames) override;

    private:
        AudioEngine *engine_;
    };

    bool openStreams();
    void closeStreams();
    void runDsp(float *buf, int numFrames);
    oboe::DataCallbackResult processBothStreamsReady(const void *inputData,
                                                      int numInputFrames,
                                                      void *outputData,
                                                      int numOutputFrames);

    DuplexProcessor duplex_;

    std::shared_ptr<oboe::AudioStream> inputStream_;
    std::shared_ptr<oboe::AudioStream> outputStream_;

    EchoEffect echo_;
    Compressor comp_;
    ReverbEffect reverb_;
    HighPassFilter hpf_;
    NoiseGate gate_;
    FrequencyShifter freqShifter_;
    EQ5Band eq_;
    FeedbackSuppressor suppressor_;
    std::atomic<float> masterGain_{1.0f};
    std::atomic<float> rmsLevel_{0.0f};
    std::atomic<float> gain_{1.0f};
    // false = no amplification: input gain pinned to 1.0 and compressor bypassed entirely.
    std::atomic<bool> boost_{true};

    // Scratch buffer the DSP chain processes in place before it is copied to
    // the (read-only, from our side) output buffer. Sized once in
    // openStreams() to the output stream's buffer capacity -- never resized
    // on the audio thread.
    std::vector<float> scratch_;

    int channelCount_ = 1;
    int sampleRate_ = 48000;

    std::mutex lifecycleLock_;
    std::atomic<bool> running_{false};

    // Bumped on every start()/stop() and successful reconnect so a debounced
    // restart thread (or a stale/late error callback from an already-replaced
    // stream pair) can recognize it is no longer relevant and bail out
    // instead of acting on a torn-down engine.
    std::atomic<uint64_t> generation_{0};
};

#endif  // ECHOMIC_AUDIO_ENGINE_H
