# echo_core 第 1 週：跨平台 C 音訊核心骨架 規格

分支：`feature/echo-core`
狀態：已確認（2026-10-08，12 項待確認事項皆採用建議，見「決定紀錄」）

建立 echonote 自己的 C 音訊核心 `echo_core`，自己設計 C 介面、自己寫 `dart:ffi` 綁定、自己管理 Dart 與 C 之間的記憶體。這是四週計畫的第 1 週（計畫頁：<https://claude.ai/artifact/9j2LTabW7yRuLDZ1YU12KR>）：先把骨架、第一批 C 函式、測試與效能比較做出來，第 2 週再用它改寫 whisper 串流的餵資料介面，第 3 週搬到 Android。

目的有兩個：(1) 補上目前缺的 FFI 第一手經驗（綁定、記憶體所有權、原生建置）；(2) 為第 2 週的效能改寫準備好工具與基準。

## 目標與範圍

- 新增套件 `echonote/packages/echo_core`，用 `flutter create --template=package_ffi` 建立（`plugin_ffi` 已被 Flutter 標為 deprecated）。C 原始碼由套件的 build hook（`hook/build.dart`＋`native_toolchain_c`）在建置時編譯，iOS 實機／模擬器與 macOS（`flutter test` 用）都由同一份 C 產生。編譯參數：C11、`-O3`、`-Wall -Wextra -Werror`（決定 #12）；原生產物最低 iOS 版本沿用 Flutter 傳入的預設值（決定 #10）。
- **第一個任務先驗證**：`package_ffi` 的 build hooks 在 iOS 實機、iOS 模擬器、macOS（`flutter test`）都編得過，且能跟用 podspec 的 `whisper_ggml` 並存。不行就退回 podspec，並另外為測試編 macOS dylib（決定 #3）。
- 用 `ffigen` 從 `src/echo_core.h` 產生 Dart 綁定（`@Native` 外部函式），不手寫 `lookupFunction`。
- 第一批 C 函式（見「API 異動」）：
  - `ec_pcm16_to_float`：PCM16 轉 float（第 2 週會用來取代 whisper worker 裡的 Dart 迴圈）。
  - `ec_rms_pcm16`：一段 PCM16 的 RMS 音量。
  - VAD 能量門檻（有狀態，opaque pointer）：判斷一段音訊是否有人聲，演算法與 whisper 串流內建的門檻一致。
  - `ec_waveform_downsample`：把一段 PCM16 壓成固定數量的峰值，給畫面畫波形。
- Dart 包裝層：對外只露出 Dart 型別（`Int16List`、`Float32List`、`double`），內部負責 native 記憶體。資料交給 C 有兩條路徑都要做（決定 #2）：**零複製**（直接傳 Dart 陣列的 `.address` 給 `isLeaf: true` 的 `@Native` 函式）與**重複使用的 native buffer**（預先 `malloc`、`asTypedList` 複製後呼叫，`NativeFinalizer` 釋放）。有狀態的 VAD 用 `NativeFinalizer` 確保釋放，也提供明確的 `dispose()`。
- 正確性：每個 C 函式都有一個純 Dart 的參考實作，測試比對兩者結果。容許誤差：`pcm16ToFloat` 必須完全相同；RMS 與峰值容許 1e-6 相對誤差（決定 #9）。
- 效能比較：用**合成訊號**（正弦波加雜訊，2 小時、16 kHz mono PCM16，由程式產生，可放進 repo、別人可重現）分三種方式處理：純 Dart、C 零複製、C 加 native buffer；記錄耗時與配置次數。**Mac 與 iPhone 12 Pro Max 都要量**，結果寫在 `packages/echo_core/README.md`（決定 #6、#7、#8）。
- 錄音畫面加上**即時音量條**，用 `rms` 計算，證明 `echo_core` 真的在 iOS 上執行（決定 #4）。
- 記錄加入 `echo_core` 前後的 App 大小（決定 #11）。
- 測試在 macOS 上用 `flutter test` 執行，真的呼叫 C（透過 build hook 編出的 macOS 動態函式庫），不 mock。

**明確不做的事**：

- 不改 whisper 串流的餵資料介面、不碰 `audio_ctx`（第 2 週）。
- 不做 Android 的建置驗證與收音（第 3 週）。`package_ffi` 會順便產生 Android 的建置設定，但這週不驗證。
- 不寫 C 端獨立的單元測試框架、不跑 sanitizer、不設 CI（第 4 週）。
- 不取代 whisper 串流 C++ 內建的 VAD 門檻；`echo_core` 的 VAD 這週只做函式與測試，不接進 App。第 2 週改寫 whisper 介面時再決定要不要讓 whisper 改用它（決定 #5）。
- 不在 GitHub 公開前處理 Firebase 設定檔（使用者決定之後再做）。

