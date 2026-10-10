# echo_core 第 2 週：whisper 餵資料改寫、audio_ctx、零複製調查、VAD 評估、Swift 包裝 規格

分支：`feature/echo-core-w2`（從 `master` f851e44 開）
狀態：已確認（2026-10-10；20 項待確認事項皆採用建議，見「決定紀錄」）

四週 FFI 計畫的第 2 週（計畫頁：<https://claude.ai/artifact/9j2LTabW7yRuLDZ1YU12KR>；第 1 週規格：[`../feature-echo-core/feature-echo-core.md`](../feature-echo-core/feature-echo-core.md)）。第 1 週做出了 `echo_core` 和它的量測工具，這週把它用到真正的資料路徑上，並補上兩個缺口：(1) 第 1 週留下的「iPhone 上零複製反而比較慢」；(2) 同一份 C library 只有 dart:ffi 一種包裝，缺少 iOS 原生（Swift）直接呼叫 C 的版本（2026-10-10 使用者決定排進本週）。

五個子項彼此獨立，可以分開驗收：

| # | 子項 | 性質 | 需要實機 |
| --- | --- | --- | --- |
| A | whisper 即時串流的 PCM 轉換改用 `ec_pcm16_to_float` | 改寫 | 回歸測試要 |
| B | 即時預覽加入 `audio_ctx` 調校 | 調校＋量測 | 要 |
| C | 查 iPhone 上 `pcm16ToFloat` 零複製比 native buffer 慢的原因 | 調查 | 要 |
| D | 評估「只在有人聲時才送辨識」的 VAD | 評估（不接進 App） | 錄音素材要 |
| E | Swift 直接呼叫 `echo_core` C 的包裝 | 新增 | 不需要（決定 #E2） |

## 目標與範圍

### A. whisper 餵資料改用 `echo_core`

現況（`packages/whisper_ggml/lib/src/whisper_live.dart` 的 `_liveWorker`）：每個 100 ms chunk（1,600 個樣本）在 worker isolate 裡 `malloc` 一塊 float buffer、用 Dart 迴圈 `samples[i] / 32768.0` 轉換、呼叫 `stream_feed`、再 `free`。

改成：

- 轉換改由 `ec_pcm16_to_float` 執行：輸入走零複製（`Int16List.address`，leaf call），輸出寫進一塊**重複使用的 native buffer**。輸出不能是 Dart 陣列，因為 `stream_feed` 會跑推論（耗時數百 ms、不是 leaf call），Dart 不允許把 Dart heap 的位址傳給非 leaf 的呼叫。
- buffer 在 session 開始時配置、不夠大才重新配置、session 結束時釋放（加 `NativeFinalizer` 保底），取代每個 chunk 一次的 `malloc`／`free`。
- `echo_core` 新增對應的 Dart API（見「API 異動」），`whisper_ggml` 的 `pubspec.yaml` 加上 `echo_core` 的 path 依賴（決定 #A1，`ECHONOTE.md` 記一筆）。
- 轉換公式與現在相同（`/ 32768`，`echo_core` 第 1 週已驗證與 Dart 逐位元相同），**辨識結果不應有任何改變**。
- 預期效益要誠實寫：轉換一個 chunk 在 iPhone 上約 1.5 µs（Dart）→ 0.6～0.9 µs（C），相對於一次推論約 900 ms 可以忽略。這個子項的價值在**架構**（同一份 C 核心進入真正的資料路徑、去掉每個 chunk 的配置），不是速度；履歷與 README 不寫成效能優化。

### B. `audio_ctx` 調校

whisper 的 encoder 預設一律處理 30 秒（`audio_ctx` = 1500 個 frame，每秒 50 個），即時預覽的視窗卻常常只有幾秒。把 `audio_ctx` 調小可以減少 encoder 的計算量，代價是可能降低辨識品質或產生幻覺。

