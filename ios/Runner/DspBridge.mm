#import "DspBridge.h"

// Relative include so no HEADER_SEARCH_PATHS build setting is needed.
#include "../../android/app/src/main/cpp/pitch_corrector.h"

struct PitchCorrectorHandle {
    PitchCorrector pc;
};

PitchCorrectorHandle* pc_create(void) { return new PitchCorrectorHandle(); }

void pc_destroy(PitchCorrectorHandle* h) { delete h; }

void pc_prepare(PitchCorrectorHandle* h, float sampleRate, int channels) {
    h->pc.prepare(sampleRate, channels);
}

void pc_reset(PitchCorrectorHandle* h) { h->pc.reset(); }

void pc_set_hold(PitchCorrectorHandle* h, bool on) { h->pc.setHold(on); }

void pc_process(PitchCorrectorHandle* h, float* buf, int frames, int channels) {
    h->pc.process(buf, frames, channels);
}
