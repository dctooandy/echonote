# echo_core：核心改用 C++、對外維持 C API 規格

分支：`feature/echo-core-cpp`（從 `feature/echo-core-dotnet` f920fe3 開；.NET 分支尚未 merge，C# 測試要一起當回歸）
狀態：已完成（2026-10-11；決定 #3 於實作中修訂，見「決定紀錄」與「結果」）

把 `echo_core` 的內部實作從 C 改成 C++，**對外的 `echo_core.h` 一個字都不改**，四種包裝（dart:ffi、Swift、Kotlin JNI、C# P/Invoke）也不改。起因是職缺分析（鉅怡智慧「跨平台軟體開發工程師」）：JD 必要條件寫「C/C++」，他們的 SDK 是 C++ 核心；目前只有 C 與 whisper.cpp 的建置整合經驗，缺 C++ 跟其他語言交界的實作。這次做的正是 SDK 公司最常見的結構：C++ 核心＋`extern "C"` 介面＋各平台 binding。

前幾份規格：[`../feature-echo-core-dotnet/`](../feature-echo-core-dotnet/feature-echo-core-dotnet.md)（以及更早的第 1～3 週）。之後接著做「SDK 發版流程（版本號、NuGet、tag 自動發佈）」，另寫一份規格。

## 現況（寫規格時查到的）

| 項目 | 現況 |
| --- | --- |
| 原始碼 | `src/echo_core.c` 一個檔：`ec_mean_square`（int64 累加）、`ec_pcm16_to_float`、`ec_rms_pcm16`、`ec_waveform_downsample`、`struct ec_vad`（config＋noise_floor，`malloc`／`free`） |
| 建置系統（4 套，全部直接列出 `src/echo_core.c`） | Dart build hook（`hook/build.dart`，`CBuilder.library`，`std: 'c11'`）；SwiftPM（`Package.swift`，C target `CEchoCore` 指向 `src/`，`cLanguageStandard: .c11`）；JNI（`android_jni/src/main/cpp/CMakeLists.txt`，`project(... C)`、`-DANDROID_STL=none`）；.NET（根目錄 `CMakeLists.txt`，`project(echo_core C)`） |
| build hook 的 C++ 支援 | `native_toolchain_c` 0.17.6 的 `CBuilder` 支援 `language: Language.cpp` 與 `cppLinkStdLib`；**Android 預設 `c++_shared`**（需要把 `libc++_shared.so` 一起打包，hook 不會自動處理），macOS／iOS 預設 `c++` |
| App 裡的其他 C++ | `libwhisper.so`（whisper.cpp）由 Gradle 的 CMake 建置，NDK CMake 預設 `ANDROID_STL=c++_static` |
| 回歸測試 | Dart 20 項（含與純 Dart 參考實作**逐位元**比對）、Swift 6 項、JNI 4 項（模擬器）、C# 8 項（本機＋公開 repo CI 三平台） |
| 大小基準 | macOS `libecho_core.dylib`（CMake Release）33,808 bytes；Android `libecho_core.so`（arm64-v8a，hook 產物）7,464 bytes、strip 後 5,816 bytes；iOS `echo_core.framework` 108 KB（第 1 週量的） |

## 目標與範圍

### A. 原始碼

- 刪除 `src/echo_core.c`，新增：
  - `src/echo_core_impl.hpp`：`namespace echo_core`，內部 API（不對外）：`mean_square(const int16_t*, int32_t)`、`class Vad`（建構子吃 `ec_vad_config`、`bool process(const int16_t*, int32_t)`、`void reset()`；資源由 RAII 管理）。
  - `src/echo_core.cpp`：`extern "C"` 介面，實作 `echo_core.h` 的每個函式，內部呼叫 `echo_core::`。`struct ec_vad { echo_core::Vad impl; };`。
- 語言標準：C++17。
- **例外不跨出 C 介面**：核心沒有會拋例外的程式碼（不用 `operator new`、不用 `std::` 容器），所有函式 `noexcept`；`ec_vad_create` 用 `std::malloc`＋placement new，失敗回傳 NULL（決定 #3 修訂）。
- **數值結果不變**：演算法、累加型別（int64）、浮點運算順序都照搬；`sqrt` 改 `std::sqrt(double)`，同一個函式。Dart 的逐位元比對測試是驗收標準。
- 標頭 `echo_core.h` 不改（已經有 `extern "C"` 包裝與 `EC_EXPORT`）。

### B. 四套建置系統改成 C++

- **Dart build hook**：`language: Language.cpp`、`std: 'c++17'`、`sources: ['src/echo_core.cpp']`；Android 的 `cppLinkStdLib` 設 `c++_static`。
- **SwiftPM**：`CEchoCore` target 改編 `.cpp`，加 `cxxLanguageStandard: .cxx17`；`unsafeFlags` 照舊。Swift 仍只 import C 標頭。
- **JNI**：`project(echo_core_jni C CXX)`、`echo_core.cpp` 加進來（橋接檔 `echo_core_jni.c` 維持 C）、`ANDROID_STL` 從 `none` 改 `c++_static`。
- **.NET CMake**：`project(echo_core CXX)`、`CXX_STANDARD 17`。MSVC 用 `/EHsc`、靜態 C++ runtime（`MSVC_RUNTIME_LIBRARY MultiThreaded`）。
- 編譯參數維持：`-O3 -Wall -Wextra -Werror -ffp-contract=off`（clang／gcc）；`/O2 /W4 /WX`（MSVC）。

