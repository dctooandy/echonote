#include "echo_core.h"

#include <math.h>
#include <stdlib.h>

#define EC_FULL_SCALE 32768.0

void ec_pcm16_to_float(const int16_t *in, float *out, int32_t n) {
  for (int32_t i = 0; i < n; i++) {
    out[i] = (float)in[i] / 32768.0f;
  }
}

// Mean of squares in the normalized [-1, 1] scale. Sums s*s as exact
// integers: each square fits in 31 bits and int64 holds two hours of them
// (~1.2e8 * 2^30) with room to spare. Integer addition is associative, so
// the compiler may vectorize the loop (a double sum's order is fixed, which
// would keep it scalar), and the result is exact rather than rounded per step.
static double ec_mean_square(const int16_t *in, int32_t n) {
  int64_t sum = 0;
  for (int32_t i = 0; i < n; i++) {
    const int32_t s = in[i];
    sum += s * s;
  }
  return (double)sum / ((double)n * EC_FULL_SCALE * EC_FULL_SCALE);
}

float ec_rms_pcm16(const int16_t *in, int32_t n) {
  if (n <= 0) return 0.0f;
  return (float)sqrt(ec_mean_square(in, n));
}

int32_t ec_waveform_downsample(const int16_t *in, int32_t n, float *out, int32_t buckets) {
  if (n <= 0 || buckets <= 0) return 0;
  const int32_t count = buckets < n ? buckets : n;
  for (int32_t b = 0; b < count; b++) {
    // 64-bit so b * n can't overflow for long inputs.
    const int64_t start = (int64_t)b * n / count;
    const int64_t end = (int64_t)(b + 1) * n / count;
    int32_t peak = 0;
    for (int64_t i = start; i < end; i++) {
      const int32_t v = in[i] < 0 ? -(int32_t)in[i] : in[i];  // -32768 -> 32768
      if (v > peak) peak = v;
    }
    out[b] = (float)(peak / EC_FULL_SCALE);
  }
  return count;
}

struct ec_vad {
  ec_vad_config config;
  float noise_floor;
};

ec_vad_config ec_vad_default_config(void) {
  const ec_vad_config config = {
      .initial_noise_floor = 0.005f,
      .rms_min = 0.0015f,
      .voice_ratio = 2.5f,
      .noise_floor_cap = 0.01f,
      .fall_rate = 0.5f,
      .rise_rate = 0.0005f,
  };
  return config;
}

ec_vad *ec_vad_create(ec_vad_config config) {
  ec_vad *vad = malloc(sizeof(ec_vad));
  if (vad == NULL) return NULL;
  vad->config = config;
  vad->noise_floor = config.initial_noise_floor;
  return vad;
}

int32_t ec_vad_process(ec_vad *vad, const int16_t *in, int32_t n) {
  if (n <= 0) return 0;
  const ec_vad_config *c = &vad->config;
  const float rms = (float)sqrt(ec_mean_square(in, n));

  // Falls quickly, rises slowly: tracks room tone without absorbing speech.
  const float rate = rms < vad->noise_floor ? c->fall_rate : c->rise_rate;
  vad->noise_floor += rate * (rms - vad->noise_floor);
  if (vad->noise_floor > c->noise_floor_cap) vad->noise_floor = c->noise_floor_cap;

  const float ratio_threshold = c->voice_ratio * vad->noise_floor;
  const float threshold = ratio_threshold > c->rms_min ? ratio_threshold : c->rms_min;
  return rms >= threshold ? 1 : 0;
}

void ec_vad_reset(ec_vad *vad) { vad->noise_floor = vad->config.initial_noise_floor; }

void ec_vad_destroy(ec_vad *vad) { free(vad); }
