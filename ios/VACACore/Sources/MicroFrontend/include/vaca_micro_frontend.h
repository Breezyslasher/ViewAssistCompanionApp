// C API over the TensorFlow Lite micro frontend, as used by microWakeWord.
// Same configuration as the Android app's microfeatures/MicroFrontend.cpp.
#ifndef VACA_MICRO_FRONTEND_H_
#define VACA_MICRO_FRONTEND_H_

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Features per 10 ms step.
#define VACA_FRONTEND_FEATURE_COUNT 40
/// Samples per 10 ms step at 16 kHz.
#define VACA_FRONTEND_SAMPLES_PER_STEP 160

typedef struct VACAMicroFrontend VACAMicroFrontend;

VACAMicroFrontend *vaca_frontend_create(void);
void vaca_frontend_destroy(VACAMicroFrontend *frontend);

/// Feeds up to `num_samples` 16 kHz mono samples. When a 10 ms step
/// completes, writes VACA_FRONTEND_FEATURE_COUNT features (already scaled
/// like the Android app: value * 0.0390625) to `features` and returns that
/// count; otherwise returns 0. `samples_read` says how many were consumed.
size_t vaca_frontend_process(VACAMicroFrontend *frontend,
                             const int16_t *samples, size_t num_samples,
                             float *features, size_t *samples_read);

#ifdef __cplusplus
}
#endif

#endif  // VACA_MICRO_FRONTEND_H_