### C. 驗證

- macOS：`dart test`（20）、`swift test`（6）、`dotnet test`（8）。
- iOS：模擬器 `flutter test integration_test/echo_core_smoke_test.dart`。
- Android 模擬器：`flutter_emulator` 上 echo_core 冒煙測試＋`./gradlew connectedAndroidTest`（JNI 4 項）；`llvm-readelf -d` 確認 `libecho_core.so` 不依賴 `libc++_shared.so`。
- 公開 repo CI：Windows／macOS／Linux 綠燈。
- 記錄大小變化：macOS dylib、Android `libecho_core.so`（arm64-v8a）改前／改後。

### D. 文件

- README：開頭改成「C++ 核心、C 介面」；新增一段「為什麼對外是 C」（name mangling、例外、`std::` 型別的 ABI、各平台 C++ 標準庫的連結方式）；建置段落更新參數。
- 同步到公開 repo。

**明確不做的事**：

- 改 C API（不加錯誤碼、不加新函式）。
- 對外提供 C++ API（例如 header-only 的 C++ 包裝）。
- 用 C++20 的 `std::span`。
- 效能重新比較（演算法沒變；只在大小上記錄差異）。
- whisper 改用 build hook（仍是第 4 週候選）。

## API 異動

無。`echo_core.h` 不變。

## 資料表異動

無。

## 權限與狀態機

無。

## UI／畫面

無。

## 邊界案例與例外處理

| 情境 | 處理 |
| --- | --- |
| `ec_vad_create` 配置失敗（`std::bad_alloc`） | 在 C 介面內 catch，回傳 NULL；四種包裝現有的「NULL → 例外／nil」路徑不變 |
| 其他函式 | 不配置、不丟例外，標 `noexcept` |
| `ec_vad_destroy(NULL)` | 照舊 no-op（`delete nullptr` 本來就安全） |
| 同一個 App 裡有兩份靜態 libc++（`libwhisper.so` 與 `libecho_core.so`） | 兩邊之間沒有 C++ 物件、例外或 `std::` 型別往來，只有 C 函式呼叫，所以安全；README 註明這個前提 |
| `struct ec_vad` 在 C 端是不完整型別 | 不變；C++ 端定義成包住 `echo_core::Vad` 的 struct |

---

## 結果（2026-10-11）

- 回歸：macOS `dart test` 20 項（含逐位元比對）、`swift test` 6 項、`dotnet test` 8 項；iOS 模擬器與 Android 模擬器（`flutter_emulator`）echo_core 冒煙測試；JNI `connectedAndroidTest` 4 項。全部通過。
- 匯出符號：macOS dylib、Android `libecho_core.so`、`libecho_core_jni.so` 都只有 C（與 JNI）函式，沒有 C++ 符號；Android `.so` 只依賴 `libc.so`、`libdl.so`（不依賴 `libc++_shared.so`）。
- 實作中追加：hook 加 `-fvisibility=hidden`，Android／Linux 加 `-Wl,--exclude-libs,ALL`、`-ffunction-sections -fdata-sections -Wl,--gc-sections`（第一版 hook 產物把 `echo_core::` 與整套 libc++abi 符號都匯出了）；JNI CMake 加 `C/CXX_VISIBILITY_PRESET hidden`；`src/module.modulemap` 讓 SwiftPM 只公開 C 標頭（否則 `echo_core_impl.hpp` 被當 C module 編譯，`<cstdint>` 找不到）。

| 大小 | 改前（C） | 改後（C++） |
| --- | ---: | ---: |
| Android `libecho_core.so`，strip 後 | 5,816 | 5,832 |
| macOS `libecho_core.dylib`（CMake Release） | 33,808 | 34,064 |
| `libecho_core_jni.so`（debug，未 strip） | 36,312 | 52,816 |

## 決定紀錄

10 項待確認事項皆於 2026-10-11 採用建議，內容已寫回上方各章節：

| # | 項目 | 決定 |
| --- | --- | --- |
| 1 | C++ 標準 | C++17 |
| 2 | Android C++ 標準庫 | `c++_static`（hook 與 JNI 都是） |
| 3 | 例外 | ~~保留例外，在 C 介面 catch~~ → 2026-10-11 修訂：**核心不拋例外**，`ec_vad_create` 改用 `std::malloc`＋placement new、`ec_vad_destroy` 呼叫解構子＋`std::free`，所有函式 `noexcept`。原因：`make_unique` 版讓 Android `libecho_core.so`（strip 後，build hook 產物）從 5,816 變 214,744 bytes；另用 NDK clang 單獨編譯比較，`make_unique` 版 214,160、關掉例外 214,248、`malloc` 版 5,432，所以元兇不是例外，而是 `operator new` 把靜態 libc++／libc++abi 執行期整包拉進來；改 `malloc` 後 build hook 產物 5,832 bytes |
| 4 | MSVC runtime | 靜態（`MultiThreaded`） |
| 5 | Linux libstdc++ | 動態（預設） |
| 6 | 檔案 | `echo_core_impl.hpp`＋`echo_core.cpp` |
| 7 | ffigen | 不動 |
| 8 | Swift 編譯參數 | `cSettings` 與 `cxxSettings` 都放 |
| 9 | CI | 這次只確認 .NET 仍綠燈；Dart、Swift 進 CI 留到發版流程 |
| 10 | 大小 | 先量，明顯變大再討論 |

## 待確認事項

目前無。
