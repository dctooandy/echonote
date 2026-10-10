# echo_core 第 2 週開發紀錄

分支：`feature/echo-core-w2`
狀態：已完成（2026-10-10）。已合併到 master（`5cc57fb`）。

本週把 `echo_core` 接進 whisper 即時串流。本週也用 iPhone 調整即時預覽，調查第 1 週的效能問題，評估 VAD，並增加 Swift 包裝。

- 規格：[`docs/specs/feature-echo-core-w2/`](../specs/feature-echo-core-w2/feature-echo-core-w2.md)
- 第 1 週紀錄：[`feature-echo-core.md`](feature-echo-core.md)

## 用語

本文件的每個用語只有一個意思。

| 用語 | 意思 |
| --- | --- |
| chunk | 100 ms 的音訊，等於 1600 個樣本（16 kHz） |
| 推論 | whisper 對一段音訊執行一次辨識 |
| 視窗 | 一次推論處理的音訊長度 |
| commit 秒數 | 視窗到達這個長度時，App 保存文字並清空視窗 |
| `audio_ctx` | whisper encoder 處理的音訊長度。單位是 frame，每秒 50 個 frame。預設值是 1500（30 秒） |
| leaf call | Dart 呼叫一個短的 C 函式。呼叫期間，Dart 不移動記憶體 |
| 零複製 | Dart 把自己的陣列位址直接交給 C，不複製資料 |
| native buffer | 用 `malloc` 配置的記憶體 |
| 偵測率 | 標記為人聲的 chunk 中，VAD 判斷為人聲的比例 |
| 誤判率 | 標記為非人聲的 chunk 中，VAD 判斷為人聲的比例 |

## 目標

- A：whisper worker 用 `ec_pcm16_to_float` 轉換 PCM16。每個 chunk 不再配置和釋放記憶體。
- B：即時預覽增加 `audio_ctx` 參數。用 iPhone 的量測結果決定預設值。
- C：調查 iPhone 上 `pcm16ToFloat` 零複製比 native buffer 慢的原因。
- D：比較 Silero VAD 和能量門檻。寫出報告。不接進 App。
- E：用 SwiftPM 包裝 `echo_core`。比較 Swift 和 dart:ffi 管理指標與資源的方法。

## 問題與修正

每個問題分成三部分：現象、原因、修正。

### 一、FFI 的規則

#### 1. `stream_feed` 不能使用 Dart 的記憶體

**現象**：我們想把轉換好的 `Float32List` 直接交給 `stream_feed`。這個做法不可行。

**原因**：

- Dart 只在 leaf call 中允許零複製。
- `stream_feed` 執行推論，一次需要數百 ms。所以它不能是 leaf call。

**修正**：

- 把工作分成兩步。
- 第 1 步：用 leaf call 執行 `ec_pcm16_to_float`。輸入使用零複製。輸出寫入 `PcmFloatBuffer` 的 native buffer。
- 第 2 步：把這個 native buffer 交給 `stream_feed`。
- `PcmFloatBuffer` 重複使用同一個 native buffer。資料變大時，它才重新配置。

#### 2. Dart 不能讀取陣列的位址

**現象**：

- H2 需要知道新的 `Float32List` 是否 16 bytes 對齊。
- analyzer 拒絕 `list.address.address`。錯誤訊息是：`The '.address' expression can only be used as argument to a leaf native external call`。
- 我們把 `.address` 傳給一個普通的 Dart 函式。analyzer 也拒絕。

**原因**：`.address` 不是普通的值。它只能直接放在 leaf 原生呼叫的參數中。

**修正**：

- 用 `@Native` 宣告 libc 的 `memmove`，並設定為 leaf。
- 呼叫 `memmove(p, p, 0)`。長度是 0，所以它不讀寫記憶體。
- `memmove` 回傳 `p`。這個值就是陣列的位址。

### 二、`audio_ctx` 調整

#### 3. 動態 `audio_ctx` 使文字重複

**現象**：

- 動態模式依照視窗長度計算每次推論的 `audio_ctx`。
- 中位數推論時間從 1809 ms 降到 658 ms。
- 但是預覽文字重複「有一個字」很多次。文字中也有簡體字。

**原因**：

- 每次推論的 `audio_ctx` 都不同，範圍是 177～1377。
- 即時預覽關閉了 temperature fallback（`noFallback`）。所以模型開始重複後，沒有機制停止重複。
- 我們沒有確認主要原因是「`audio_ctx` 改變」還是「`audio_ctx` 太小」。