## API 異動

### 後端 API

無。

### C 介面（`packages/echo_core/src/echo_core.h`）

共同約定：

- 樣本格式為 mono、PCM16（`int16_t`）。函式不依賴取樣率，echonote 實際使用 16 kHz。
- 函式不配置記憶體、不保留傳入的指標；呼叫端負責所有 buffer 的配置與釋放。
- `n`（樣本數）≤ 0 時不讀寫任何記憶體，回傳值見各函式。
- 無狀態函式可在任何 thread 呼叫；有狀態的 VAD 物件不是 thread-safe，同一個物件只能由一個 isolate 使用。

| 函式 | 簽名 | 行為 |
| --- | --- | --- |
| `ec_pcm16_to_float` | `void ec_pcm16_to_float(const int16_t* in, float* out, int32_t n)` | `out[i] = in[i] / 32768.0f`，範圍 [-1, 1)；與 whisper 套件現有的轉換公式一致 |
| `ec_rms_pcm16` | `float ec_rms_pcm16(const int16_t* in, int32_t n)` | 回傳正規化 RMS（0～1，以 32768 為滿刻度）；`n ≤ 0` 回傳 0 |
| `ec_vad_create` | `ec_vad* ec_vad_create(ec_vad_config config)` | 建立 VAD 狀態；配置失敗回傳 `NULL` |
| `ec_vad_process` | `int32_t ec_vad_process(ec_vad* vad, const int16_t* in, int32_t n)` | 以整段為一個單位更新雜訊底並判斷：有人聲回 1、沒有回 0；`n ≤ 0` 回 0 且不更新狀態 |
| `ec_vad_reset` | `void ec_vad_reset(ec_vad* vad)` | 雜訊底回到初始值 |
| `ec_vad_destroy` | `void ec_vad_destroy(ec_vad* vad)` | 釋放；傳入 `NULL` 不做事 |
| `ec_waveform_downsample` | `int32_t ec_waveform_downsample(const int16_t* in, int32_t n, float* out, int32_t buckets)` | 把 `n` 個樣本平均分成 `buckets` 段，每段輸出絕對值峰值（0～1）；回傳實際寫入的段數；`buckets > n` 時只寫 `n` 段 |

`ec_vad_config`（數值與 whisper 串流內建門檻相同，見 `whisper_flutter_plus.cpp` 的 `whisper_stream_state`）：

| 欄位 | 預設 | 說明 |
| --- | --- | --- |
| `initial_noise_floor` | 0.005 | 初始雜訊底（RMS） |
| `rms_min` | 0.0015 | 有人聲的絕對下限 |
| `voice_ratio` | 2.5 | 門檻 = max(`voice_ratio` × 雜訊底, `rms_min`) |
| `noise_floor_cap` | 0.01 | 雜訊底上限（吵雜環境） |
| `fall_rate` / `rise_rate` | 0.5 / 0.0005 | 雜訊底快降慢升 |

### Dart 包裝（`packages/echo_core/lib/echo_core.dart`）

- `Float32List pcm16ToFloat(Int16List samples)`
- `double rms(Int16List samples)`
- `List<double> waveform(Int16List samples, int buckets)`
- `class EchoVad`：`EchoVad({EchoVadConfig config})`、`bool process(Int16List samples)`、`void reset()`、`void dispose()`。用 `NativeFinalizer` 綁定 `ec_vad_destroy`；`dispose()` 會先解除 finalizer 再釋放，避免重複釋放；`dispose()` 之後再呼叫其他方法丟 `StateError`。
- 每個無狀態函式在 Dart 端有兩種實作路徑（零複製／native buffer），效能比較用；App 使用零複製路徑。native buffer 路徑由一個持有 buffer 的物件管理，`NativeFinalizer` 負責釋放，buffer 不夠大時重新配置。

### App 端

- `pubspec.yaml` 新增 `echo_core: path: packages/echo_core`。
- `LiveRecordScreen` 錄音中依每個 chunk 的 `rms` 顯示音量條（見 UI）。

## 資料表異動

無。

## 權限與狀態機

無角色差異。唯一的狀態是 `EchoVad` 的生命週期：

