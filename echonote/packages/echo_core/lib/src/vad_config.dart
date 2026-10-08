/// Mirrors `ec_vad_config`. Defaults match `ec_vad_default_config()` and the
/// gate in whisper_ggml's live stream.
class EchoVadConfig {
  const EchoVadConfig({
    this.initialNoiseFloor = 0.005,
    this.rmsMin = 0.0015,
    this.voiceRatio = 2.5,
    this.noiseFloorCap = 0.01,
    this.fallRate = 0.5,
    this.riseRate = 0.0005,
  });

  final double initialNoiseFloor;
  final double rmsMin;
  final double voiceRatio;
  final double noiseFloorCap;
  final double fallRate;
  final double riseRate;
}