- `stream_start` 的 JSON 新增 `audio_ctx`，`stream_run_inference` 設定 `wparams.audio_ctx`；`transcribeLive` 與 `LivePreviewConfig` 新增對應參數，**預設維持原行為**（0 = 1500）。
- 調整方式：固定值與動態（每次推論依視窗長度算 `ceil(秒數 × 50) + 餘量`，上限 1500）兩種都做成參數，實機各量一次再決定預設值（決定 #B1）。固定值模式需要搭配可調的 commit 門檻（固定值涵蓋不到 25 秒），所以 commit 秒數也做成參數，預設維持 25 秒。
- metrics 新增 `audio_ctx`（這次實際用的值），方便比對。
- 實機量測：同一段朗讀內容，比較 encode_ms、total_ms、落後秒數、文字品質，依結果決定 `kLivePreviewConfig` 的預設值：中位數 total_ms 降低 20% 以上、且同一份約 2 分鐘朗讀稿的文字沒有明顯變差（使用者目視）才改，否則維持 0 並記錄結果（決定 #B2、#R2）。stop 時的最後一次推論套用同一個設定（決定 #R4）。
- 只影響即時預覽（tiny）；錄完後的離線轉錄（base）不動。

### C. 零複製比較慢的調查

第 1 週兩次量測都重現：iPhone 12 Pro Max 上 `pcm16ToFloat` 零複製 0.87 µs、native buffer 0.59 µs；Mac 上相反。兩條路徑都會在 Dart heap 配置一個輸出陣列，差別在：

- 零複製：`Float32List(n)`（配置＋清零）→ C 直接寫進這塊 Dart 記憶體。
- native buffer：C 寫進 malloc 的 buffer → `Float32List.fromList` 複製出來。

要驗證的假設（每個做一個 benchmark 變體，在 iPhone profile 模式量）：

| 假設 | 變體 |
| --- | --- |
| H1：`Float32List(n)` 的清零加上 C 再寫一次，比 `fromList` 的一次複製貴 | 零複製寫進**預先配置、重複使用**的 `Float32List`（不配置、不清零） |
| H2：Dart heap 的 typed data 對齊方式讓 NEON 寫入變慢 | 印出兩種輸出位址的對齊（`address % 16`）；C 端用對齊與非對齊 buffer 各量一次 |
| H3：剛配置的 Dart 記憶體第一次寫入的成本（cache／TLB），malloc 的 buffer 已經熱了 | 零複製輸入、native buffer 輸出（就是 A 的組合），再 `fromList` 複製出來 |

- 交付物：README「從數據學到的」第 4 點改寫成結論（或「已排除哪些假設、仍未查明」），benchmark 變體留在 `lib/benchmark.dart`。
- 時間上限：實機 1 輪（約 30 分鐘）（決定 #C1）；變體在 Mac 上也跑一次對照（決定 #R3）。查不出原因也算完成，只要記錄排除了什麼。
- 結果也回答 A 的設計問題：A 的輸入走零複製是否合理。

### D. 「只在有人聲時才送辨識」的 VAD 評估

現況：whisper 串流用 RMS 能量門檻決定要不要跑推論（`stream_feed`），`echo_core` 的 `EchoVad` 是同一個演算法。第 1 週驗收時觀察到：電視等背景聲音也會被判斷成有聲音，觸發不必要的推論（也可能產生幻覺文字）。

本週只做**評估**，產出比較結果與建議，不接進 App（決定 #D1；接不接、接在哪留到第 3／4 週）。實作評估的只有 D-a 與對照組，D-b／D-c 只寫成本分析（決定 #D6）。候選：

| 候選 | 說明 | 成本 |
| --- | --- | --- |
| D-a：whisper.cpp 內建 Silero VAD | 內建版本的 whisper.cpp 已經有 `whisper_vad_*` API，包含串流用的 `whisper_vad_detect_speech_no_reset`；需要另外下載 ggml 格式的 Silero 模型（約 1 MB） | 低：程式已在，只要接上與下載模型 |
| D-b：`echo_core` 加頻譜特徵 | 在現有能量門檻上加過零率、語音頻段能量比等特徵，純 C、不需要模型 | 中：要自己調參 |
| D-c：移植 WebRTC VAD 到 `echo_core` | BSD 授權、純 C、業界常用 | 中：移植與授權標示 |
| 對照組 | 現有能量門檻 | — |