```text
建立（ec_vad_create，綁定 NativeFinalizer）
 ├─ process／reset（可重複）
 ├─ dispose() → 解除 finalizer → ec_vad_destroy → 已釋放（之後呼叫丟 StateError）
 └─ 沒有呼叫 dispose 就被 GC → NativeFinalizer 呼叫 ec_vad_destroy
```

## UI／畫面

- **`LiveRecordScreen` 錄音中加上即時音量條**（決定 #4）：每收到一個 100 ms 的 chunk，用 `echo_core` 的 `rms` 算音量並更新。
- 視覺**暫定，待正式設計**：先用 Material 預設的 `LinearProgressIndicator`，放在已錄時間下方；音量對應到進度條的刻度（線性或 dB）在實作時依實機觀感調整，不視為定案。
- 不顯示波形、不顯示 VAD 結果。

## 邊界案例與例外處理

| 情境 | 處理方式 |
| --- | --- |
| 空輸入（0 個樣本） | 各函式依上表回傳 0 或不寫入，不讀寫記憶體；Dart 包裝直接回傳空結果，不呼叫 C |
| 樣本值為 -32768 | 轉換結果為 -1.0；RMS、峰值不超過 1 |
| `buckets` ≤ 0 | 回傳 0，不寫入 |
| `buckets` 大於樣本數 | 每段一個樣本，回傳實際段數 |
| `EchoVad` 已 `dispose` 又呼叫 | Dart 丟 `StateError`，不呼叫 C |
| `dispose()` 呼叫兩次 | 第二次不做事 |
| `ec_vad_create` 回傳 `NULL` | Dart 建構子丟例外，不建立物件 |
| 奇數 bytes 的 PCM | 不在 `echo_core` 處理：API 只收 `Int16List`。上游（`MicStreamChannel` 保證偶數、`WavWriter` 自行處理）負責 |
| build hook 在某平台編譯失敗 | App 建置失敗（不是執行時才發現）；第 1 週只保證 iOS 與 macOS |

---

## 決定紀錄

12 項待確認事項皆於 2026-10-08 採用建議，內容已寫回上方各章節：

| # | 項目 | 決定 |
| --- | --- | --- |
| 1 | 分支名稱 | `feature/echo-core`，從 `master` 開 |
| 2 | Dart 資料交給 C 的方式 | 零複製與 native buffer 兩種都做，效能表三方對照；App 用零複製 |
| 3 | `package_ffi` 可行性 | 排成第一個任務驗證；不行就退回 podspec |
| 4 | 接進 App | 錄音畫面加即時音量條（`rms`） |
| 5 | VAD 用途 | 這週只做函式與測試 |
| 6 | 效能量測地點 | Mac 與 iPhone 12 Pro Max 都量 |
| 7 | 效能測試資料 | 合成訊號（正弦波加雜訊） |
| 8 | 效能表位置 | `packages/echo_core/README.md` |
| 9 | 比對容許誤差 | 轉 float 完全相同；RMS、峰值 1e-6 相對誤差 |
| 10 | iOS 最低版本 | 原定對齊 15.6；2026-10-08 修訂：沿用 Flutter 傳給 build hook 的預設值（13.0）。App 本身要求 15.6，執行上沒有影響，強行覆寫等於跟工具鏈打架 |
| 11 | App 大小 | 記錄加入前後的大小 |
| 12 | C 編譯參數 | C11、`-O3`、`-Wall -Wextra -Werror` |

## 任務拆解

> 2026-10-08 初版。依據本規格與目前程式碼現況拆解（`live_transcription_service.dart` 的 `_onChunk` 是每個 100 ms chunk 進來的位置；專案目前沒有 `integration_test`、沒有 `CLAUDE.md`）。所有任務都屬於「可獨立進行」，沒有需要外部團隊配合的項目。

### 階段 0：可行性驗證（必須最先完成）

- [x] **T0.1** 記錄基準 App 大小：在加入 `echo_core` 之前，`flutter build ios --release --no-codesign`，記下 `Runner.app` 大小（決定 #11）。
  - 2026-10-08：`Runner.app` 41.0 MB（Flutter 回報；`du` 39.5 MB）。
- [x] **T0.2** 用 `flutter create --template=package_ffi echo_core` 在 `packages/` 建立套件；讀懂產生的 `hook/build.dart`、`ffigen.yaml`、`src/` 結構。設定 C11、`-O3`、`-Wall -Wextra -Werror`。依賴：無。
  - 2026-10-08：已建立；刪除範本附帶的 `example/` App（以 echonote 本身當範例）。hook 設定 `std: 'c11'`、`-Wall -Wextra -Werror`、`.o3`。
