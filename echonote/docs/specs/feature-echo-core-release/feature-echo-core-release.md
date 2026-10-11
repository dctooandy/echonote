# echo_core：SDK 發版流程規格（版本號、NuGet、tag 自動發佈）

分支：`feature/echo-core-release`（從 `feature/echo-core-cpp` 65fc166 開；dotnet、cpp 兩個分支都尚未 merge）
狀態：已確認（2026-10-11；12 項待確認事項皆採用建議，見「決定紀錄」）

讓 echo_core 像一個對外發佈的 SDK：**有版本號與相容性規則、有可安裝的套件、推 tag 就自動測試、打包、驗證、發佈**。起因是職缺分析（鉅怡智慧「跨平台軟體開發工程師」）職務說明第 3 項「SDK Build、Packaging、Release 及 Auto Build／Deploy」與第 6 項「版本資訊」；目前只有 App 的發版經驗（GitLab CI、Xcode Cloud、Fastlane），沒有 SDK 的版本管理與套件發佈。

前幾份規格：[`../feature-echo-core-dotnet/`](../feature-echo-core-dotnet/feature-echo-core-dotnet.md)、[`../feature-echo-core-cpp/`](../feature-echo-core-cpp/feature-echo-core-cpp.md)。

## 現況（寫規格時查到的）

| 項目 | 現況 |
| --- | --- |
| 版本號 | `pubspec.yaml` 寫 `0.0.1`；`CHANGELOG.md` 只有範本的 TODO；C# 專案沒有設版本；`echo_core.h` 沒有版本資訊；公開 repo 沒有 tag |
| CI（只在公開 repo） | `.github/workflows/dotnet.yml`：push／PR 時在 Windows、macOS、Linux 跑 `dotnet test`（測試專案建置前用 CMake 編原生庫）。沒有 Dart、Swift，沒有打包與發佈 |
| 原生庫 | 根目錄 `CMakeLists.txt` 編出 `echo_core.dll`／`libecho_core.dylib`／`libecho_core.so`；MSVC 靜態 C++ runtime；Android 不在這條（走 build hook 與 JNI） |
| 對外 C API | 8 個函式（`ec_pcm16_to_float` … `ec_vad_destroy`）；四種包裝（dart:ffi、Swift、Kotlin JNI、C#）都只用這 8 個 |
| 帳號 | 公開 repo `github.com/dctooandy/echo_core`；沒有 nuget.org 帳號資訊、沒有 repo secrets |

## 目標與範圍

### A. 版本號與相容性規則

- 採 SemVer `主版本.次版本.修訂`，**C API 的 ABI 相容性決定升哪一位**：
  - 刪除或改名函式、改函式簽章、改 `ec_vad_config` 欄位（數量、順序、型別）→ 主版本（舊的 binding 會讀錯記憶體或找不到符號）。
  - 新增函式、新增常數 → 次版本。
  - 只改實作、修 bug、改文件 → 修訂版。
  - 1.0.0 之前，次版本也可以有不相容變更（SemVer 對 0.x 的慣例），CHANGELOG 要標明。
- **版本號唯一的來源是 `echo_core.h`**：新增 `EC_VERSION_MAJOR`、`EC_VERSION_MINOR`、`EC_VERSION_PATCH` 三個巨集，以及函式 `int32_t ec_version(void)`，回傳 `主*10000 + 次*100 + 修訂`（例如 0.2.0 → 200）。
  - 新增函式依上面的規則是次版本，所以第一個正式版本是 **0.2.0**。
- 其他地方的版本號由 CI 檢查是否與標頭一致：`pubspec.yaml`、C# 的 `Version`、CHANGELOG 最上面一節、release tag。不一致就失敗。
- 四種包裝各加一個讀版本的 API（Dart 頂層函式 `nativeVersion()`、Swift `EchoCore.version`、Kotlin `EchoCoreJni.version()`、C# `EchoCore.Version`），回傳 `(major, minor, patch)`。
- **C# 載入時檢查原生庫版本**：第一次呼叫前比對 `ec_version()` 的主版本與 C# 組件編譯時的主版本，不同就丟 `InvalidOperationException`，訊息寫出兩邊的版本。

### B. ABI 檢查

- 新增 `abi/exports.txt`：列出原生庫應該匯出的符號（目前 8 個＋`ec_version`）。
- CI 在三個平台用各自的工具（`nm`／`llvm-nm`、`dumpbin /exports`）列出實際匯出的符號，跟 `exports.txt` 比對：
  - **少了符號** → 失敗（ABI 被破壞）。
  - **多了符號** → 失敗（有 C++ 或內部符號外洩，正是 C++ 改寫時遇過的問題）。
- 改 `exports.txt` 本身就代表 API 變了，PR 審查時一眼看得出來。

### C. NuGet 套件

- 套件 ID：`Dctooandy.EchoCore`（`EchoCore` 這種短名稱在 nuget.org 容易撞名）。
- 內容：`lib/net8.0/EchoCore.dll`＋各平台原生庫放在 `runtimes/<RID>/native/`。.NET 執行時依平台自動挑對的檔案，使用者不用自己複製 dll。
- 支援的 RID：
  - `win-x64`（`windows-latest`）
  - `osx-arm64`、`osx-x64`（在 `macos-latest` 用 `CMAKE_OSX_ARCHITECTURES` 交叉編譯）
  - `linux-x64`（`ubuntu-latest`）
  - `linux-arm64`（`ubuntu-24.04-arm`）
- 套件附 README、LICENSE（MIT）、repo 連結、版本說明連結。
- `dotnet pack` 時版本號從標頭讀出，不手寫第二份。

### D. CI 流程（公開 repo，`.github/workflows/`）

