using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace EchoNote.Audio;

/// <summary>
/// ec_vad_config. Field order and types match echo_core.h, so it is passed
/// to and returned from C by value without marshalling.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
public struct EcVadConfig
{
    public float InitialNoiseFloor;
    public float RmsMin;
    public float VoiceRatio;
    public float NoiseFloorCap;
    public float FallRate;
    public float RiseRate;

    /// <summary>The defaults from echo_core.h (ec_vad_default_config).</summary>
    public static EcVadConfig Default => NativeMethods.VadDefaultConfig();
}

/// <summary>
/// Owns a native ec_vad*. The runtime keeps it alive while a call is using
/// it, and its finalizer calls ec_vad_destroy if Dispose was never called.
/// </summary>
internal sealed class EchoVadHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    // The LibraryImport generator creates the handle through this.
    public EchoVadHandle() : base(ownsHandle: true) { }

    protected override bool ReleaseHandle()
    {
        NativeMethods.VadDestroy(handle);
        return true;
    }
}

/// <summary>
/// Energy-gate voice activity detector backed by a native ec_vad. Release it
/// with <see cref="Dispose"/> (or <c>using</c>), like the Dart EchoVad's
/// dispose() and Kotlin's close(). Not thread-safe.
/// </summary>
public sealed class EchoVad : IDisposable
{
    private readonly EchoVadHandle _handle;

    public EchoVad() : this(EcVadConfig.Default) { }

    /// <exception cref="OutOfMemoryException">ec_vad_create returned NULL.</exception>
    public EchoVad(EcVadConfig config)
    {
        _handle = NativeMethods.VadCreate(config);
        if (_handle.IsInvalid)
        {
            _handle.Dispose();
            throw new OutOfMemoryException("ec_vad_create failed.");
        }
    }

    /// <summary>True when the chunk is voiced. Empty input returns false.</summary>
    /// <exception cref="ObjectDisposedException">Called after Dispose.</exception>
    public unsafe bool Process(ReadOnlySpan<short> samples)
    {
        ObjectDisposedException.ThrowIf(_handle.IsClosed, this);
        if (samples.IsEmpty) return false;
        fixed (short* input = samples)
        {
            return NativeMethods.VadProcess(_handle, input, samples.Length) == 1;
        }
    }

    /// <summary>Puts the noise floor back to its initial value.</summary>
    /// <exception cref="ObjectDisposedException">Called after Dispose.</exception>
    public void Reset()
    {
        ObjectDisposedException.ThrowIf(_handle.IsClosed, this);
        NativeMethods.VadReset(_handle);
    }

    /// <summary>Frees the native state. Safe to call more than once.</summary>
    public void Dispose() => _handle.Dispose();
}