- [x] **T0.3** App 加上 `echo_core: path: packages/echo_core`，用範本自帶的範例函式驗證三處：`flutter test`（macOS 上真的呼叫 C）、`flutter build ios --simulator`、iOS 實機 debug 執行；確認原生產物最低版本為 15.6，且 `whisper_ggml`（podspec）照常運作。依賴：T0.2。
  - 2026-10-08 進度：macOS `dart test` 通過（hook 編出 `libecho_core.dylib`）；iOS 模擬器用 `integration_test/echo_core_smoke_test.dart` 執行通過，與 `whisper_ggml` 並存正常；實機 release 建置通過（arm64），App 41.0 → 41.2 MB。`echo_core.framework` 最低版本為 13.0，依修訂後的決定 #10 接受。實機執行併入 T4.3 驗證。
- [x] **T0.4**（條件式，不需要：T0.3 通過）T0.3 任一處失敗時：改用 podspec 編譯 `echo_core`，並另外為 `flutter test` 編 macOS dylib；回頭修改規格。依賴：T0.3。

### 階段 1：C 實作

依賴：T0.3 通過（或 T0.4 完成）。

- [x] **T1.1** `src/echo_core.h`：依規格定義 4 類函式與 `ec_vad_config`，寫清楚「不配置記憶體、不保留指標、`n ≤ 0` 的行為、VAD 非 thread-safe」等約定的註解。
- [x] **T1.2** 實作 `ec_pcm16_to_float`、`ec_rms_pcm16`、`ec_waveform_downsample`，含 `n ≤ 0`、`buckets ≤ 0`、`buckets > n`、-32768 等邊界。依賴：T1.1。
- [x] **T1.3** 實作 `ec_vad_create`／`process`／`reset`／`destroy`，演算法與 `whisper_flutter_plus.cpp` 的 `stream_feed` 門檻一致（快降慢升的雜訊底、上限、門檻 = max(ratio × 雜訊底, 下限)）。依賴：T1.1。
- [x] **T1.4** 用 `ffigen` 產生綁定：無狀態函式與 `ec_vad_process` 標 `isLeaf: true`；`ec_vad_destroy` 要能取得函式指標給 `NativeFinalizer` 用。依賴：T1.2、T1.3。

### 階段 2：Dart 包裝與測試

- [x] **T2.1** 純 Dart 參考實作（`pcm16ToFloat`、`rms`、`waveform`、VAD），跟 C 版本的公式逐行對應。依賴：無（可與階段 1 同時做）。
- [x] **T2.2** 零複製路徑：直接把 `Int16List`／`Float32List` 的 `.address` 交給 leaf 函式；空輸入直接回傳、不呼叫 C。依賴：T1.4。
- [x] **T2.3** native buffer 路徑：持有 buffer 的物件，預先 `malloc`、`asTypedList` 複製後呼叫；不夠大時重新配置；`NativeFinalizer` 釋放。依賴：T1.4。
- [x] **T2.4** `EchoVad`：建構時 `ec_vad_create`（`NULL` 時丟例外）並綁 `NativeFinalizer`；`dispose()` 先解除 finalizer 再釋放、第二次呼叫不做事；釋放後呼叫其他方法丟 `StateError`。依賴：T1.4。
- [x] **T2.5** 測試（macOS 上 `flutter test`，真的呼叫 C）：C 與參考實作比對（轉 float 完全相同，RMS／峰值 1e-6 相對誤差）、兩條路徑結果一致、邊界案例表逐項、VAD 生命週期、buffer 重新配置。依賴：T2.1–T2.4。
  - 2026-10-08：`packages/echo_core/test/echo_core_test.dart` 16 項全部通過（macOS，真的呼叫 C）；iOS 模擬器的 `integration_test` 也改成呼叫真正的函式並通過。
  - 規格未寫到、實作時新增：`ec_vad_default_config()`（Dart 預設值與 C 預設值有測試確保一致）；編譯參數加 `-ffp-contract=off`（關閉乘加合併，讓 C 與純 Dart、各平台結果逐位元相同，VAD 判斷因此能完全比對）；`EchoBufferedCore.allocations`（效能表要用的配置次數）；`waveform` 回傳 `Float32List`。

### 階段 3：效能比較

