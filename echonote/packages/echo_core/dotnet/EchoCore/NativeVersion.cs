namespace EchoNote.Audio;

/// <summary>
/// Checks, once, that the loaded native library has the major version this
/// binding was built against (the assembly version comes from the same
/// echo_core.h). A different major version means a function or
/// ec_vad_config changed, so calling on would read the wrong memory.
/// </summary>
internal static class NativeVersion
{
    private static readonly int ExpectedMajor =
        typeof(NativeVersion).Assembly.GetName().Version!.Major;

    private static volatile bool _checked;

    /// <exception cref="InvalidOperationException">Major versions differ.</exception>
    internal static void EnsureCompatible()
    {
        if (_checked) return;
        CheckCompatible(NativeMethods.Version(), ExpectedMajor);
        _checked = true;
    }

    internal static (int Major, int Minor, int Patch) Decode(int version) =>
        (version / 10000, version / 100 % 100, version % 100);

    internal static void CheckCompatible(int nativeVersion, int expectedMajor)
    {
        var (major, minor, patch) = Decode(nativeVersion);
        if (major != expectedMajor)
        {
            throw new InvalidOperationException(
                $"echo_core native library is {major}.{minor}.{patch}, but this binding " +
                $"expects major version {expectedMajor}. Use the native library from the " +
                "same package.");
        }
    }
}
