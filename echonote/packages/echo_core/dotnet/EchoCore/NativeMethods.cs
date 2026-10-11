using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace EchoNote.Audio;

/// <summary>
/// P/Invoke bindings to echo_core.h. [LibraryImport] generates the
/// marshalling at compile time; every parameter here is blittable (pointers,
/// ints, a struct of floats) except the SafeHandle, so the generated code
/// only adds the handle's reference counting.
/// </summary>
internal static unsafe partial class NativeMethods
{
    // Resolved to echo_core.dll, libecho_core.so or libecho_core.dylib.
    private const string Lib = "echo_core";

    [LibraryImport(Lib, EntryPoint = "ec_version")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial int Version();

    [LibraryImport(Lib, EntryPoint = "ec_pcm16_to_float")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial void Pcm16ToFloat(short* input, float* output, int n);

    [LibraryImport(Lib, EntryPoint = "ec_rms_pcm16")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial float RmsPcm16(short* input, int n);

    [LibraryImport(Lib, EntryPoint = "ec_waveform_downsample")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial int WaveformDownsample(short* input, int n, float* output, int buckets);

    [LibraryImport(Lib, EntryPoint = "ec_vad_default_config")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial EcVadConfig VadDefaultConfig();

    [LibraryImport(Lib, EntryPoint = "ec_vad_create")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial EchoVadHandle VadCreate(EcVadConfig config);

    [LibraryImport(Lib, EntryPoint = "ec_vad_process")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial int VadProcess(EchoVadHandle vad, short* input, int n);

    [LibraryImport(Lib, EntryPoint = "ec_vad_reset")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial void VadReset(EchoVadHandle vad);

    // Takes the raw pointer: only EchoVadHandle.ReleaseHandle calls it.
    [LibraryImport(Lib, EntryPoint = "ec_vad_destroy")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial void VadDestroy(nint vad);
}