- [x] **T3.1** 合成訊號產生器：固定亂數種子的正弦波加雜訊，2 小時、16 kHz mono PCM16，分成 100 ms chunk 餵入（跟實際錄音的呼叫粒度一致）。依賴：無。
- [x] **T3.2** Mac 上的效能比較：純 Dart／C 零複製／C 加 native buffer 三方，量各函式的總耗時；記憶體配置次數依設計列出（不量測）。依賴：T2.5、T3.1。
  - 2026-10-08：`lib/benchmark.dart`（Mac CLI 與 iPhone `integration_test` 共用）＋`bin/benchmark.dart`（`dart build cli` 以 AOT 編譯，跟 App 的 profile／release 可比）。
  - **公平性修正**：純 Dart 的 `rms`／VAD 原本用 `for-in`，AOT 下慢約 4 倍，改成索引迴圈；兩邊再一起改成**整數累加平方和**（結果精確、逐位元相同，且讓 C 可以向量化）。最終 Mac（M2 Pro）：`rms` 8.4×、`vad` 8.3×、`pcm16ToFloat` 4.3×、`waveform` 23.5×（C 零複製相對純 Dart）。
  - debug 模式（JIT）的 Dart 數值迴圈快很多，數字不可用；iPhone 量測必須用 profile（Xcode：Edit Scheme → Run → Build Configuration = Profile）。
  - 觀察待確認：舊版 iPhone profile 數據中，`pcm16ToFloat` 的零複製（0.87 µs）慢於 native buffer（0.60 µs），與 Mac 相反，等新一輪 iPhone 數據再看是否重現。
- [x] **T3.3** iPhone 12 Pro Max 上跑同一組比較：新增 `integration_test`，用 `flutter drive --profile` 執行（debug 模式的 Dart 是 JIT，數字不可用），結果印到 console。依賴：T3.2。
- [x] **T3.4** 把兩台裝置的結果、量測方法、App 大小前後差異寫進 `packages/echo_core/README.md`。依賴：T0.1、T3.3、T4.1。
  - 2026-10-08：iPhone 12 Pro Max profile 模式量測完成（使用者用 Xcode Profile 設定執行；無線 `flutter drive` 找不到 VM Service 而失敗）。結果、方法、記憶體配置表、App 大小（41.0 → 41.2 MB，framework 108 KB）寫入 `packages/echo_core/README.md`。iPhone 上 `pcm16ToFloat` 零複製慢於 native buffer 的現象兩次重現，原因未查明，記於 README。App 大小在 T4 完成後若有變化再更新。

### 階段 4：接進 App

- [x] **T4.1** `LiveRecording` 新增 `Stream<double> level`：在 `_onChunk` 用 `echo_core` 的零複製 `rms` 算每個 chunk 的音量。chunk 的 `Uint8List` 若 `offsetInBytes` 是奇數，無法直接當成 `Int16List`，要先複製一份。依賴：T2.2。
- [x] **T4.2** `LiveRecordScreen` 錄音中在已錄時間下方顯示 `LinearProgressIndicator` 音量條（暫定視覺）；音量到進度條的對應方式在實機上調整。依賴：T4.1。
  - 2026-10-08：`LiveRecording.level`（零複製 `rms`，chunk 未對齊 2 bytes 時才複製）；錄音畫面在已錄時間下方用 `StreamBuilder` 只重繪音量條。對應方式先用 dB：-60 dBFS → 0、0 dBFS → 滿（說話約 -35～-15 dBFS，線性對應幾乎不會動），實機上再調。
- [x] **T4.3** 實機驗證：錄音時說話音量條會動、安靜時接近 0；即時預覽與 WAV 寫入不受影響。依賴：T4.2。
  - 2026-10-08：使用者實機確認音量條反應合理，說話時約到一半（dB 範圍維持 -60～0 dBFS）；這同時補上 T0.3 延後的「`echo_core` 在 iPhone 實機執行」驗證。音量條也會反映電視等背景聲音，這是 RMS 的本質（量的是所有聲音的能量，不分人聲），不是錯誤。

### 階段 5：收尾

- [ ] **T5.1** 用 `/spec-check` 核對規格與實作，用 `/devlog` 整理開發紀錄。依賴：階段 0–4 全部完成。

### 任務摘要

- 共 21 項，全部「可獨立進行」；其中 T0.4 是條件式任務，只在 T0.3 失敗時才做。
- 關鍵路徑：T0.2 → T0.3 → 階段 1 → T2.2 → T4.1 → T4.2 → T4.3。T2.1、T3.1 可以提前同時做。

## 待確認事項

目前無。拆解任務時的 2 項已於 2026-10-08 採用建議：(1) iPhone 效能比較用 `integration_test`＋`flutter drive --profile`；(2) 記憶體配置次數依設計列出，實際只量耗時。
