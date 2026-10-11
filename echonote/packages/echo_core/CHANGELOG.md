# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow [SemVer](https://semver.org/), judged by the C API's ABI: a removed or changed function or `ec_vad_config` field is a major version, an added function a minor version, anything else a patch. Before 1.0.0 a minor version may also break the API; such changes are marked **Breaking**.

## [Unreleased]

## [0.2.0] - 2026-10-11

### Added

- `ec_version()` and `EC_VERSION_MAJOR`/`MINOR`/`PATCH` in `echo_core.h`; every wrapper exposes the version (Dart `nativeVersion()`, Swift `EchoCore.version`, Kotlin `EchoCoreJni.version()`, C# `EchoCore.Version`).
- C# (P/Invoke) wrapper in `dotnet/`, published as the NuGet package `Dctooandy.EchoCore` with native libraries for `win-x64`, `osx-arm64`, `osx-x64`, `linux-x64` and `linux-arm64`. It checks on first use that the native library's major version matches.
- `abi/exports.txt` and `scripts/check_exports.py`: CI fails when the library exports anything else.
- Root `CMakeLists.txt` for the desktop native library.

### Changed

- The core is now C++17 behind the unchanged C API. It does not use `operator new`, `std::` containers or exceptions, so the Android library does not pull in libc++'s runtime (5.8 KB instead of 214 KB).
- Android builds link `c++_static` and keep its symbols local.

## [0.0.1] - 2026-10-08

### Added

- C core: `ec_pcm16_to_float`, `ec_rms_pcm16`, `ec_waveform_downsample`, `ec_vad_*`.
- dart:ffi bindings (build hook + ffigen), Swift wrapper (SwiftPM) and Kotlin JNI wrapper.
