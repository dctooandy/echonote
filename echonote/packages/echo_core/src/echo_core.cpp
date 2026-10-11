// echo_core: C++ inside, C at the boundary.
//
// The functions in echo_core.h are the only exported symbols. They are
// declared extern "C" (in the header) so their names are not mangled, and
// they keep C++ out of the ABI: no exceptions, std:: types or classes cross
// it, so any compiler, any C++ standard library (or none, for Dart, Swift,
// Kotlin and C#) can call them.
//
// The core also stays off the C++ runtime: no operator new, no std::
// containers, nothing that throws. Using any of those would link
// libc++/libc++abi statically into the Android library (see ec_vad_create).

#include "echo_core.h"

#include <cmath>
#include <cstdlib>
#include <new>

#include "echo_core_impl.hpp"

// The C side only ever sees a pointer to this (an incomplete type there).
struct ec_vad {
  echo_core::Vad impl;
};

namespace echo_core {

void pcm16_to_float(const int16_t *in, float *out, int32_t n) noexcept {
  for (int32_t i = 0; i < n; i++) {
    out[i] = static_cast<float>(in[i]) / 32768.0f;
  }
}

// Sums s*s as exact integers: each square fits in 31 bits and int64 holds
// two hours of them (~1.2e8 * 2^30) with room to spare. Integer addition is
// associative, so the compiler may vectorize the loop (a double sum's order
// is fixed, which would keep it scalar), and the result is exact rather
// than rounded per step.
double mean_square(const int16_t *in, int32_t n) noexcept {
  int64_t sum = 0;
  for (int32_t i = 0; i < n; i++) {
    const int32_t s = in[i];
    sum += s * s;
  }
  return static_cast<double>(sum) / (static_cast<double>(n) * kFullScale * kFullScale);
}

float rms(const int16_t *in, int32_t n) noexcept {
  if (n <= 0) return 0.0f;
  return static_cast<float>(std::sqrt(mean_square(in, n)));
}

int32_t waveform_downsample(const int16_t *in, int32_t n, float *out,
                            int32_t buckets) noexcept {
  if (n <= 0 || buckets <= 0) return 0;
  const int32_t count = buckets < n ? buckets : n;
  for (int32_t b = 0; b < count; b++) {
    // 64-bit so b * n can't overflow for long inputs.
    const int64_t start = static_cast<int64_t>(b) * n / count;
    const int64_t end = static_cast<int64_t>(b + 1) * n / count;
    int32_t peak = 0;
    for (int64_t i = start; i < end; i++) {
      const int32_t v = in[i] < 0 ? -static_cast<int32_t>(in[i]) : in[i];  // -32768 -> 32768
      if (v > peak) peak = v;
    }
    out[b] = static_cast<float>(peak / kFullScale);
  }
  return count;
}

bool Vad::process(const int16_t *in, int32_t n) noexcept {
  if (n <= 0) return false;
  const float level = static_cast<float>(std::sqrt(mean_square(in, n)));

  // Falls quickly, rises slowly: tracks room tone without absorbing speech.
  const float rate = level < noise_floor_ ? config_.fall_rate : config_.rise_rate;
  noise_floor_ += rate * (level - noise_floor_);
  if (noise_floor_ > config_.noise_floor_cap) noise_floor_ = config_.noise_floor_cap;

  const float ratio_threshold = config_.voice_ratio * noise_floor_;
  const float threshold = ratio_threshold > config_.rms_min ? ratio_threshold : config_.rms_min;
  return level >= threshold;
}

}  // namespace echo_core

extern "C" {

int32_t ec_version(void) {
  return EC_VERSION_MAJOR * 10000 + EC_VERSION_MINOR * 100 + EC_VERSION_PATCH;
}

void ec_pcm16_to_float(const int16_t *in, float *out, int32_t n) {
  echo_core::pcm16_to_float(in, out, n);
}

float ec_rms_pcm16(const int16_t *in, int32_t n) { return echo_core::rms(in, n); }

int32_t ec_waveform_downsample(const int16_t *in, int32_t n, float *out, int32_t buckets) {
  return echo_core::waveform_downsample(in, n, out, buckets);
}

ec_vad_config ec_vad_default_config(void) {
  ec_vad_config config;
  config.initial_noise_floor = 0.005f;
  config.rms_min = 0.0015f;
  config.voice_ratio = 2.5f;
  config.noise_floor_cap = 0.01f;
  config.fall_rate = 0.5f;
  config.rise_rate = 0.0005f;
  return config;
}

// The only function that allocates. malloc plus placement new instead of
// `new`: operator new can throw, and on Android (static libc++) using it
// links libc++/libc++abi's exception runtime into the library, ~210 KB
// against ~5 KB without it. Nothing in the core throws, so no exception can
// reach a C, Dart, Swift, Kotlin or C# caller; failure is the NULL the
// header documents.
ec_vad *ec_vad_create(ec_vad_config config) {
  void *memory = std::malloc(sizeof(ec_vad));
  if (memory == nullptr) return nullptr;
  return new (memory) ec_vad{echo_core::Vad(config)};
}

int32_t ec_vad_process(ec_vad *vad, const int16_t *in, int32_t n) {
  return vad->impl.process(in, n) ? 1 : 0;
}

void ec_vad_reset(ec_vad *vad) { vad->impl.reset(); }

void ec_vad_destroy(ec_vad *vad) {
  if (vad == nullptr) return;
  vad->~ec_vad();  // Pairs with the placement new above.
  std::free(vad);
}

}  // extern "C"