**修正**：

- 不使用動態模式。
- 使用固定的 `audio_ctx` 768（約 15 秒），並把 commit 秒數改為 15 秒。
- 結果：中位數推論時間從 1809 ms 降到 516 ms。最大落後從 4.8 秒降到 1.0 秒。使用者認為這組的文字最好。
- 這組設定現在是 `kLivePreviewConfig` 的預設值。

#### 4. 一部分加速來自較短的視窗

**現象**：固定 768 組的中位數視窗是 9.0 秒。基準組是 14.6 秒。

**原因**：

- `audio_ctx` 768 只能處理 15 秒的音訊。
- 所以 commit 秒數必須從 25 秒降到 15 秒。
- 這次測試同時改變了兩個參數。

**修正**：

- 我們記錄這個限制。
- 我們沒有測量「`audio_ctx` 0 加 commit 15 秒」。所以兩個參數各自的效果不明。
- 採用標準是：中位數推論時間至少減少 20%，而且文字沒有變差。這組設定符合標準。

#### 5. 每次切換設定都要修改程式碼

**現象**：原本的計畫是每量一組就修改 `kLivePreviewConfig`。這個做法容易出錯。

**修正**：

- `audioCtx` 和 `commitSec` 用 `int.fromEnvironment` 讀取 `--dart-define`。
- Dart 沒有 const 的 `double.fromEnvironment`。所以 `LivePreviewConfig.commitSec` 使用整數秒。App 傳給套件時，把它轉成 `double`。
- debug 建置在錄音結束時印出 `[live-metrics]` 摘要。摘要包含中位數和預覽全文。

### 三、零複製調查

#### 6. 第 1 週的問題沒有再發生

**現象**：

- 第 1 週：iPhone 上零複製是 0.87 µs，native buffer 是 0.59 µs。兩次量測結果相同。
- 第 2 週：零複製是 0.49 µs，native buffer 是 0.54 µs。零複製比較快，和 Mac 相同。

**原因**：

- 原因不明。
- 已知的差異只有執行方式。第 1 週使用 Xcode 的 Profile 設定。第 2 週使用 USB 和 `flutter drive --profile`。
- 依照決定 #C1，調查只做一輪。我們沒有再驗證。

**修正**：README 只寫已經證明的結論：

- 配置輸出陣列需要 0.31 µs。轉換只需要 0.13 µs。所以配置佔了大部分時間。
- 新的 `Float32List` 在 1000 次配置中都是 16 bytes 對齊。
- 位址錯開 4 bytes 時，只慢 0.03 µs。所以對齊不是原因。

#### 7. Mac 第一次的結果異常

**現象**：

- Mac 第一次執行：零複製和 native buffer 都是 0.55 µs。
- 第二次和第三次：零複製是 0.31 µs，native buffer 是 0.46 µs。

**修正**：在 Mac 上執行三次。不使用第一次的結果。規格只記錄第二次和第三次的範圍。

### 四、VAD 評估

#### 8. shell 移除了巨集的引號

**現象**：`build.sh` 編譯 whisper.cpp 時失敗。錯誤是 `invalid suffix '.1' on floating constant`，位置在 `return WHISPER_VERSION;`。

**原因**：`eval` 移除了 `-DWHISPER_VERSION="1.9.1"` 的引號。所以巨集變成數字 `1.9.1`，不是字串。

**修正**：在 `DEFS` 中寫 `\"1.9.1\"`。`eval` 展開後，巨集是 C 字串。

#### 9. Silero 不能在串流中補零

**現象**：

- Silero 一次處理 512 個樣本。
- 一個 chunk 有 1600 個樣本，不是 512 的整數倍。
- `whisper_vad_detect_speech_no_reset` 會在不足 512 的尾端補零。

**修正**：

- 每次只送 512 的整數倍。
- 把剩下的樣本加到下一個 chunk。
- 結果：串流中不補零。

#### 10. 電視素材只有對白

**現象**：在 `tv_only` 上，Silero 的誤判率是 93.7%。能量門檻是 66.2%。Silero 比較差。

**原因**：

- 電視播放的是對白。對白是人聲。
- 語音型 VAD 不能分辨現場的人和電視中的人。規格的決定 #D4 已經記錄這個限制。
- 所以這段素材不能證明 VAD 能否過濾音樂和雜訊。

**修正**：

