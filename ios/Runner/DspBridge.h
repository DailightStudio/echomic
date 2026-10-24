#ifndef ECHOMIC_DSP_BRIDGE_H
#define ECHOMIC_DSP_BRIDGE_H

#include <stdbool.h>

// Plain C API over the shared C++ DSP (android/app/src/main/cpp), callable
// from Swift through Runner-Bridging-Header.h. Swift sees the handle as
// OpaquePointer.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PitchCorrectorHandle PitchCorrectorHandle;

PitchCorrectorHandle* _Nonnull pc_create(void);
void pc_destroy(PitchCorrectorHandle* _Nullable h);
// Control thread only, never while pc_process may run (allocates).
void pc_prepare(PitchCorrectorHandle* _Nonnull h, float sampleRate, int channels);
void pc_reset(PitchCorrectorHandle* _Nonnull h);
// Any thread (atomic).
void pc_set_hold(PitchCorrectorHandle* _Nonnull h, bool on);
// Render thread: interleaved in-place, no allocation/locking.
void pc_process(PitchCorrectorHandle* _Nonnull h, float* _Nonnull buf, int frames, int channels);

#ifdef __cplusplus
}
#endif

#endif  // ECHOMIC_DSP_BRIDGE_H
