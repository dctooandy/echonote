# Dctooandy.EchoCore

C# bindings for [echo_core](https://github.com/dctooandy/echo_core): a small C++17 audio core behind a C API, called through P/Invoke (`[LibraryImport]`).

```csharp
using EchoNote.Audio;

short[] samples = /* 16 kHz mono PCM16 */;
float level = EchoCore.Rms(samples);
float[] floats = EchoCore.Pcm16ToFloat(samples);
float[] peaks = EchoCore.Waveform(samples, buckets: 32);

using var vad = new EchoVad();
bool voiced = vad.Process(samples);

var (major, minor, patch) = EchoCore.Version;   // version of the loaded native library
```

- Spans are pinned and passed to native code without copying.
- `EchoVad` owns native state through a `SafeHandle`; dispose it (or rely on the finalizer).
- The native library ships in `runtimes/<rid>/native/` for `win-x64`, `osx-arm64`, `osx-x64`, `linux-x64` and `linux-arm64`. On first use the binding checks that the native library's major version matches its own and throws `InvalidOperationException` otherwise.

MIT licensed. Source, versioning rules and changelog: https://github.com/dctooandy/echo_core
