// Port of the Android app's microfeatures/src/main/cpp/MicroFrontend.cpp
// (Copyright 2025 Mark Parker, Apache-2.0) without the JNI layer.
#include "vaca_micro_frontend.h"

#include <stdlib.h>

#include "tensorflow/lite/experimental/microfrontend/lib/frontend.h"
#include "tensorflow/lite/experimental/microfrontend/lib/frontend_util.h"

#define FEATURES_STEP_SIZE 10
#define FEATURE_DURATION_MS 30
#define AUDIO_SAMPLE_FREQUENCY 16000
#define FLOAT32_SCALE 0.0390625f

struct VACAMicroFrontend {
  struct FrontendConfig config;
  struct FrontendState state;
};

VACAMicroFrontend *vaca_frontend_create(void) {
  VACAMicroFrontend *f = (VACAMicroFrontend *)calloc(1, sizeof(VACAMicroFrontend));
  if (f == NULL) return NULL;

  f->config.window.size_ms = FEATURE_DURATION_MS;
  f->config.window.step_size_ms = FEATURES_STEP_SIZE;
  f->config.filterbank.num_channels = VACA_FRONTEND_FEATURE_COUNT;
  f->config.filterbank.lower_band_limit = 125.0f;
  f->config.filterbank.upper_band_limit = 7500.0f;
  f->config.noise_reduction.smoothing_bits = 10;
  f->config.noise_reduction.even_smoothing = 0.025f;
  f->config.noise_reduction.odd_smoothing = 0.06f;
  f->config.noise_reduction.min_signal_remaining = 0.05f;
  f->config.pcan_gain_control.enable_pcan = 1;
  f->config.pcan_gain_control.strength = 0.95f;
  f->config.pcan_gain_control.offset = 80.0f;
  f->config.pcan_gain_control.gain_bits = 21;
  f->config.log_scale.enable_log = 1;
  f->config.log_scale.scale_shift = 6;

  if (!FrontendPopulateState(&f->config, &f->state, AUDIO_SAMPLE_FREQUENCY)) {
    free(f);
    return NULL;
  }
  return f;
}

void vaca_frontend_destroy(VACAMicroFrontend *f) {
  if (f == NULL) return;
  FrontendFreeStateContents(&f->state);
  free(f);
}

size_t vaca_frontend_process(VACAMicroFrontend *f, const int16_t *samples,
                             size_t num_samples, float *features,
                             size_t *samples_read) {
  *samples_read = 0;
  if (f == NULL || num_samples == 0) return 0;
  struct FrontendOutput out =
      FrontendProcessSamples(&f->state, samples, num_samples, samples_read);
  for (size_t i = 0; i < out.size; ++i) {
    features[i] = (float)out.values[i] * FLOAT32_SCALE;
  }
  return out.size;
}
