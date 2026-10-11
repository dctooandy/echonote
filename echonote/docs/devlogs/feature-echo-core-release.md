# echo_core：C# 包裝、C++ 核心、SDK 發版流程 開發紀錄

分支：`feature/echo-core-dotnet` → `feature/echo-core-cpp` → `feature/echo-core-release`（同一天依序疊開，2026-10-11；三個分支都已 push，尚未 merge 進 `master`）
狀態：已完成；`v0.2.0` 已在公開 repo 發佈（<https://github.com/dctooandy/echo_core/releases/tag/v0.2.0>）

職缺分析（鉅怡智慧「跨平台軟體開發工程師」）列出三個缺口：Windows／.NET Interop、C++、SDK 的打包與發版。這份紀錄涵蓋為了補這三個缺口連續做的三個分支。

- 規格：[`feature-echo-core-dotnet`](../specs/feature-echo-core-dotnet/feature-echo-core-dotnet.md)、[`feature-echo-core-cpp`](../specs/feature-echo-core-cpp/feature-echo-core-cpp.md)、[`feature-echo-core-release`](../specs/feature-echo-core-release/feature-echo-core-release.md)
- 前一份紀錄：[`feature-echo-core-w3.md`](feature-echo-core-w3.md)
- 公開 repo：<https://github.com/dctooandy/echo_core>（monorepo 的 `packages/echo_core/` 是原始碼來源，完成後同步過去）

## 目標

- **A. C# 包裝（P/Invoke）**：C# 不經過 Flutter，用 `[LibraryImport]` 呼叫同一份核心；`fixed` 釘住 `Span` 零複製；`SafeHandle` 管 `ec_vad*`；CMake 編桌面原生庫；GitHub Actions 在 Windows／macOS／Linux 跑測試。
- **B. 核心改用 C++17、對外維持 C API**：`echo_core.h` 不改，四種包裝（dart:ffi、Swift、Kotlin JNI、C#）不改，現有測試當回歸。
- **C. SDK 發版流程**：SemVer 與 ABI 規則、`ec_version()`、ABI 匯出檢查、C# 載入時檢查主版本、NuGet 套件 `Dctooandy.EchoCore`（5 個 RID）、推 tag 自動測試／打包／驗證／發佈。

## 踩到的坑

### 一、環境

#### Homebrew 裝 .NET SDK 需要 sudo

**現象**：`brew install --cask dotnet-sdk` 失敗：`sudo: a terminal is required to read the password`。

**原因**：這個 cask 是 `.pkg` 安裝程式，要用 root 執行；Claude Code 的 shell 不能輸入密碼。

**修法**：改用官方 `dotnet-install.sh --channel 10.0 --install-dir ~/.dotnet`（不需要 sudo），在 `~/.zshrc` 加 `DOTNET_ROOT` 與 `PATH`。CMake 用 `brew install cmake`（不需要 sudo）。本機只有 .NET 10 runtime，所以 net8.0 的測試專案設 `RollForward=Major`。

#### SDK 10 的 `dotnet new console --framework net8.0` 失敗

**現象**：在本機驗證 NuGet 套件時，建 console 專案回傳結束代碼 127。

**原因**：未深究；推測是 SDK 10 的範本不接受 `net8.0`。原因待查。

**修法**：手寫 `consumer.csproj`（CI 的 verify job 也是手寫）。

### 二、C++ 改寫（`feature/echo-core-cpp`）

#### Dart build hook 讀不到目標平台

**現象**：`dart analyze hook`：`The getter 'code' isn't defined for the type 'BuildConfig'`。

**原因**：`input.config.code` 是 `package:code_assets` 提供的 extension，hook 沒有 import。

**修法**：`hook/build.dart` 加 `import 'package:code_assets/code_assets.dart';`，用 `OS.android` 判斷。

#### SwiftPM 把 C++ 標頭當成 C 編譯