- 評估在 Mac 上進行（沿用「在 Mac 編內建 whisper 原始碼」的做法），評估程式放進 repo 的 `tool/vad_eval/` 讓結果可重現（決定 #D3），輸入是實機錄的 WAV。
- 素材由使用者用現有錄音功能錄 3 段、每段 30～60 秒：(1) 安靜環境說話、(2) 只有電視或音樂、(3) 說話加上電視背景（決定 #D5）。
- 評估指標：每 100 ms 的判斷結果，與人工標記（粒度 0.5 秒）比對（決定 #D2）；另外記錄每 100 ms 的處理時間。
- **限制要先講清楚**：語音型 VAD（D-a、D-c）偵測的是「人聲」，電視裡的對白也是人聲，**無法分辨現場的人和電視裡的人**。目標設定為「濾掉非語音的聲音（音樂、雜訊、敲擊聲）」，電視對白列為已知限制（決定 #D4）。

### E. Swift 包裝

讓同一份 `echo_core` C 原始碼有第二種包裝：Swift 直接呼叫 C，不經過 Flutter。對照 dart:ffi 的做法，展示兩種語言各自怎麼處理指標與資源釋放。

- 形式：以 Swift Package（SwiftPM）放在 `packages/echo_core/` 底下（決定 #E1）：
  - C target：直接使用 `src/` 的同一份 `echo_core.c`／`echo_core.h`，不複製。
  - Swift target `EchoCore`：Swift API（見「API 異動」）。
  - 測試 target：XCTest，`swift test` 在 macOS 執行。
- 指標：用 `withUnsafeBufferPointer`／`withUnsafeMutableBufferPointer` 傳給 C，指標只在 closure 內有效（對應 Dart 的 leaf call 限制）。
- 資源：`EchoVAD` 是 `final class`，`init` 呼叫 `ec_vad_create`（`NULL` 時 init 失敗），`deinit` 呼叫 `ec_vad_destroy`。對應 Dart 的 `NativeFinalizer`，但 Swift 的 ARC 是確定性釋放，不需要另外的 `dispose()`。
- 編譯參數與 build hook 一致（C11、`-O3`、`-ffp-contract=off`、`-Werror`；因為用了 `unsafeFlags`，這個套件只能以本地 path 依賴，本來就不發佈，決定 #E3），讓 Swift 版與 Dart 版的結果逐位元相同。
- iOS 上的驗證：`swift test`（macOS 真的呼叫 C）＋ `xcodebuild` 編譯 iOS 模擬器版本確認編得過；不接進 Runner（決定 #E2）。

**明確不做的事**：

- 不改 whisper 串流 C++ 內建的能量門檻，也不把門檻搬到 Dart／`echo_core`（第 1 週決定 #5 的延續：`EchoVad` 仍不接進 App）。
- 不讓 whisper_ggml 的 C++（podspec）直接連結 `echo_core` 的 C：兩者由不同的建置系統產生，跨 framework 連結的成本不值得。
- 不做 Android（第 3 週）、不設 CI、不跑 sanitizer（第 4 週）。
- 不改離線轉錄（base）的參數。
- 不發佈 Swift Package（不上 GitHub release、不做 XCFramework）。
- 不在 GitHub 公開前處理 Firebase 設定檔（使用者決定之後再做）。

## API 異動

### 後端 API

無。

### `echo_core` Dart（`packages/echo_core/lib/`）

新增可重複使用的轉換 buffer（名稱暫定 `PcmFloatBuffer`）：

- `PcmFloatBuffer()`：不先配置。
- `Pointer<Float> convert(Int16List samples)`：輸入零複製交給 `ec_pcm16_to_float`，輸出寫進內部 buffer，回傳 buffer 的指標。**指標只在下一次 `convert` 或 `dispose` 之前有效**；呼叫端（whisper worker）會在同一個 isolate、下一次 `convert` 之前用完。
- `void dispose()`：釋放；第二次呼叫不做事；之後呼叫 `convert` 丟 `StateError`。`NativeFinalizer` 保底。
- `int get allocations`：重新配置次數（測試用）。
- 空輸入：回傳 `nullptr`、不呼叫 C（呼叫端遇到 0 個樣本本來就不呼叫 `stream_feed`）。

### `echo_core` C

無異動。

### `whisper_ggml`（內建版本）

- `pubspec.yaml`：新增 `echo_core: path: ../echo_core`（決定 #A1）。
- `stream_start` JSON：新增 `audio_ctx`（整數，0 = 預設 1500，-1 = 動態）與 `commit_sec`（預設 25）。
- `stream_run_inference`：依設定填 `wparams.audio_ctx`；metrics 新增 `audio_ctx`。
- `WhisperController.transcribeLive`／`startWhisperLiveSession`：新增 `audioCtx`（預設 0）、`commitSec`（預設 25）參數。
- 修改處照慣例在註解標 `[echonote]`，`ECHONOTE.md` 補一行說明。

