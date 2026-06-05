#include <jni.h>

#include <memory>

#include "audio_engine.h"

// Single process-wide engine instance shared by all JNI calls.
static std::unique_ptr<AudioEngine> gEngine;

extern "C" {

JNIEXPORT jint JNI_OnLoad(JavaVM * /*vm*/, void * /*reserved*/) {
    return JNI_VERSION_1_6;
}

JNIEXPORT jboolean JNICALL
Java_com_dailightstudio_echomic_AudioEnginePlugin_nativeStart(JNIEnv * /*env*/,
                                                              jobject /*thiz*/) {
    if (!gEngine) {
        gEngine = std::make_unique<AudioEngine>();
    }
    return gEngine->start() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_dailightstudio_echomic_AudioEnginePlugin_nativeStop(JNIEnv * /*env*/,
                                                             jobject /*thiz*/) {
    if (gEngine) {
        gEngine->stop();
    }
}

JNIEXPORT void JNICALL
Java_com_dailightstudio_echomic_AudioEnginePlugin_nativeSetGain(JNIEnv * /*env*/,
                                                               jobject /*thiz*/,
                                                               jfloat gain) {
    if (gEngine) {
        gEngine->setGain(static_cast<float>(gain));
    }
}

JNIEXPORT void JNICALL
Java_com_dailightstudio_echomic_AudioEnginePlugin_nativeSetEchoDelay(
    JNIEnv * /*env*/, jobject /*thiz*/, jfloat delayMs) {
    if (gEngine) {
        gEngine->setEchoDelay(static_cast<float>(delayMs));
    }
}

JNIEXPORT void JNICALL
Java_com_dailightstudio_echomic_AudioEnginePlugin_nativeSetEchoFeedback(
    JNIEnv * /*env*/, jobject /*thiz*/, jfloat feedback) {
    if (gEngine) {
        gEngine->setEchoFeedback(static_cast<float>(feedback));
    }
}

JNIEXPORT jfloat JNICALL
Java_com_dailightstudio_echomic_AudioEnginePlugin_nativeGetRmsLevel(JNIEnv * /*env*/,
                                                                     jobject /*thiz*/) {
    return gEngine ? static_cast<jfloat>(gEngine->getRmsLevel()) : 0.0f;
}

JNIEXPORT jboolean JNICALL
Java_com_dailightstudio_echomic_AudioEnginePlugin_nativeIsRunning(JNIEnv * /*env*/,
                                                                   jobject /*thiz*/) {
    return (gEngine && gEngine->isRunning()) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_dailightstudio_echomic_AudioEnginePlugin_nativeSetReverbWet(JNIEnv * /*env*/,
                                                                      jobject /*thiz*/,
                                                                      jfloat wet) {
    if (gEngine) gEngine->setReverbWet(static_cast<float>(wet));
}

JNIEXPORT void JNICALL
Java_com_dailightstudio_echomic_AudioEnginePlugin_nativeSetMasterGain(JNIEnv * /*env*/,
                                                                       jobject /*thiz*/,
                                                                       jfloat gain) {
    if (gEngine) gEngine->setMasterGain(static_cast<float>(gain));
}

}  // extern "C"
