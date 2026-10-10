import CEchoCore

/// Swift wrapper over echo_core's C functions — the same C the Flutter app
/// calls through dart:ffi.
///
/// Pointers come from `withUnsafe(Mutable)BufferPointer` and are only valid
/// inside the closure; the C functions never keep them, so that is enough
/// (the Dart side has the matching rule: `.address` only in leaf calls).
public enum EchoCore {
    /// PCM16 → float in [-1, 1).
    public static func pcm16ToFloat(_ samples: [Int16]) -> [Float] {
        let n = samples.count
        guard n > 0 else { return [] }
        return samples.withUnsafeBufferPointer { input in
            [Float](unsafeUninitializedCapacity: n) { output, initialized in
                ec_pcm16_to_float(input.baseAddress, output.baseAddress, Int32(n))
                initialized = n
            }
        }
    }

    /// Normalized RMS level, 0...1.
    public static func rms(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return samples.withUnsafeBufferPointer {
            ec_rms_pcm16($0.baseAddress, Int32($0.count))
        }
    }

    /// Peak absolute value of each of `buckets` equal runs, 0...1. Returns
    /// min(`buckets`, `samples.count`) values.
    public static func waveform(_ samples: [Int16], buckets: Int) -> [Float] {
        guard !samples.isEmpty, buckets > 0 else { return [] }
        let count = min(buckets, samples.count)
        return samples.withUnsafeBufferPointer { input in
            [Float](unsafeUninitializedCapacity: count) { output, initialized in
                initialized = Int(ec_waveform_downsample(
                    input.baseAddress, Int32(input.count), output.baseAddress, Int32(count)))
            }
        }
    }
}

/// Energy-gate voice activity detector backed by a native `ec_vad`.
///
/// ARC frees the native state deterministically in `deinit`, so unlike the
/// Dart `EchoVad` (NativeFinalizer + `dispose()`) there is nothing to call.
/// Not `Sendable`: the C state is not thread-safe.
public final class EchoVAD {
    private let vad: OpaquePointer

    /// Returns nil if the native allocation fails.
    public init?(config: ec_vad_config = ec_vad_default_config()) {
        guard let vad = ec_vad_create(config) else { return nil }
        self.vad = vad
    }

    deinit {
        ec_vad_destroy(vad)
    }

    /// True when `samples` is voiced. Empty input returns false without
    /// touching the state.
    public func process(_ samples: [Int16]) -> Bool {
        guard !samples.isEmpty else { return false }
        return samples.withUnsafeBufferPointer {
            ec_vad_process(vad, $0.baseAddress, Int32($0.count)) == 1
        }
    }

    public func reset() {
        ec_vad_reset(vad)
    }
}