**現象**：`swift test` 失敗：`echo_core_impl.hpp: 'cstdint' file not found`、`could not build Objective-C module 'CEchoCore'`。

**原因**：`Package.swift` 的 `publicHeadersPath: "."` 讓 `src/` 底下所有標頭都成為 C module 的一部分，包括只給 C++ 用的 `echo_core_impl.hpp`。

**修法**：新增 `src/module.modulemap`，只公開 `echo_core.h`。

#### Android 的 `.so` 把 C++ 內部與整套 libc++abi 都匯出了

**現象**：第一版 C++ 的 hook 產物，`llvm-readelf --dyn-syms` 除了 8 個 C 函式，還有 `echo_core::` 的 5 個函式，以及 70 多個 `std::bad_alloc`、`__cxa_throw`、`__gxx_personality_v0` 等 libc++abi 符號。

**原因**：`native_toolchain_c` 不會預設隱藏符號；靜態連結的 libc++ 符號也會被匯出。同一個 App 裡 `libwhisper.so` 也有自己的靜態 libc++，動態連結器可能讓兩邊的同名符號互相綁定。

**修法**：hook 加 `-fvisibility=hidden`；Android／Linux 加 `-Wl,--exclude-libs,ALL`、`-ffunction-sections -fdata-sections -Wl,--gc-sections`。JNI 的 CMake 加 `C/CXX_VISIBILITY_PRESET hidden`。之後只匯出 8 個 C 函式。

#### Android 的 `.so` 大了 37 倍，原因不是例外

**現象**：Android `libecho_core.so`（strip 後，hook 產物）從 C 版 5,816 bytes 變成 214,744 bytes。

**原因**：用 NDK clang 以同樣參數單獨編譯比較：`make_unique`＋`try`／`catch` 214,160 bytes；同一份程式關掉例外（`-fno-exceptions -fno-rtti`，配置改 `new (std::nothrow)`）214,248 bytes，幾乎沒變；`malloc`＋placement new 5,432 bytes。所以元兇是 `operator new`：靜態連結時它把 libc++／libc++abi 的執行期（例外處理、型別資訊、名稱還原器）整包拉進來。

**修法**：`ec_vad_create` 改 `std::malloc`＋placement new，`ec_vad_destroy` 呼叫解構子＋`std::free`；核心不用 `operator new`、不用 `std::` 容器、不拋例外，所有函式 `noexcept`（規格決定 #3 由「在交界 catch」修訂為「核心不拋例外」）。hook 產物回到 5,832 bytes。

#### Android build hook 預設 `c++_shared`

**現象**：寫規格時讀 `native_toolchain_c` 0.17.6 原始碼發現：Android 預設連結 `c++_shared`。沒有實際遇到錯誤。

**原因**：`c++_shared` 要把 `libc++_shared.so` 一起打包進 APK，hook 不會處理。

**修法**：hook 的 `cppLinkStdLib` 在 Android 設 `c++_static`，跟 whisper（NDK CMake 預設）一致。`llvm-readelf -d` 確認只依賴 `libc.so`、`libdl.so`。

### 三、發版流程（`feature/echo-core-release`）

#### NuGet 套件裡原生庫的路徑重複一層

**現象**：本機 `dotnet pack` 出來的套件裡是 `runtimes/osx-arm64/native/osx-arm64/native/libecho_core.dylib`。

**原因**：`PackagePath="runtimes/%(RecursiveDir)"` 時，NuGet 自己又附加了一次 `RecursiveDir`。

**修法**：改成 `PackagePath="runtimes"`。全新 console 專案安裝本機套件後執行，輸出 `version=0.2.0 rms=0.5`。

#### Windows runner 的兩個預先處理

**現象**：沒有實際遇到，寫 workflow 時預先處理：Windows runner 有 `python` 沒有 `python3`；Windows 上 `dotnet run` 的輸出行尾是 `\r\n`，用 bash 比對字串會失敗。