1. **test**（push、PR、tag）：沿用三平台 `dotnet test`，另外加入：
   - `dart test`（macOS、Linux）
   - `swift test`（macOS）
   - 版本一致性檢查、ABI 匯出檢查
2. **native**（只在 tag）：每個 RID 用 CMake Release 編原生庫，上傳成 artifact。
3. **pack**：收齊所有 artifact，`dotnet pack` 出 `.nupkg`。
4. **verify**：在 Windows、macOS、Linux 各建一個**全新的** console 專案，從本機資料夾安裝剛打好的 `.nupkg`，呼叫 `EchoCore.Rms` 與 `EchoCore.Version` 並比對結果。驗的是「套件本身能用」，不只是原始碼能用。
5. **release**（tag `v*` 且前面全部通過）：
   - 確認 tag 版本＝標頭版本。
   - 建立 GitHub Release，內文取 CHANGELOG 對應的那一節，附上 `.nupkg`。
   - 推到發佈目的地。
- tag 有 `-` 後綴（例如 `v0.3.0-rc.1`）時，發成 prerelease。

### E. 文件

- `CHANGELOG.md` 改用 Keep a Changelog 格式，補上 0.2.0 這一版：C++ 核心、C# 包裝、`ec_version`。
- README 新增「版本與發佈」：相容性規則、發一版的步驟（改標頭版本 → 改 CHANGELOG → PR → 合併 → 推 tag）、怎麼安裝 NuGet 套件。
- monorepo 同步：程式碼、`abi/`、CHANGELOG、README 都同步；workflow 只放公開 repo。

**明確不做的事**：

- 發佈到 pub.dev、CocoaPods、Maven／AAR、SwiftPM 的 binary target（xcframework）。只在 README 列為「之後的方向」。
- 套件簽章、symbol package（`.snupkg`）。
- 32 位元、`win-arm64`。
- 自動產生版本號（例如依 commit 訊息自動升版）。版本號由人決定，CI 只負責檢查。

## API 異動

不是後端 API。C API 新增：

- `EC_VERSION_MAJOR`、`EC_VERSION_MINOR`、`EC_VERSION_PATCH`（巨集）
- `EC_EXPORT int32_t ec_version(void);`

依 A 的規則屬於次版本升級。四種包裝各加一個讀版本的 API（見 A）。

## 資料表異動

無。

## 權限與狀態機

發佈流程的狀態：

| 觸發 | 跑哪些 job | 結果 |
| --- | --- | --- |
| push 到任一分支、PR | test | 只測試，不打包 |
| 推 `v*` tag | test → native → pack → verify → release | 全過才發佈；任何一步失敗就不發佈，也不建 Release |

權限：release job 需要 `contents: write`（建 Release）；推 GitHub Packages 需要 `packages: write`；推 nuget.org 需要 repo secret `NUGET_API_KEY`（由使用者在 GitHub 設定，Claude 不經手金鑰）。

## UI／畫面

無。

## 邊界案例與例外處理

| 情境 | 處理 |
| --- | --- |
| tag 版本跟標頭不同（例如 tag `v0.3.0`，標頭還是 0.2.0） | release 前的檢查失敗，不發佈 |
| CHANGELOG 沒有這一版的段落 | 版本一致性檢查失敗 |
| 同一個版本重推 tag | NuGet 不允許覆蓋已發佈的版本 → 發佈失敗。README 寫明：發錯就升修訂版重發，不刪 tag 重來 |
| 某個 RID 編譯失敗 | 整個發佈停止，不會出現缺平台的套件 |
| 使用者的平台不在支援清單（例如 `win-arm64`） | 載入時 `DllNotFoundException`；README 列出支援的 RID |
| 新版 C# 搭舊版原生庫（使用者自己換了 dll） | 主版本不同 → 載入時丟例外（A 的版本檢查）；同主版本、次版本較舊 → 呼叫到不存在的函式時 `EntryPointNotFoundException`。README 註明「C# 與原生庫要用同一個套件的」 |
| 匯出符號多出一個 | ABI 檢查失敗，必須確認是刻意新增（改 `exports.txt`、升次版本）還是外洩 |
| GitHub Actions 的 runner 版本變動（例如 `macos-latest` 改指向新版） | 不釘 runner 版本；CI 失敗時再處理 |

---

## 決定紀錄

12 項待確認事項皆於 2026-10-11 採用建議：

| # | 項目 | 決定 |
| --- | --- | --- |
| 1 | 第一個正式版本 | `0.2.0` |
| 2 | 讀版本的 API | 四種包裝都加 |
| 3 | C# 載入時檢查主版本 | 做 |
| 4 | ABI 匯出檢查 | 做 |
| 5 | NuGet 套件 ID | `Dctooandy.EchoCore` |
| 6 | RID | `win-x64`、`osx-arm64`、`osx-x64`、`linux-x64`、`linux-arm64`；`win-arm64` 之後 |
| 7 | 發佈目的地 | GitHub Release（附 `.nupkg`）＋GitHub Packages；nuget.org 之後再加 |
| 8 | prerelease tag | 支援（tag 含 `-` 發成 prerelease） |
| 9 | 第一次發版 | 先推 `v0.2.0-rc.1` 試跑整條流程，綠燈後推 `v0.2.0` |
| 10 | `osx-x64` 驗證 | 只檢查架構（`lipo -info`），不執行 |
| 11 | `pubspec.yaml` 版本 | 一起升到 0.2.0 |
| 12 | workflow | `dotnet.yml` 拆成 `ci.yml`（每次 push／PR）與 `release.yml`（tag），badge 改指 `ci.yml` |

## 待確認事項

目前無。