- 增加一段 20 秒的 `music_only` 素材，只有音樂。
- 結果：能量門檻的誤判率是 86.0%。Silero 是 0%，最高機率是 0.059。
- 結論：Silero 能過濾非語音聲音。Silero 不能過濾電視對白。

#### 11. 標記草稿可能偏向 Silero

**現象**：

- 為了減少人工，我們用 Silero 的判斷產生標記草稿。然後使用者確認草稿。
- `speech_tv` 的草稿是整段。原因是 Silero 把電視聲音也判斷為人聲。

**修正**：

- 使用者確認 `quiet_speech` 的草稿正確。
- 使用者確認自己在 `speech_tv` 中幾乎一直在說話。
- 報告記錄以下限制：
  - 標記可能偏向 Silero。
  - `speech_tv` 只有 9 個非人聲 chunk。
  - 每一類素材只有一段，約 20 秒。
  - 所以結論只能表示方向。

#### 12. `devicectl` 和 Flutter 使用不同的裝置 ID

**現象**：`xcrun devicectl device copy from` 找不到 `flutter devices` 顯示的 ID（`00008101-…`）。

**原因**：

- Flutter 使用裝置的 UDID。
- `devicectl` 使用 CoreDevice 的 Identifier（`BC5C89A2-…`）。

**修正**：先執行 `xcrun devicectl list devices` 取得 Identifier。`tool/vad_eval/README.md` 已經寫入這個步驟。

## 測試方法

### `echo_core` 單元測試

1. 執行 `cd packages/echo_core && dart test`。
2. 確認 20 項測試通過。

新增的 `PcmFloatBuffer` 測試檢查以下項目：

- 結果和 whisper worker 的舊迴圈完全相同。
- buffer 只在需要時變大。
- 空輸入回傳 `nullptr`。
- `dispose` 前後的行為正確。

### Swift

1. 執行 `cd packages/echo_core && swift test`。
2. 確認 6 項測試通過。測試包含邊界值、VAD（安靜→說話→安靜）和 `deinit` 釋放。
3. 執行 `xcodebuild -scheme EchoCore -destination 'generic/platform=iOS Simulator' build`。
4. 確認建置成功。

### App

1. 執行 `flutter test`。確認 11 項測試通過。
2. 每次修改後，執行 `flutter build ios --simulator --debug`。

### 效能比較

1. Mac：用 `dart build cli` 建立 AOT 執行檔。執行三次。
2. iPhone 12 Pro Max：用 USB 連接。執行 `flutter drive --profile --target=integration_test/echo_core_benchmark_test.dart`。
3. 結果記錄在 `packages/echo_core/README.md`。

### 即時預覽調整

1. 使用 iPhone 12 Pro Max 和 debug 建置。whisper C++ 一定使用 `-O3`。
2. 每組設定錄一次。每次都朗讀同一份 521 字的稿子。
3. 讀取 `[live-metrics]` 摘要。
4. 使用者比較三組的文字品質。

### A 的回歸測試

使用者確認以下項目：

- 即時錄音時，文字持續出現。
- 停止錄音後，離線轉錄完成。
- 錄音紀錄正確保存。

### VAD

1. 用 `say` 合成一段中文語音。用它做冒煙測試。
2. 執行 `tool/vad_eval/build.sh`。
3. 對 4 段實機素材執行 `build/vad_eval <模型> <wav> <標記>`。

## 待辦事項與已知限制

### 待辦事項

- 第 3 或第 4 週：用 Silero 決定即時串流何時推論。模型下載失敗時，使用能量門檻。
- 開始前，在 iPhone 上量測 Silero 的處理時間。目前只有 Mac 的結果：每個 chunk 約 200 µs。
- 如果需要，量測 `LIVE_AUDIO_CTX=0 LIVE_COMMIT_SEC=15`。這組結果能分開兩個參數的效果。
- 第 3 週：Android。第 4 週：C 單元測試、ASan、CI。
- 職缺分析建議增加 JNI 範例和 CI。
- 在 GitHub 公開前，處理 Firebase 設定檔。使用者稍後決定。

### 已知限制

- VAD 不能過濾電視對白。分辨對白需要說話者辨識或方向性收音。這些工作不在計畫範圍內。
- 動態 `audio_ctx` 造成文字重複的原因不明。參數保留在程式中，但不建議使用。
- 第 1 週零複製較慢的原因不明。原因可能和執行方式有關。
- VAD 素材每一類只有一段，約 20 秒。標記可能偏向 Silero。