### App 端

- `LivePreviewConfig` 新增 `audioCtx`（預設 0）、`commitSec`（預設 25）；`kLivePreviewConfig` 的值依 B 的量測結果決定。

### Swift（`packages/echo_core/`，新增）

- `Package.swift`：C target（`src/`）、Swift target `EchoCore`、測試 target。
- `enum EchoCore`（命名空間）：
  - `static func pcm16ToFloat(_ samples: [Int16]) -> [Float]`
  - `static func rms(_ samples: [Int16]) -> Float`
  - `static func waveform(_ samples: [Int16], buckets: Int) -> [Float]`
- `final class EchoVAD`：`init?(config: ec_vad_config = ec_vad_default_config())`、`func process(_ samples: [Int16]) -> Bool`、`func reset()`；`deinit` 釋放。不標 `Sendable`（C 端不是 thread-safe）。
- 參數型別用 `[Int16]` 還是泛型 `some Collection`／`UnsafeBufferPointer` 多載，實作時決定，以呼叫端好用為主。

## 資料表異動

無。

## 權限與狀態機

無角色差異。新增兩個生命週期：

```text
PcmFloatBuffer（whisper worker 擁有，一個 session 一個）
 建立（不配置）→ convert（第一次配置；不夠大時重新配置）→ … → dispose（session stop 時）
 沒有 dispose 就被 GC → NativeFinalizer 釋放

EchoVAD（Swift）
 init（ec_vad_create；NULL → init 回傳 nil）→ process／reset → 最後一個參照消失 → deinit → ec_vad_destroy
```

## UI／畫面

無新畫面。B 的量測沿用現有錄音畫面與 debug log（metrics）；不新增調校開關畫面，改 `kLivePreviewConfig` 重新建置來切換，量 2～3 種設定（決定 #B3）。

## 邊界案例與例外處理

| 情境 | 處理方式 |
| --- | --- |
| chunk 位元組數為奇數、或 `offsetInBytes` 為奇數 | 沿用 worker 現有的補位邏輯（`pendingByte`），補完才轉成 `Int16List` 交給 `convert` |
| 補位後 0 個樣本 | 不呼叫 `convert`、不呼叫 `stream_feed`（現有行為） |
| chunk 比目前 buffer 大 | 重新配置（先解除舊 buffer 的 finalizer 再掛新的，沿用 `EchoBufferedCore` 做法） |
| `stream_feed` 回傳錯誤 | 現有錯誤處理不變；buffer 留到 stop 時釋放 |
| session 中途出錯、worker 被 kill | isolate 被 kill 時 `NativeFinalizer` 不保證執行；接受約 6 KB 的洩漏，寫進註解（決定 #A2） |
| `audio_ctx` 大於 1500 或為負數 | C++ 端夾到合法範圍；Dart 端不另外檢查 |
| `audio_ctx` 小於視窗長度需要的 frame 數 | 固定值模式由使用者把 `commitSec` 設在涵蓋範圍內（量測設定會成對調整）；C++ 不另外截斷或報錯 |
| Swift `ec_vad_create` 回傳 `NULL` | `init?` 回傳 `nil` |
| Swift 空陣列 | 不呼叫 C，直接回傳 0／空陣列（與 Dart 一致） |

---

## 決定紀錄

20 項待確認事項皆於 2026-10-10 採用建議，內容已寫回上方各章節：

