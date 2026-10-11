// echo_core's C++ implementation. Internal: nothing here crosses the library
// boundary. Callers outside the library (Dart, Swift, Kotlin, C#) only see
// the C API in echo_core.h, which echo_core.cpp implements on top of this.
// Everything is noexcept and allocation-free (see echo_core.cpp).

#ifndef ECHO_CORE_IMPL_HPP
#define ECHO_CORE_IMPL_HPP

#include <cstdint>

#include "echo_core.h"

namespace echo_core {

inline constexpr double kFullScale = 32768.0;

void pcm16_to_float(const int16_t *in, float *out, int32_t n) noexcept;

// Mean of squares in the normalized [-1, 1] scale.
double mean_square(const int16_t *in, int32_t n) noexcept;

float rms(const int16_t *in, int32_t n) noexcept;

int32_t waveform_downsample(const int16_t *in, int32_t n, float *out,
                            int32_t buckets) noexcept;

// Energy-gate voice activity detector (see ec_vad_* in echo_core.h).
class Vad {
 public:
  explicit Vad(const ec_vad_config &config) noexcept
      : config_(config), noise_floor_(config.initial_noise_floor) {}

  // True when the chunk is voiced. n <= 0 returns false and leaves the
  // state unchanged.
  bool process(const int16_t *in, int32_t n) noexcept;

  void reset() noexcept { noise_floor_ = config_.initial_noise_floor; }

 private:
  ec_vad_config config_;
  float noise_floor_;
};

}  // namespace echo_core

#endif  // ECHO_CORE_IMPL_HPP
