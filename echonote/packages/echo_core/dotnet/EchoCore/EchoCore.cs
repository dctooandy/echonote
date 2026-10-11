namespace EchoNote.Audio;

/// <summary>
/// echo_core's stateless functions. Spans are pinned with <c>fixed</c> and
/// handed to C without copying; the C functions never keep the pointer, so
/// it only has to stay valid for the call (the same rule as a dart:ffi leaf
/// call, Swift's withUnsafeBufferPointer and JNI's GetPrimitiveArrayCritical).
/// Safe on any thread.
/// </summary>
public static class EchoCore
{
    /// <summary>
    /// Version of the loaded native library (SemVer), from ec_version(). Not
    /// version-checked, so it also works for diagnosing a mismatch.
    /// </summary>
    public static (int Major, int Minor, int Patch) Version =>
        NativeVersion.Decode(NativeMethods.Version());

    /// <summary>PCM16 to float in [-1, 1).</summary>
    public static float[] Pcm16ToFloat(ReadOnlySpan<short> samples)
    {
        var output = new float[samples.Length];
        Pcm16ToFloat(samples, output);
        return output;
    }

    /// <summary>
    /// PCM16 to float in [-1, 1), written into <paramref name="destination"/>
    /// so a caller can reuse one buffer instead of allocating per call.
    /// </summary>
    /// <exception cref="ArgumentException">Lengths differ.</exception>
    public static unsafe void Pcm16ToFloat(ReadOnlySpan<short> samples, Span<float> destination)
    {
        if (destination.Length != samples.Length)
        {
            throw new ArgumentException(
                $"destination has {destination.Length} elements; samples has {samples.Length}.",
                nameof(destination));
        }
        if (samples.IsEmpty) return;
        NativeVersion.EnsureCompatible();
        fixed (short* input = samples)
        fixed (float* output = destination)
        {
            NativeMethods.Pcm16ToFloat(input, output, samples.Length);
        }
    }

    /// <summary>Normalized RMS level, 0..1. Empty input returns 0.</summary>
    public static unsafe float Rms(ReadOnlySpan<short> samples)
    {
        if (samples.IsEmpty) return 0;
        NativeVersion.EnsureCompatible();
        fixed (short* input = samples)
        {
            return NativeMethods.RmsPcm16(input, samples.Length);
        }
    }

    /// <summary>
    /// Peak absolute value (0..1) of each of <paramref name="buckets"/> equal
    /// runs. Returns min(buckets, samples.Length) values; empty when either
    /// is not positive.
    /// </summary>
    public static unsafe float[] Waveform(ReadOnlySpan<short> samples, int buckets)
    {
        if (samples.IsEmpty || buckets <= 0) return [];
        NativeVersion.EnsureCompatible();
        var output = new float[Math.Min(buckets, samples.Length)];
        int written;
        fixed (short* input = samples)
        fixed (float* peaks = output)
        {
            written = NativeMethods.WaveformDownsample(input, samples.Length, peaks, output.Length);
        }
        return written == output.Length ? output : output[..written];
    }
}