| # | 項目 | 決定 |
| --- | --- | --- |
| A1 | `whisper_ggml` 依賴 `echo_core` | 可以，path 依賴，`ECHONOTE.md` 記一筆 |
| A2 | worker 被 kill 時的 buffer | 接受約 6 KB 洩漏，寫進註解 |
| B1 | audio_ctx 固定或動態 | 兩種都做成參數（另加 commit 秒數參數），實機各量一次 |
| B2 | 採用門檻 | 中位數 total_ms 降 20% 以上且文字沒有明顯變差 |
| B3 | 量測切換方式 | 改 `kLivePreviewConfig` 重新建置，不加 debug 畫面 |
| C1 | 調查時間上限 | 實機 1 輪（約 30 分鐘） |
| D1 | VAD 是否接進 App | 本週只評估 |
| D2 | 人工標記 | 3 段、每段 30～60 秒、粒度 0.5 秒 |
| D3 | 評估程式位置 | 放進 repo（`tool/vad_eval/`） |
| D4 | 濾除目標 | 非語音聲音；電視對白列為已知限制 |
| D5 | 錄音素材 | 安靜說話／只有電視或音樂／說話加電視 |
| D6 | 候選範圍 | 實作 D-a（Silero）＋對照組，D-b／D-c 只寫成本分析 |
| E1 | Swift 包裝形式 | SwiftPM |
| E2 | iOS 驗證範圍 | `swift test`＋iOS 模擬器編譯，不接進 Runner |
| E3 | C target 的 `-Werror` | 開 |
| R1 | 證明辨識結果沒變 | 單元測試證明轉換逐位元相同；實機只做回歸 |
| R2 | B 的量測方式 | 實機量耗時，品質用同一份朗讀稿目視比較 |
| R3 | C 的變體在 Mac 跑 | 要 |
| R4 | stop 時的推論套用 audio_ctx | 是 |
| R5 | 執行順序 | 先做不需要實機的部分，實機時段一次測完 |
| R6 | 合併前更新 README | 要 |

## 任務拆解

> 2026-10-10 初版。依據本規格與程式碼現況拆解：`whisper_live.dart` 的 `_liveWorker`（`feed` 分支）是 PCM 轉換的位置；`whisper_flutter_plus.cpp` 的 `stream_run_inference`／`stream_start` 是 audio_ctx 與 commit 秒數要接的地方；`STREAM_COMMIT_SAMPLES` 目前是常數；內建 whisper.cpp 已有 `whisper_vad_*` API。專案沒有 `CLAUDE.md`，不需要查核已知風險清單。所有任務都屬於「可獨立進行」，沒有需要外部團隊配合的項目。標 📱 的任務需要 iPhone 實機（使用者約 90 分鐘後可配合）。

### 階段 1：不需要實機（先做）

**A. 餵資料改寫**

- [ ] **T1.1** `echo_core` 新增 `PcmFloatBuffer`：`convert`（輸入零複製、輸出寫進重複使用的 malloc buffer）、`dispose`、`allocations`、`NativeFinalizer`；空輸入回傳 `nullptr`。依賴：無。
- [ ] **T1.2** `echo_core` 測試：`convert` 結果與舊的 Dart 迴圈（`/ 32768.0`）逐位元相同（決定 #R1）、重新配置、`dispose` 前後與兩次 `dispose`。依賴：T1.1。
- [ ] **T1.3** `whisper_ggml`：`pubspec.yaml` 加 `echo_core` path 依賴；`_liveWorker` 改用 `PcmFloatBuffer`（session 一個、stop 時 `dispose`；被 kill 的洩漏寫進註解，決定 #A2）；標 `[echonote]`，`ECHONOTE.md` 補一筆。App 端 `flutter pub get`、iOS 模擬器建置通過。依賴：T1.1。

**B. audio_ctx 接線**

- [ ] **T1.4** `whisper_flutter_plus.cpp`：`stream_start` 讀 `audio_ctx`（0 預設、-1 動態、其他夾到 1～1500）與 `commit_sec`（預設 25，取代常數 `STREAM_COMMIT_SAMPLES`）；`stream_run_inference` 設 `wparams.audio_ctx`（動態：`ceil(秒數 × 50) + 餘量`，上限 1500）；metrics 加 `audio_ctx`、`commit_sec`。依賴：無。
- [ ] **T1.5** Dart 參數一路接上：`startWhisperLiveSession`、`WhisperController.transcribeLive`、`LivePreviewConfig`（`audioCtx` 預設 0、`commitSec` 預設 25）、`LiveTranscriptionService.start` 傳入。預設值下行為不變；iOS 模擬器建置通過。依賴：T1.4。

**C. 零複製調查（Mac 部分）**

- [ ] **T1.6** `lib/benchmark.dart` 加變體：H1 零複製寫進重複使用的 `Float32List`；H2 印出輸出位址對齊、對齊與非對齊 buffer 各量；H3 零複製輸入＋native 輸出＋`fromList`。Mac 用 `dart build cli` AOT 跑並記錄（決定 #R3）。iPhone 用的 `integration_test` 跟著共用。依賴：無（T1.1 完成後可順便把 `PcmFloatBuffer` 也列進比較）。

