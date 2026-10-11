# echo_core：.NET P/Invoke 包裝規格

分支：`feature/echo-core-dotnet`（從 `master` ccb10e8 開）
狀態：已確認（2026-10-11；11 項待確認事項皆採用建議，見「決定紀錄」）

讓 C# 不透過 Flutter，經由 P/Invoke 呼叫同一份 `echo_core` C 原始碼，跟 dart:ffi、Swift、Kotlin JNI 並列成第四種包裝。起因是職缺分析（鉅怡智慧「跨平台軟體開發工程師」）列出的缺口：JD 要求 Windows／.NET 與 .NET Interop，四週計畫原本只把 .NET P/Invoke 列為選做。今天完成，投遞前放上公開 repo。

前幾週規格：[`../feature-echo-core/`](../feature-echo-core/feature-echo-core.md)、[`../feature-echo-core-w2/`](../feature-echo-core-w2/feature-echo-core-w2.md)、[`../feature-echo-core-w3/`](../feature-echo-core-w3/feature-echo-core-w3.md)。

## 現況（寫規格時查到的）

| 項目 | 現況 |
| --- | --- |
| C API | `src/echo_core.h`：`ec_pcm16_to_float`、`ec_rms_pcm16`、`ec_waveform_downsample`、`ec_vad_default_config`、`ec_vad_create`／`process`／`reset`／`destroy`。`EC_EXPORT` 已經有 `_WIN32` 分支（`__declspec(dllexport)`），Windows 不用改標頭 |
| `ec_vad_config` | 6 個 `float`，以值傳遞；`ec_vad_default_config()` 以值回傳 |
| 既有包裝 | dart:ffi（build hook）、Swift（`Package.swift`）、Kotlin JNI（`android_jni/` 的 CMake）。編譯參數都是 C11、`-O3`、`-Wall -Wextra -Werror`、`-ffp-contract=off` |
| Swift 測試 | 6 項：`pcm16ToFloat`、`rms`、`waveform` 的已知值；VAD「安靜 → 說話 → 安靜」；預設值與標頭一致；釋放 |
| 工具 | 2026-10-11 安裝：.NET SDK 10.0.401（Homebrew cask 需要 sudo，改用官方 `dotnet-install.sh` 裝在 `~/.dotnet`，只有 .NET 10 runtime）、CMake 4.4.4（Homebrew） |
| 公開 repo | `/Users/andychen/Documents/002-development/echo_core` 是從 monorepo 匯出的乾淨歷史，沒有 CI |

## 目標與範圍

### A. C# 包裝（`dotnet/` 資料夾）

- `dotnet/EchoCore/`：class library，提供跟 Swift 相同的介面：
  - `EchoCore.Pcm16ToFloat(ReadOnlySpan<short>) → float[]`
  - `EchoCore.Rms(ReadOnlySpan<short>) → float`
  - `EchoCore.Waveform(ReadOnlySpan<short>, int buckets) → float[]`
  - `EchoVad : IDisposable`：`Process(ReadOnlySpan<short>) → bool`、`Reset()`、`Dispose()`；建構子可選 `EcVadConfig`
  - `EcVadConfig`：`[StructLayout(LayoutKind.Sequential)]`，6 個 `float`，欄位順序與標頭相同；`EcVadConfig.Default` 呼叫 `ec_vad_default_config()`
- 綁定方式：`[LibraryImport]`（.NET 7 起的 source generator，編譯期產生 marshalling 程式碼）。
- 陣列傳遞：`fixed` 釘住 `ReadOnlySpan<short>` 取得指標，直接交給 C，不複製；C 函式不保留指標，所以 `fixed` 區塊結束就安全。對應 dart:ffi 的 leaf call、Swift 的 `withUnsafeBufferPointer`、JNI 的 `GetPrimitiveArrayCritical`。
- VAD 的原生指標：`EchoVadHandle : SafeHandleZeroOrMinusOneIsInvalid`，`ReleaseHandle()` 呼叫 `ec_vad_destroy`。`EchoVad.Dispose()` 釋放 handle；忘了 `Dispose` 時由 SafeHandle 的 finalizer 釋放。`ec_vad_create` 回傳 NULL 時建構子丟 `OutOfMemoryException`。
- 執行緒：`EchoVad` 不是執行緒安全，文件註明；不加鎖。

### B. 原生程式庫建置

- 在套件根目錄新增 `CMakeLists.txt`，把 `src/echo_core.c` 編成共享庫 `echo_core`（macOS `libecho_core.dylib`、Linux `libecho_core.so`、Windows `echo_core.dll`）。
- 編譯參數與其他包裝一致：clang／gcc 用 `-O3 -Wall -Wextra -Werror -ffp-contract=off`；MSVC 用 `/O2 /W4 /WX`，浮點用預設的 `/fp:precise`。
- `dotnet test` 前自動建置原生庫，產物複製到測試的輸出目錄。