**修法**：依 `RUNNER_OS` 選 `python`／`python3`；比對前 `tr -d '\r'`。CI 與 release 第一次就全綠。

#### 同步到公開 repo 時蓋掉了授權與說明

**現象**：把 monorepo 的套件檔案整批複製到公開 repo 後，`LICENSE` 變回範本的 `TODO`，`pubspec.yaml` 的說明與 `publish_to: none` 也被蓋掉。

**原因**：公開 repo 第一次建立時，這兩個檔案是在公開 repo 那邊改的，monorepo 沒有同步。

**修法**：在公開 repo 修回，並把 monorepo 的 `LICENSE`（MIT）與 `pubspec.yaml` 改成一致，之後整批複製不會再蓋掉。

#### README 的大小比較表混用兩種建置來源

**現象**：寫這份紀錄時核對數字發現：README 表格的「`make_unique` 214,744」是 hook 產物，「關掉例外 214,248」是 NDK clang 單獨編譯，放在同一欄。

**修法**：表格拆成「Flutter build hook 產物」與「NDK clang 單獨編譯」兩欄，註明只比同一欄。結論不變。

---

## 測試方法

- **macOS 本機**：`dart test` 21 項（含與純 Dart 參考實作逐位元比對，C++ 改寫後結果不變）、`swift test` 7 項、`dotnet test` 10 項。
- **iOS 模擬器（iPhone 15）、Android 模擬器（`flutter_emulator`，arm64、Android 13）**：`integration_test/echo_core_smoke_test.dart` 通過。
- **JNI**：`./gradlew connectedAndroidTest` 5 項（含版本與標頭一致）。
- **匯出符號與相依**：`nm -gU`（macOS）、`llvm-readelf --dyn-syms`／`-d`（Android）；CI 用 `scripts/check_exports.py`（Windows 直接讀 PE 匯出表）比對 `abi/exports.txt` 的 9 個符號。
- **公開 repo CI**：`ci.yml` 7 個 job（Dart macOS／Linux、Swift、.NET 三平台＋匯出檢查、版本一致性）。`release.yml` 在 `v0.2.0-rc.1` 與 `v0.2.0` 各跑一次，19 個 job 全綠：5 個 RID 的原生庫建置（含架構檢查）、打包並確認 5 個原生庫都在、在 Windows／macOS／Linux x64／Linux arm64 各建全新 console 專案安裝套件並執行、建 GitHub Release、推 GitHub Packages。
- **大小**：

| | 改前 | 改後 |
| --- | ---: | ---: |
| Android `libecho_core.so`（strip 後，hook 產物） | 5,816（C） | 5,832（C++） |
| macOS `libecho_core.dylib`（CMake Release） | 33,808（C） | 34,064（C++） |
| `libecho_core_jni.so`（debug，未 strip） | 36,312（C） | 52,816（C++） |

## 待辦／已知限制

- 三個分支疊在一起，都還沒 merge 進 `master`；第 3 週的 Android 實機項目（2026-10-12）也還沒做。
- `osx-x64` 在 arm64 runner 上交叉編譯，CI 只驗證建置與架構（`lipo -info`），沒有實際執行。
- GitHub Packages 的 NuGet 即使是公開套件，使用者也要用 GitHub 帳號設定來源才能還原；不用登入的下載只有 GitHub Release 的 `.nupkg`。nuget.org 之後再加。
- 核心不能用會配置記憶體的 `std::` 容器，否則 Android 又會把 libc++ 拉回來。
- Windows 不要求跟其他平台逐位元相同（MSVC 用 `/fp:precise`，測試只比已知值）。
- `win-arm64`、32 位元不支援；Android 只建 `arm64-v8a`。
- 公開 repo 靠手動整批複製同步，沒有自動化。
- `dotnet new console --framework net8.0` 在 SDK 10 失敗的原因待查。