**E. Swift 包裝**

- [ ] **T1.7** `packages/echo_core/Package.swift`：C target 指向 `src/`（同一份原始碼），C11、`-O3`、`-ffp-contract=off`、`-Werror`（決定 #E3）；Swift target `EchoCore`：`EchoCore.pcm16ToFloat`／`rms`／`waveform` 與 `final class EchoVAD`（`init?`、`process`、`reset`、`deinit`）。依賴：無。
- [ ] **T1.8** XCTest：手算的邊界案例（空輸入、-32768、`buckets` ≤ 0、`buckets` > n）、VAD「安靜 → 說話 → 安靜」判斷、`EchoVAD` 釋放；`swift test` 通過。依賴：T1.7。
- [ ] **T1.9** `xcodebuild` 編譯 iOS 模擬器版本確認通過（決定 #E2）；確認 SwiftPM 的 `.build/` 不會被 build hook 或 Flutter 誤收進 App、也已被 `.gitignore` 排除。依賴：T1.7。

**D. VAD 評估（準備）**

- [ ] **T1.10** `tool/vad_eval/`：在 Mac 編內建 whisper.cpp 原始碼，讀 16 kHz WAV，每 100 ms 輸出能量門檻（對照組）與 Silero（`whisper_vad_detect_speech_no_reset`）的判斷與處理時間；下載 ggml Silero 模型（不進 git）；附 README 說明怎麼跑。先用合成訊號或既有錄音確認能跑。依賴：無。
- [ ] **T1.11** 人工標記格式與比對程式：標記檔（每 0.5 秒有沒有人聲）→ 算各方法的命中率／誤判率。依賴：T1.10。

### 階段 2：📱 實機時段（一次測完，決定 #R5）

- [ ] **T2.1** 📱 A 的回歸：即時錄音能出現即時文字、停止後完成轉錄（不比對文字，決定 #R1）。依賴：T1.3。
- [ ] **T2.2** 📱 C 的 iPhone 數據：profile 模式跑含 H1～H3 變體的效能比較（30 分鐘上限，決定 #C1）。依賴：T1.6。
- [ ] **T2.3** 📱 B 的量測：同一份約 2 分鐘朗讀稿，量 2～3 種設定（基準 0／動態 -1／固定值＋對應的 `commitSec`），記錄 encode_ms、total_ms、落後秒數，文字由使用者目視比較。依賴：T1.5。
- [ ] **T2.4** 📱 D 的素材：使用者錄 3 段（安靜說話／只有電視或音樂／說話加電視，每段 30～60 秒），把 WAV 從 App 取出到 Mac。依賴：無。

### 階段 3：整理結果

- [ ] **T3.1** 依 T2.3 的結果和決定 #B2 的門檻，決定 `kLivePreviewConfig` 的 `audioCtx`／`commitSec`，結果寫回規格。依賴：T2.3。
- [ ] **T3.2** C 的結論：改寫 README「從數據學到的」第 4 點（查明的原因，或排除了哪些假設）。依賴：T2.2。
- [ ] **T3.3** D 的評估：標記 3 段素材（T1.11 格式）、跑 `tool/vad_eval`、把結果與 D-b／D-c 成本分析寫成報告（放 `tool/vad_eval/README.md` 或規格），附建議。依賴：T1.11、T2.4。
- [ ] **T3.4** 更新 `packages/echo_core/README.md`：Swift 用法、`PcmFloatBuffer`、C 的結論（決定 #R6）。依賴：T1.9、T3.2。
- [ ] **T3.5** 用 `/spec-check` 核對、用 `/devlog` 整理開發紀錄，再 merge 進 master（每週一次）。依賴：階段 1～3 全部完成。

### 任務摘要

- 共 20 項，全部「可獨立進行」；4 項需要實機（T2.1～T2.4）。
- 實機前可以完成：T1.1～T1.11。實機時段最好已經完成 T1.3、T1.5、T1.6，才能一次測完。
- 關鍵路徑：T1.4 → T1.5 → T2.3 → T3.1（B 的結論依賴實機量測）。

## 待確認事項

目前無。