### C. 測試（`dotnet/EchoCore.Tests/`）

- xUnit，案例跟 Swift 的 6 項相同（已知值、VAD 序列、預設值、釋放），另加：
  - `Dispose()` 兩次不出錯；`Dispose()` 後呼叫 `Process` 丟 `ObjectDisposedException`。
  - 空輸入：`Rms` 回 0、`Pcm16ToFloat` 回空陣列、`Waveform` 的 `buckets <= 0` 回空陣列。
- macOS 本機 `dotnet test` 通過。

### D. CI（GitHub Actions，只放公開 repo）

- `.github/workflows/dotnet.yml`：matrix `windows-latest`、`macos-latest`、`ubuntu-latest`，各自 CMake 建置原生庫 → `dotnet test`。Windows 這一格是唯一能證明「Windows 上真的能跑」的地方（本機沒有 Windows）。

### E. 文件

- README：包裝對照表加 C#（P/Invoke）一欄；新增「C#（P/Invoke）包裝」段落（用法、記憶體所有權、建置與測試指令、`LibraryImport` 與 `DllImport` 的差別一句話）；開頭的平台清單加上 Windows／Linux（.NET）。
- CI badge 放 README 開頭（有 CI 才放）。

### F. 同步

- monorepo 的 `packages/echo_core/` 是原始碼來源；完成後把 `dotnet/`、`CMakeLists.txt`、README、`.gitignore` 同步到公開 repo，CI 設定只放公開 repo。

**明確不做的事**：

- NuGet 套件打包與發佈（`runtimes/<rid>/native` 多平台打包）。只在 README 提一句「之後的方向」。
- 效能比較（C vs 純 C#）。
- Xamarin、MAUI、React Native。
- 32 位元（x86）。只建置 64 位元：x64、arm64。
- echonote App 不使用這個包裝。

## API 異動

無（不涉及後端）。對外的程式介面見「目標與範圍 A」。

## 資料表異動

無。

## 權限與狀態機

無。

## UI／畫面

無。

## 邊界案例與例外處理

| 情境 | 處理 |
| --- | --- |
| 輸入長度為 0 | 不進 `fixed`，直接回 0／空陣列，與 Swift 一致 |
| 輸入長度超過 `int.MaxValue` | `Span` 長度本來就是 `int`，不會發生；不另外處理 |
| `buckets` 大於樣本數 | 依 C 的規則，回傳 `min(buckets, n)` 個值；輸出陣列先配 `min(buckets, n)` 個 |
| 找不到原生庫 | 第一次呼叫丟 `DllNotFoundException`，README 寫明要先建置原生庫 |
| 原生庫的 CPU 架構不符（例如 x64 的 .NET 載入 arm64 的 dylib） | `BadImageFormatException`；README 寫明 CMake 與 .NET 要同一個架構 |
| `EchoVad` 忘了 `Dispose` | SafeHandle 的 finalizer 會釋放；不會洩漏，但釋放時機不確定 |
| `Dispose` 後再使用 | 丟 `ObjectDisposedException` |
| `ec_vad_create` 失敗 | 建構子丟 `OutOfMemoryException` |
| 多執行緒共用一個 `EchoVad` | 不支援，文件註明 |

---

## 決定紀錄

11 項待確認事項皆於 2026-10-11 採用建議，內容已寫回上方各章節：

| # | 項目 | 決定 |
| --- | --- | --- |
| 1 | 綁定方式 | `[LibraryImport]`；README 對照說明 `DllImport` |
| 2 | 原生庫建置 | CMake，三平台共用一份 |
| 3 | MSVC 浮點 | 用預設 `/fp:precise`；Windows 不要求跨平台逐位元相同，測試只比已知值 |
| 4 | 原生庫進測試 | 測試專案的 MSBuild target 在建置前呼叫 CMake |
| 5 | CI | 今天做，只跑 .NET（Windows／macOS／Linux）；其他包裝的 CI 留第 4 週 |
| 6 | 開發位置 | monorepo 開發，完成後同步到公開 repo；CI 設定只放公開 repo |
| 7 | 目標框架 | library `net8.0`；測試專案 `net8.0`＋`RollForward=Major` |
| 8 | `Pcm16ToFloat` 多載 | 加寫進呼叫端 `Span<float>` 的版本，長度不符丟 `ArgumentException` |
| 9 | unsafe | library 開 `AllowUnsafeBlocks`，unsafe 只在內部 |
| 10 | README 的 Windows 宣稱 | CI 綠燈後才寫「Windows 已驗證」與 badge |
| 11 | 履歷 | CI 綠燈後才加 C#（P/Invoke）與 GitHub Actions |

## 待確認事項

目前無。
