# 原生麥克風串流＋即時逐字稿 規格

分支：`feature/native-mic-stream`
狀態：已確認（2026-10-08，17 項決定皆已確認；任務拆解的 2 項待確認事項也已決定）；技術驗證**有條件通過**：即時預覽用 `tiny`＋調校參數，離線用 `base`

這份文件記錄「在 App 內直接錄音，並一邊錄一邊顯示逐字稿」的功能。做法是自己寫原生的 Platform Channel（iOS 用 `AVAudioEngine`），輸出 16 kHz、mono、PCM16 的音訊串流，交給 `whisper_ggml` 的 `WhisperController.transcribeLive()` 做裝置端即時辨識。錄音結束後，再用存下來的 WAV 跑一次既有的離線轉錄，產生正式的逐字稿。

做這個功能有兩個目的：(1) 補上 v1 刻意不做的「App 內錄音」；(2) 自己實作 MethodChannel／EventChannel，不依賴現成的錄音套件，藉此累積原生整合的經驗。

> 跟 v1 範圍的關係：v1 原本明確寫「只匯入既有錄音檔，不做 App 內錄音」。這份規格屬於 v1 之後的擴充。

**整體原則**：只做 iOS；盡量沿用既有的匯入流程；先追求「錄得穩、存得下來」。即時文字只當作錄音中的預覽，最終的逐字稿一律來自離線轉錄。

## 即時預覽的實際顯示方式

這一節根據 `whisper_ggml` 2.4.0 的原生串流實作（`ios/Classes/whisper_flutter_plus.cpp`）整理，用來校正預期：**不是一個字一個字出現。**

- 累積 **1.5 秒以上的新語音**才重新辨識一次，所以畫面每次冒出一個詞組或半句話。
- 每次都把目前視窗（**最多 25 秒**）整段重新辨識，所以最近 25 秒內的文字可能被修改。
- 視窗超過 25 秒就定稿，之後那段文字不再變動。
- 靜音不會觸發辨識，畫面維持不動。
- whisper 是一次處理一整段音訊的模型，不是串流模型。真正逐字出現需要串流辨識引擎，不在這份規格的範圍內。

**延遲風險（推算，尚未實測）**：whisper 內部會把音訊補滿成 30 秒再處理，所以每次重新辨識的成本跟新增音訊多寡關係不大。依離線轉錄實測（iPhone 12 Pro Max，`base`，0.37 倍音檔長度，換算每 30 秒約 11 秒），每次重新辨識可能需要數秒。只要辨識一次所需的時間超過 1.5 秒，套件的佇列就會持續累積，造成預覽越來越落後、記憶體持續上升。所以要先做第 0 步的技術驗證。

## 第 0 步：技術驗證（spike）

在依照本規格全部開發之前，先做一個最小原型，在實機上量測即時辨識跟不跟得上。

**範圍**：

- 實作 `MicStreamChannel.swift`（MethodChannel `echonote/mic` + EventChannel `echonote/mic/pcm`）和 `MicStreamService`，介面依照本規格的「新增 Platform Channel」一節。這部分正式開發會直接沿用。
- 一個臨時的測試畫面：開始／停止按鈕，加上 `transcribeLive(model: ..., lang: 'zh')` 的即時文字。
- 量測並顯示以下數值（可以只用 `debugPrint` 加上畫面上的簡單文字）：
  - 每次 partial 更新的間隔（秒）；
  - 已送出的音訊秒數，以及 partial 對應的最新進度；兩者的差距就是「落後秒數」；
  - App 的記憶體用量（用 Xcode Instruments 或 Debug Navigator 觀察）。
- 不做 WAV 寫入、不改資料模型、不做正式 UI、不處理中斷和路由改變。

> 補充：套件沒有直接提供「partial 對應到哪個音訊時間點」。量測時可以在 fork 或除錯版本裡記錄每次 `stream_run_inference` 的耗時，或在 Dart 端用「送出的音訊秒數」與「收到 partial 的時間」推估。這個量測用的修改只在技術驗證期間使用，不併入正式程式碼。

**測試方式**：在 iPhone 12 Pro Max 上，用 `base` 和 `tiny` 各錄 5 分鐘連續講話（例如朗讀文章），記錄上述數值。

**判斷標準與後續決定**：

| 實測結果 | 判定 | 後續 |
| --- | --- | --- |
| `base` 的單次辨識中位數 ≤ 2 秒，而且 5 分鐘內落後秒數沒有持續增加 | 通過 | 依照本規格繼續開發，即時預覽用 `base` |
| `base` 跟不上，但 `tiny` 符合上一列的條件 | 有條件通過 | 即時預覽改用 `tiny`，最終逐字稿仍然用 `base` 跑離線轉錄。首次使用需要額外下載 `tiny` 模型（約 75 MB） |
| `base` 和 `tiny` 都跟不上 | 不通過 | 暫停正式開發，回頭評估：(a) 修改 whisper.cpp，縮小 `audio_ctx`，讓短音訊不必補滿 30 秒（屬於技能樹第 2 項）；(b) 錄音中不顯示即時文字，只錄音，結束後再轉錄 |

技術驗證的結果和決定要寫回這一節，並更新開頭的「狀態」欄位。

### 結果（2026-10-08，iPhone 12 Pro Max，debug 模式）

**判定：有條件通過。** 即時預覽用 `tiny`、4 threads，並調整串流參數；離線轉錄仍用 `base`。

| 設定 | 單次辨識中位數 | 落後趨勢 | 結果 |
| --- | --- | --- | --- |
| `base`，原始參數，2／4 threads（約 31 秒） | 3333／2465 ms | 持續增加，停止時落後 13–17 秒 | 不通過 |
| `tiny`，原始參數，4 threads（5 分鐘） | 約 1 秒，第 40 輪起暴增到 5–20 秒 | 約 50 秒後失控，停止時積壓 216 秒；手機很燙 | 不通過 |
| `tiny`，調校後，4 threads（231 秒） | **898 ms** | 最大 2.0 秒，沒有上升趨勢；停止後 1.7 秒定稿；不燙 | **通過** |

- **調校內容**：重算間隔 1.5 → 3 秒、關閉 temperature fallback（`temperature_inc = 0`）、每段最多 64 token。即時文字約每 3 秒更新一次。
- **瓶頸分析**：encoder 固定補滿 30 秒，占單次耗時 70–90%；原始參數下失控的主因推測是 temperature fallback 的重解碼，發熱降頻（encoder 慢約 60%）是次因。
- 記憶體 550–670 MB，長時間持平，沒有洩漏。
- 4 threads 比 2 threads 快（encoder 較快，但每個 token 的 decode 較慢）。
- **依賴**：調校參數和量測數據需要修改 `whisper_ggml`，已經內建在 `packages/whisper_ggml`（path 依賴，只放 iOS＋Dart）。修改內容見該資料夾的 `ECHONOTE.md` 和 commit `082105c`。
- **繁體中文**：即時模式沒有 prompt 時夾雜不少簡體字（`no_context`）。加上 `initialPrompt`「以下是繁體中文的會議逐字稿。」後，1 分鐘實測全部是繁體，prompt 也沒有混進輸出 → 設為 `kLivePreviewConfig` 的預設值，不需要簡轉繁。
- 縮小 `audio_ctx` 目前不需要，留作之後的優化（技能樹第 2 項）。

## 目標與範圍

- 使用者從首頁的展開式 FAB 選擇「即時錄音」，按下開始後，App 透過原生麥克風串流收音。
- 錄音期間，畫面持續顯示 whisper 產生的即時逐字稿（`WhisperLiveSession.partials`，每次都是完整全文，會覆蓋上一次的內容），作為**預覽**。
- 錄音同時寫入 WAV 檔。
- 停止後，先存成一筆 `Recording`（狀態為「未轉錄」），接著用 WAV 跑既有的離線 `transcribe()`，產生正式的 segments，完成後導向 `MeetingDetailScreen`。之後的分析、播放流程跟匯入的錄音一致。
- 離線轉錄失敗或沒有辨識出內容時，錄音和紀錄照樣保留，使用者之後可以「重新轉錄」。
- 辨識全程在裝置上進行，**不呼叫任何雲端 API、不消耗 token**。
- 原生層自己實作，不使用 `record`、`flutter_sound`、`mic_stream` 等現成的錄音套件。

**明確不做的事**：

- **Android**：這個分支只做 iOS。Channel 介面寫成兩個平台共用，Android 的 `AudioRecord` 實作另外開分支（決定 #2）。
- **背景錄音**：App 進入背景就自動停止並存檔（決定 #5）。
- **中斷後自動恢復錄音**：來電等中斷一律結束並存檔（決定 #11）。
- **提升辨識準確度**（換模型、調整 `initialPrompt`／gate 參數、改用 `.measurement` mode）：等功能做完再實測評估。例外（皆由第 0 步技術驗證決定，目的不是準確度）：即時預覽改用 `tiny` 並調整串流參數（為了速度）；即時預覽加上繁體 `initialPrompt`（為了避免簡體字）。
- **在 FFI 層做 buffer 優化、縮小 `audio_ctx`**：那是技能樹的第 2 項。註：技術驗證後已將 `whisper_ggml` 內建到 `packages/whisper_ggml` 並做了必要修改（串流可調參數、每次推論的 `metrics`、模型下載改為串流並回報進度），見該資料夾的 `ECHONOTE.md`。
- **錄音期間的即時摘要或分析**：避免 token 費用倍增，分析仍然在結束後由使用者手動觸發。
- **說話者辨識（diarization）**。
- **在 UI 上顯示 `source` 欄位**：先只存資料（決定 #4）。

## API 異動

### 後端 API

無。`analyzeMeeting` Cloud Function 不變。

### 新增 Platform Channel（Dart ↔ 原生的介面契約）

這份契約設計成 iOS 和 Android 共用。這個分支只實作 iOS。

#### MethodChannel `echonote/mic`

| method | 參數 | 回傳 | 說明 |
| --- | --- | --- | --- |
| `getPermissionStatus` | 無 | `String`：`granted`／`denied`／`permanentlyDenied`／`undetermined` | 查詢麥克風權限，不會跳出系統詢問。iOS 被拒絕後不會再詢問，所以一律回 `permanentlyDenied`，不會回 `denied` |
| `requestPermission` | 無 | `bool` | 跳出系統的權限詢問；權限已經被永久拒絕時直接回 `false` |
| `start` | `{ "sampleRate": 16000, "chunkMs": 100 }` | `null` | 開始收音，PCM 從 EventChannel 送出。已經在錄時回傳錯誤 `ALREADY_RUNNING` |
| `stop` | 無 | `null` | 停止收音並釋放原生資源，結束 EventChannel 的串流。沒在錄音時呼叫也不算錯誤（idempotent） |
| `openSettings` | 無 | `bool` | 開啟系統設定裡本 App 的頁面，讓使用者在拒絕後開啟麥克風權限（2026-10-08 新增，取代額外依賴 `url_launcher`） |

錯誤一律用 `FlutterError`／`PlatformException` 的 `code` 區分：

| code | 情境 |
| --- | --- |
| `PERMISSION_DENIED` | 沒有麥克風權限就呼叫了 `start` |
| `ALREADY_RUNNING` | 重複呼叫 `start` |
| `AUDIO_SESSION_ERROR` | `AVAudioSession` 設定失敗或 engine 啟動失敗（Android：`AudioRecord` 初始化失敗） |
| `FORMAT_UNSUPPORTED` | 無法轉換成 16 kHz mono PCM16 |
| `INTERRUPTED` | 收音途中被系統中斷（來電、Siri、其他 App 搶走音訊），以 EventChannel 錯誤事件送出 |
| `BACKGROUNDED` | App 進入背景，原生端主動停止收音，以 EventChannel 錯誤事件送出 |

#### EventChannel `echonote/mic/pcm`

- **事件型別**：`Uint8List`（原生端是 `FlutterStandardTypedData`），內容是 16 kHz、mono、PCM16 little-endian 的音訊。
- **每個 chunk 長度**：**100 ms**，也就是 1600 個 sample、3200 bytes（決定 #15）。chunk 長度**必須是偶數 bytes**（套件可以處理奇數長度，但原生端應該保證是偶數）。
- **執行緒**：`FlutterEventSink` 必須在 main thread 呼叫。`installTap` 的 callback 在 audio thread 上，要切回 main thread 再送出。
- **錯誤事件**：發生中斷或進入背景時，先送 `error(code, message)`（`INTERRUPTED`／`BACKGROUNDED`），再送 `endOfStream`。
- **結束**：`stop` 被呼叫後，原生端送出 `endOfStream`，Dart 的 stream 進入 `onDone`。這會觸發套件裡的 `session.stop()`（`transcribeLive` 用 `onDone: session.stop` 監聽傳入的 stream）。

#### iOS 原生實作要點

- **`AVAudioSession`**（決定 #6）：
  - category 用 `.playAndRecord`，mode 用 `.default`（保留系統的語音處理和降噪）。
  - 不開啟與其他 App 混音。
- **收音**：在 `AVAudioEngine.inputNode` 上 `installTap`，取得硬體原生格式的音訊（通常是 48 kHz Float32），再用 `AVAudioConverter` 轉成 16 kHz、mono、Int16。
- **硬體格式改變**（插拔耳機、藍牙連線或斷線）：監聽 `AVAudioEngineConfigurationChange`——硬體格式改變時 engine 會自行停止，只監聽 `routeChangeNotification` 接不回來。收到後重新安裝 tap（每個 tap 各自持有 converter 與暫存，避免與 audio thread 競爭）並重新啟動 engine，串流不中斷；切換瞬間最多遺失不到一個 chunk。
- **中斷**（`AVAudioSession.interruptionNotification`）：收到 `.began` 就停止 engine，送出 `INTERRUPTED`，然後結束串流。
- **進入背景**：收到 `UIApplication.didEnterBackgroundNotification` 就停止收音，送出 `BACKGROUNDED`，然後結束串流。
- **檔案位置**：`ios/Runner/MicStreamChannel.swift`，在 `AppDelegate` 註冊。

#### Android 實作備忘（不在這個分支）

之後實作時：用 `AudioRecord` 直接設定 16 kHz、`CHANNEL_IN_MONO`、`ENCODING_PCM_16BIT`，音源用 `VOICE_RECOGNITION`（決定 #7）。`read()` 迴圈放在獨立 thread，切回 main looper 再呼叫 `EventSink.success`。

### Dart 端新增與異動

- **新增 `lib/services/mic_stream_service.dart`**：`MicStreamService`，包裝上述兩個 channel。
  - 對外提供 `Future<MicPermission> permissionStatus()`、`Future<bool> requestPermission()`、`Future<Stream<Uint8List>> start()`、`Future<void> stop()`。
  - 把 `PlatformException` 轉成專案自己的例外型別。
  - 重複呼叫 `start` 在 Dart 端就擋下（`alreadyRunning`），不送到原生端：EventChannel 在原生端只有一個 sink，重複監聽會搶走正在錄的串流。
  - 另有 `openSettings()`，對應 channel 的 `openSettings`。
- **新增 `lib/services/live_transcription_service.dart`**：`LiveTranscriptionService`。
  - 呼叫 `WhisperController.transcribeLive(lang: 'zh', ...)`，其餘參數來自 `kLivePreviewConfig`：`tiny`、4 threads、每 3 秒重算、關閉 temperature fallback、每段最多 64 token、繁體 `initialPrompt`「以下是繁體中文的會議逐字稿。」（依第 0 步技術驗證）。**`lang` 必須明確傳 `'zh'`**：套件預設是 `'en'`，而 `'auto'` 有已知 bug。
  - `ensureModels()` 在錄音前依序確保 `tiny`（即時用）和 `base`（離線用）都已下載，並回報進度；套件的下載改為邊下載邊寫入 `.part` 檔、檢查 HTTP 狀態，完成才改名。
  - `LiveRecording` 對外提供：`preview`（完整預覽文字）、`lagSeconds`（落後秒數 = 已送出的音訊秒數 − 套件 `metrics` 的 `fed_sec`）、`notices`（`previewDelayed`／`previewCaughtUp`／`previewStopped`／`nearLimit`）、`done`（結束原因、預覽文字、實際寫入的音訊長度、WAV 是否可用）。
  - 同一份 PCM 串流要同時送給 whisper 和 WAV 寫入器。因為 Dart 的單一訂閱 stream 不能被聽兩次，要用 broadcast stream 或手動分流。
- **新增 WAV 寫入器**（例如 `lib/services/wav_writer.dart`）：錄音期間把 PCM 持續 append 到檔案，停止時補寫 WAV header 裡的長度欄位。不能把整段音訊放在記憶體裡。
- **異動 `TranscriptionService`／`ImportScreen`**：讓離線轉錄流程可以對「已經存在的 `Recording`」執行，供即時錄音停止後和「重新轉錄」共用。

## 資料表異動

本機的 JSON 儲存（`RecordingStore`，`history/*.json`）：

- **新增 `source` 欄位**（`String`：`import`／`live`，決定 #4）。舊資料沒有這個欄位，讀取時預設為 `import`，不需要遷移。UI 先不顯示。
- **`segments` 允許是空陣列**，代表「未轉錄」（決定 #13）。
  - `Recording` 新增 getter，例如 `bool get isTranscribed => segments.isNotEmpty`。
  - 舊資料一定有 segments，不受影響。
- **音檔**：即時錄音存成 `recordings/<id>.wav`（16 kHz mono PCM16，加上 WAV header）。`audioFileName` 照舊只存檔名，不存絕對路徑。
- **`elapsedSeconds`** 繼續代表「離線轉錄耗時」（決定 #3），跟匯入流程意義一致。未轉錄的紀錄填 `0`。錄音長度需要時從 WAV 檔推算，不另外存。
- **`model`**：沿用 `kWhisperModel.modelName`。

## 權限與狀態機

### 系統權限

- 在 `ios/Runner/Info.plist` 新增 `NSMicrophoneUsageDescription`（目前沒有），說明文字（決定 #8）：

  > echonote 需要使用麥克風錄製會議內容，語音會在裝置上轉成逐字稿，不會上傳到雲端。

- 不新增 `UIBackgroundModes`（決定 #5）。

### 即時錄音的狀態機

```text
（從首頁「即時錄音」進入畫面就開始，不另外按開始）
checkingPermission
      ├─ 沒有權限且可以詢問 → 跳出系統詢問（仍在 checkingPermission）─ 允許 → preparing ／ 拒絕 → permissionDenied
      ├─ 永久拒絕 → permissionDenied（引導使用者到系統設定）
      └─ 已有權限 → preparing（下載或載入模型、啟動 WhisperLiveSession）
preparing ─ 成功 → recording ／ 失敗 → error
recording ─(按停止／達到 2 小時上限)→ finalizing
recording ─(中斷／進入背景／原生錯誤)→ finalizing（保留已錄的內容）
finalizing：stop 原生 → 等 session.stop() → 補寫 WAV header → 存成未轉錄的 Recording
            （header 補寫失敗，或實際音訊不到 1 秒 → 刪除 WAV、不保存 → error）
finalizing ─ 成功 → transcribing ／ 失敗 → error
transcribing（離線轉錄，顯示進度百分比）
 ├─ 成功且有內容 → 更新 Recording 的 segments 與 elapsedSeconds → 導向 MeetingDetailScreen
 └─ 失敗或沒有內容 → 紀錄維持未轉錄，顯示錯誤，提供「返回」
```

- 錄音期間不能再開第二個 session。
- `finalizing` 和 `transcribing` 的時候，停止按鈕停用，避免重複觸發。
- `transcribing` 跟 `ImportScreen` 一樣只在前景執行。

### 未轉錄紀錄的行為

- 首頁的紀錄卡片顯示「未轉錄」標記。
- 進入 `MeetingDetailScreen` 時，顯示「尚未轉錄」和「重新轉錄」按鈕；「分析」按鈕停用；播放功能照常可用。
- 「重新轉錄」走同一套離線轉錄流程，成功後更新同一筆紀錄。

## UI／畫面

**暫定，待正式設計。** 目前整個 App 都使用 Flutter 預設的 Material 主題，以下只定功能需求，不定視覺。

- **首頁入口**（決定 #9）：`HomeScreen` 的 FAB 改成展開式，展開後有「匯入錄音檔」和「即時錄音」兩個選項。
- **新畫面 `LiveRecordScreen`**，需要顯示：
  - 錄音狀態和已錄時間（時:分:秒，因為上限是 2 小時）；
  - 即時逐字稿預覽（全文持續更新，自動捲到最底）；
  - 停止按鈕；
  - 「即時文字可能延遲」提示（見邊界案例的辨識落後）；
  - 剩 5 分鐘到上限時的提示；
  - 權限被拒、模型下載中、錯誤等狀態的提示。
- **錄音中按返回**（決定 #12）：跳出確認對話框，選項是「停止並存檔」和「繼續錄音」。保存中（`finalizing`）不能離開。
- **紀錄名稱**：即時錄音的 `audioName` 為「即時錄音 YYYY-MM-DD HH:mm」（開始錄音的時間），分析後一樣由標題取代顯示。
- **停止後**：同一個畫面切換成轉錄進度，跟 `ImportScreen` 的呈現一致。完成後用 `pushReplacement` 導向 `MeetingDetailScreen`。
- **`HomeScreen`／`MeetingDetailScreen`**：新增未轉錄狀態的顯示，見上一節。
- **刪除紀錄**（2026-10-08 使用者追加）：首頁清單往左滑、或詳細頁右上角選單的「刪除」，都先跳出確認對話框；確認後一併刪除紀錄 JSON 和音檔（`RecordingStore.delete`），不提供復原、不支援多選。詳細頁在轉錄或分析進行中時選單停用。
- **離線轉錄抑制非語音標註**（2026-10-08 錯誤修正）：`TranscriptionService` 改傳 `suppressNonSpeechTokens: true`。某些錄音會讓 whisper 在每個 30 秒視窗開頭輸出「(咖啡)」之類的標註並略過整段人聲；抑制後恢復正常。逐字稿因此不再含「(音樂)」等標註。

## 邊界案例與例外處理

| 情境 | 處理方式 |
| --- | --- |
| 第一次使用，模型還沒下載（約 147 MB） | 在 `preparing` 狀態顯示下載中，下載完才開始收音 |
| 權限被拒或永久拒絕 | 不開始錄音，顯示說明並提供前往系統設定的按鈕 |
| 錄音中來電、Siri 或其他 App 搶走音訊 | 原生端送出 `INTERRUPTED` 並結束串流 → `finalizing` → 照常存檔並轉錄。**不自動恢復**（決定 #11） |
| 音訊路由改變（插拔耳機、藍牙連線或斷線） | 原生端重建 converter 或重新安裝 tap，串流不中斷，送出的資料格式維持 16 kHz mono PCM16 |
| App 進入背景 | 原生端送出 `BACKGROUNDED` 並結束串流 → `finalizing` → 存成未轉錄的紀錄。轉錄需要在前景執行，回到前景後如果還在這個畫面就接著轉錄，否則使用者可以從詳細頁「重新轉錄」 |
| 辨識跟不上即時速度（套件已知限制：佇列無上限、逐字稿越來越落後） | **只顯示提示，不丟棄音訊**（決定 #10）。用內建 `whisper_ggml` 的 `metrics` 算真正的落後秒數：落後 = 已送出的音訊秒數 − 該次辨識開始時原生端已收到的秒數（`fed_sec`）；**超過 6 秒**就顯示「即時文字可能延遲」（2026-10-08 由「15 秒沒有新 partial」改為此法；實測正常落後 0.7–2 秒，6 秒約兩次重算週期）。最終逐字稿來自離線轉錄，不受影響 |
| 長時間錄音 | **上限 2 小時**（決定 #14）。剩 5 分鐘時提示，到達上限自動停止 → `finalizing`。WAV 用串流方式寫入，2 小時約 230 MB |
| 即時辨識中途發生 native 錯誤 | 套件會在 `partials` 送出錯誤，並以最後一次的文字當作定稿。錄音和 WAV 寫入繼續進行，即時預覽顯示「即時文字已停止」。最終逐字稿不受影響 |
| 離線轉錄沒有辨識出內容 | 紀錄維持未轉錄，**保留音檔**（決定 #13），提示「沒有辨識出任何內容」 |
| 離線轉錄失敗 | 紀錄維持未轉錄，保留音檔，顯示錯誤，之後可以「重新轉錄」 |
| 磁碟空間不足，寫入 WAV 失敗 | 停止錄音 → 盡量補寫 WAV header（依實際寫入的 bytes），把已寫入的部分存成未轉錄紀錄。補寫也失敗時（`wavUsable == false`）顯示錯誤，刪除殘缺的檔案 |
| 錄音不到 1 秒（例如一開始就被中斷） | 刪除 WAV，不保存紀錄，顯示「錄音太短，沒有保存」 |
| 錄音中按返回 | 跳出確認對話框（決定 #12） |
| 重複按開始或停止 | 原生端的 `start` 回 `ALREADY_RUNNING`，`stop` 為 idempotent；Dart 端先擋重複 `start`；首頁「即時錄音」在錄音畫面開著時忽略再次點擊；停止按鈕只在 `recording` 狀態有作用 |

## 驗收情境

在實機上執行（決定 #16），之後可以用 `/qa-checklist` 做成可勾選的驗收頁：

1. 錄 5 分鐘，正常停止 → 離線轉錄完成 → 進入詳細頁，逐字稿有分段，點擊可以跳轉播放，可以分析。
2. 錄 30 分鐘 → 觀察記憶體不會持續成長、「即時文字可能延遲」提示的表現，以及錄音、轉錄都完成。
3. 錄音中來電 → 自動停止並存檔，存下來的錄音完整到中斷為止。
4. 錄音中插拔有線耳機、連線或斷開藍牙耳機 → 錄音不中斷，WAV 沒有雜音或變速。
5. 錄音中切到背景 → 自動停止並存成未轉錄紀錄 → 可以從詳細頁「重新轉錄」。

---

## 決定紀錄

17 項決定皆於 2026-10-08 確認，內容已寫回上方各章節：

| # | 項目 | 決定 |
| --- | --- | --- |
| 1 | 逐字稿分段 | 停止後用 WAV 跑離線轉錄取得正式 segments；即時文字只當預覽 |
| 2 | 是否包含 Android | 只做 iOS，Android 另開分支 |
| 3 | `elapsedSeconds` 意義 | 繼續代表離線轉錄耗時 |
| 4 | `source` 欄位 | 新增（`import`／`live`），UI 先不顯示 |
| 5 | 背景錄音 | 不支援，進入背景自動停止並存檔 |
| 6 | `AVAudioSession` | `.playAndRecord` + `.default`，不混音 |
| 7 | Android 音源 | 本分支不適用；之後用 `VOICE_RECOGNITION` |
| 8 | 權限說明文字 | 見「系統權限」 |
| 9 | 首頁入口 | 展開式 FAB |
| 10 | 辨識落後 | 只顯示提示，不丟棄音訊；落後超過 6 秒才提示（依 `metrics` 算真正落後，2026-10-08 修訂） |
| 11 | 中斷後恢復 | 不自動恢復，結束並存檔 |
| 12 | 錄音中按返回 | 確認對話框 |
| 13 | 空結果或失敗 | 保留音檔，存成可重新轉錄的「未轉錄」紀錄 |
| 14 | 錄音上限 | 2 小時，剩 5 分鐘提示 |
| 15 | chunk 長度 | 100 ms |
| 16 | 驗收方式 | 5 個實機驗收情境，見「驗收情境」 |
| 17 | 即時辨識速度風險 | 正式開發前先做第 0 步技術驗證，依實測結果決定即時預覽用 `base`、`tiny`，或回頭評估 |

## 任務拆解

> 2026-10-08 初版。依據本規格與目前程式碼現況拆解。專案沒有 `CLAUDE.md`，所以「已知風險檔案」的提醒改用程式碼註解和專案記憶裡記錄的 workaround 為準。

**分軌說明**：除非另外標註，所有任務都屬於「可獨立進行」。UI 目前是暫定版，正式設計稿出來後才需要設計配合，不阻擋開發。

### 階段 0：技術驗證（決定後續方向，必須最先完成）

- [x] **T0.1** 建立分支 `feature/native-mic-stream`。
- [x] **T0.2** 在 `ios/Runner/Info.plist` 新增 `NSMicrophoneUsageDescription`（文字見「系統權限」）。
- [x] **T0.3** 實作 `ios/Runner/MicStreamChannel.swift`，只做正常路徑：`getPermissionStatus`、`requestPermission`、`start`、`stop`；`AVAudioSession` 設定；`installTap` 加上 `AVAudioConverter` 轉成 16 kHz mono Int16；每 100 ms 切回 main thread 送出一個 chunk。依賴：T0.2。
  - 註冊位置：`AppDelegate` 目前使用 `FlutterImplicitEngineDelegate`，channel 要在 `didInitializeImplicitFlutterEngine` 裡，透過 `engineBridge.pluginRegistry` 取得 registrar 的 messenger 來建立，不能沿用舊的 `window.rootViewController` 寫法。
- [x] **T0.4** 實作 `lib/services/mic_stream_service.dart`（`MicStreamService`），包含 `PlatformException` 轉成專案例外型別。依賴：T0.3。
- [x] **T0.5** 臨時測試畫面：開始／停止、即時文字，以及顯示 partial 更新間隔和已送出的音訊秒數。呼叫 `transcribeLive(lang: 'zh')`，模型可以切換 `base`／`tiny`。依賴：T0.4。
- [x] **T0.6** 量測用的套件修改：在本機 fork 的 `whisper_ggml` 裡記錄每次 `stream_run_inference` 的耗時，用 `dependency_overrides` 或 `pubspec_overrides.yaml` 暫時指向 fork。依賴：T0.5。處置方式見待確認事項 #1（已決定）。
- [x] **T0.7** 在 iPhone 12 Pro Max 上用 `base`、`tiny` 各錄 5 分鐘連續講話，記錄單次辨識耗時（中位數）、落後秒數的趨勢、記憶體用量。**順便確認即時模式輸出的是繁體中文**（離線模式已確認過，但即時模式用 `no_context` 而且沒有 prompt，需要另外確認）。依賴：T0.6。
  - 結果見「第 0 步：技術驗證」的結果；繁體中文靠 `initialPrompt` 解決。
- [x] **T0.8** 把結果和判定寫回「第 0 步：技術驗證」，更新開頭的「狀態」；移除 T0.5 的臨時畫面和 T0.6 的套件修改。依賴：T0.7。
  - 判定為「不通過」時，**暫停以下所有階段**，回頭修改規格。
  - 2026-10-08 完成：結果已寫回；fork 改為內建 `packages/whisper_ggml`（量測與調校參數保留為正式功能）。**例外**：測試畫面 `live_spike_screen.dart` 是目前唯一能在實機啟動錄音的地方，經使用者同意**保留到 T4.1 正式錄音畫面完成後再刪除**（連同首頁的 debug 入口）。

### 階段 1：原生層補強

依賴：T0.8 判定為通過或有條件通過。

- [x] **T1.1** 路由改變：監聽 `routeChangeNotification`，硬體格式改變時重建 converter 或重新安裝 tap，串流不中斷。
  - 程式已完成：實際監聽的是 `AVAudioEngineConfigurationChange`（硬體格式改變時 engine 會自行停止，必須重裝 tap 並重新啟動；只聽 route change 不夠）。converter 與暫存改成每個 tap 各自持有的 `TapPipeline`，避免與 audio thread 競爭。**實機待驗**。
- [x] **T1.2** 中斷：監聽 `interruptionNotification`，收到 `.began` 時停止 engine，送出 `INTERRUPTED` 錯誤事件後結束串流。
  - 程式已完成。**實機待驗**（來電或 Siri）。
- [x] **T1.3** 進入背景：監聽 `didEnterBackgroundNotification`，停止收音，送出 `BACKGROUNDED` 錯誤事件後結束串流。
  - 程式已完成。**實機待驗**。
- [x] **T1.4** 錯誤代碼補齊：`ALREADY_RUNNING`、`AUDIO_SESSION_ERROR`、`FORMAT_UNSUPPORTED`；確認 `stop` 是 idempotent。
  - 已完成（T0.3 起就有基本回傳；`ALREADY_RUNNING` 另在 Dart 端先擋）。
- [x] **T1.5** `MicStreamService` 把 `INTERRUPTED`／`BACKGROUNDED` 轉成 Dart 端可以區分的例外型別，供狀態機判斷。依賴：T1.2、T1.3。
  - 已完成：`MicStreamErrorCode.interrupted／backgrounded`，`LiveTranscriptionService` 轉成 `LiveEndReason`。

### 階段 2：資料模型與儲存

可以跟階段 1 同時進行。

- [x] **T2.1** `Recording` 新增 `source` 欄位（`import`／`live`），`fromJson` 缺少時預設為 `import`；`ImportScreen` 建立紀錄時明確填 `import`。
- [x] **T2.2** `Recording` 支援「未轉錄」：新增 `isTranscribed` getter；`segments` 和 `elapsedSeconds` 目前是 `final`，要改成可以更新（改成非 final，或新增 `copyWith`），讓轉錄完成後能更新同一筆紀錄。
- [x] **T2.3** 單元測試：舊格式 JSON（沒有 `source`）讀取正常、空 `segments` 的序列化往返、`isTranscribed` 判斷。依賴：T2.1、T2.2。範圍見待確認事項 #2（已決定）。

### 階段 3：Dart 服務層

- [x] **T3.1** `lib/services/wav_writer.dart`：開檔寫入暫定 header → 持續 append PCM → 關閉時補寫 RIFF 和 data 的長度欄位。不能把整段音訊放在記憶體裡。
- [x] **T3.2** WAV 寫入器的單元測試：header 欄位正確（16 kHz、mono、16-bit）、長度欄位正確、奇數 bytes 的處理。依賴：T3.1。
- [x] **T3.3** 抽出離線轉錄流程：把 `ImportScreen._run()` 裡「轉錄 → 存檔」的邏輯抽成可以對「已存在的 `Recording`」執行的函式，供匯入、即時錄音停止後、重新轉錄三處共用。轉錄成功就更新 `segments`、`elapsedSeconds`；沒有內容或失敗時紀錄維持未轉錄。依賴：T2.2。
  - ⚠️ 不要拿掉 `TranscriptionService._sanitizedAudioPath()` 的 workaround（`whisper_ggml` 的 ffmpeg 路徑沒加引號）。重構後匯入流程要用含空白的檔名回歸測試一次。
  - 實作：`lib/services/recording_transcriber.dart`（`RecordingTranscriber`、`NoSpeechDetectedException`）；`ImportScreen` 已改用（等於同時完成 T4.7 的程式部分）。**含空白檔名的實機回歸測試尚未做。**
- [x] **T3.4** `lib/services/live_transcription_service.dart`：串接 `MicStreamService` → 分流（broadcast 或手動）→ `transcribeLive` 和 `WavWriter`；明確傳 `lang: 'zh'`；即時預覽的模型依照 T0.8 的判定。依賴：T0.4、T3.1。
  - 程式已完成（`kLivePreviewConfig`：tiny、4 threads、3 秒、no fallback、64 token；`initialPrompt` 為繁體 prompt）；實機驗證過 WAV 長度正確。寫入失敗時停止錄音並以 `writeFailed` 結束（T3.7 的服務端部分）。實機驗證過（60.8 秒錄音的 WAV 大小與理論值完全一致）。
- [x] **T3.5** 錄音上限：滿 1 小時 55 分時通知 UI，滿 2 小時自動停止。依賴：T3.4。
  - 程式已完成：`LiveRecording.maxDuration`／`limitWarningBefore`，送出 `LiveNotice.nearLimit`，滿 2 小時以 `LiveEndReason.limitReached` 結束。
- [x] **T3.6** 「即時文字可能延遲」偵測：依 `session.metrics` 計算落後秒數（已送出音訊秒數 − `fed_sec`），超過 6 秒就發出提示狀態；`partials` 出錯時改發出「即時文字已停止」狀態，錄音與 WAV 寫入繼續。依賴：T3.4。
  - 程式已完成：落後超過 `lagHintSeconds`（6 秒）送出 `previewDelayed`，回到 6 秒內送出 `previewCaughtUp`；`partials` 出錯送出 `previewStopped`。
- [x] **T3.7** 寫入失敗處理：磁碟空間不足時停止錄音，盡量補寫 header 並存成未轉錄紀錄；補寫失敗就刪掉殘缺的檔案並回報錯誤。依賴：T3.1、T3.4。
  - 已完成：寫入失敗時服務停止錄音並以 `writeFailed` 結束，`WavWriter.close()` 依實際寫入的 bytes 補寫 header；`LiveRecordScreen` 照常存成未轉錄紀錄並顯示原因，實際音訊不到 1 秒則刪檔不保存。磁碟寫滿難以模擬，**沒有實測**。
  - `WavWriter.close()` 已經會在寫入失敗時，依實際寫入的 bytes 補寫 header 再丟出錯誤；剩下的是錄音流程端的處理（停止、存成未轉錄、補寫失敗時刪檔）。
- [x] **T3.8**（條件式）如果 T0.8 判定即時預覽用 `tiny`：在 `preparing` 階段同時確保 `tiny`（即時用）和 `base`（離線用）都已下載，並顯示下載進度。依賴：T0.8、T3.4。
  - 程式已完成：`LiveTranscriptionService.ensureModels(onProgress:)` 依序確保 `tiny`、`base`；內建 `whisper_ggml` 的 `downloadModel` 改成串流寫入 `.part` 檔、檢查 HTTP 狀態、回報進度（Mac 上實際下載 `tiny` 驗證過）。UI 端進度顯示在 T4.1。

### 階段 4：UI（暫定版，待正式設計）

- [x] **T4.1** `LiveRecordScreen` 和狀態機：`checkingPermission` → `requestingPermission`／`permissionDenied`（附前往系統設定按鈕）→ `preparing`（模型下載）→ `recording` → `finalizing` → `transcribing` → 導向 `MeetingDetailScreen`；`finalizing`／`transcribing` 時停用停止按鈕，防止連點。依賴：T1.5、T3.3、T3.4。
  - 程式已完成：`lib/screens/live_record_screen.dart`。停止後**先存成未轉錄紀錄再轉錄**；錄音不到 1 秒不保存；權限被拒時用新增的 `openSettings` 開系統設定。測試畫面與首頁 debug 入口已刪除。**實機待驗**。
- [x] **T4.2** 錄音中的畫面元素：已錄時間、即時預覽（自動捲到最底，標示為「預覽」）、延遲提示、上限提示。依賴：T4.1、T3.5、T3.6。
  - 程式已完成（時:分:秒、預覽標示、延遲／停止／上限提示）。
- [x] **T4.3** 錄音中按返回：用 `PopScope` 攔截，跳出「停止並存檔／繼續錄音」確認對話框。依賴：T4.1。
  - 程式已完成（`PopScope`；收尾存檔中不能離開）。
- [x] **T4.4** 中斷和進入背景：收到 `INTERRUPTED`／`BACKGROUNDED` 時進入 `finalizing` 並存檔；進入背景的情況，回到前景後如果還在這個畫面就接著轉錄。依賴：T4.1、T1.5。
  - 程式已完成：中斷／背景／寫入失敗／上限都走同一條收尾流程並顯示原因；背景時等 `AppLifecycleListener.onResume` 才轉錄。
- [x] **T4.5** `HomeScreen`：FAB 改成展開式（「匯入錄音檔」／「即時錄音」）；`_statusLabel` 新增「未轉錄」狀態。依賴：T2.2。
  - 已完成：`_ExpandableFab`（「即時錄音」／「匯入錄音檔」）；「未轉錄」標記與圖示。「即時錄音」在 T4.1 前先顯示「開發中」。
- [x] **T4.6** `MeetingDetailScreen`：未轉錄時顯示「尚未轉錄」和「重新轉錄」按鈕；`_analysisGate` 的分析按鈕和 AppBar 的重新分析在未轉錄時停用；播放照常可用。依賴：T2.2、T3.3。
  - 已完成：未轉錄時四個分頁都顯示「尚未轉錄」＋「重新轉錄」（含進度），分析按鈕與 AppBar 重新分析隱藏；播放照常。**實機待驗**（需要一筆未轉錄紀錄，T4.1 之後才自然產生）。
- [x] **T4.7** `ImportScreen` 改用 T3.3 抽出的共用流程，畫面行為不變。依賴：T3.3。
  - 已在 T3.3 一併完成。

### 階段 5：驗收

- [x] **T5.1** 在實機上執行「驗收情境」的 5 個情境，可以先用 `/qa-checklist` 做成可勾選的驗收頁。依賴：階段 1–4 全部完成。
  - 2026-10-08：使用者自行實測，回報無異常（未逐項記錄各情境的結果）。
- [x] **T5.2** 回歸測試：匯入既有錄音檔（含空白檔名）→ 轉錄 → 分析 → 播放，行為跟改動前一致；舊的歷史紀錄可以正常開啟。依賴：T4.7。
  - 2026-10-08：使用者實機確認通過（重新匯入「(咖啡)」mp3 與以前正常的舊檔案，結果正常）。
- [ ] **T5.3** 用 `/spec-check` 核對規格與實作，用 `/devlog` 整理開發紀錄。依賴：T5.1、T5.2。

### 任務摘要

- 共 34 項，全部屬於「可獨立進行」，沒有需要外部團隊配合的任務。
- 其中 T3.8 是條件式任務，只有在技術驗證判定即時預覽用 `tiny` 時才需要做。
- 關鍵路徑：階段 0 → T1.5 ＋ T3.3 ＋ T3.4 → T4.1 → 階段 5。階段 1 和階段 2 可以同時進行。

## 待確認事項

拆解任務時發現，兩項皆於 2026-10-08 確認採用建議做法：

1. **技術驗證的臨時程式碼怎麼處理？** T0.5 的測試畫面和 T0.6 的 fork 修改，要在同一個分支上做完再刪掉，還是另開 `spike/` 分支？建議：在同一個分支上做，測試畫面只在 `kDebugMode` 顯示入口；fork 用不進版控的 `pubspec_overrides.yaml` 指向，T0.8 時刪掉。
   - **決定**：採用建議，在同一個分支上做。
2. **自動化測試的範圍？** 專案目前只有 Flutter 預設的 `test/widget_test.dart`。建議：只替純 Dart 的部分（`Recording` 的 JSON、`WavWriter`）補單元測試（T2.3、T3.2），原生層和 UI 用實機驗收。
   - **決定**：採用建議。

## 驗收核對記錄

### 2026-10-08（`/spec-check`，commit `fc900d1`）

- **結論**：主體功能與規格一致（Platform Channel 契約、錯誤代碼、chunk 格式、資料模型、未轉錄流程、狀態機主線、上限與延遲提示都有對應程式碼）。有 6 項是**規格沒跟上實作**（技術驗證後的決定未回寫正文），1 項是**實作沒完全做到規格**（WAV header 補寫失敗時未刪檔）。
- **落差**：
  1. 路由改變：正文寫 `routeChangeNotification`，實作監聽 `AVAudioEngineConfigurationChange`。
  2. `LiveTranscriptionService`：正文寫 `transcribeLive(model: kWhisperModel…)`，實作用 `kLivePreviewConfig`（`tiny`＋調校參數＋繁體 prompt）。
  3. 「明確不做的事」寫不修改 `whisper_ggml`、不調整 `initialPrompt`，實際已內建並修改套件、即時預覽使用繁體 prompt。
  4. 狀態機的 `idle →(按開始)` 與 `requestingPermission`：實作從首頁「即時錄音」進入就直接開始，系統權限詢問發生在 `checkingPermission` 內，沒有獨立狀態。
  5. 磁碟空間不足：規格要求「補寫 header 也失敗時刪除殘缺檔案」，實作在補寫失敗時仍會保存（只有實際音訊不到 1 秒才刪檔）。
  6. 驗收情境 1–5：使用者回報自行實測沒問題，尚未逐項記錄結果。
- **規格未涵蓋**：Dart 端先擋重複 `start`、`openSettings`（API 表已補）、錄音不到 1 秒不保存、即時錄音的名稱格式、錄音時間顯示到小時、`metrics`／`lagSeconds`、模型下載改為串流＋進度、iOS 上 `getPermissionStatus` 不會回 `denied`。
- **處理決定（同日，使用者）**：落差 1–4 改規格（已更新正文）；落差 5 改實作（`WavWriter.headerFinalized` → `LiveRecordingResult.wavUsable`，不可用時刪檔不保存）；落差 6 記為「使用者自測，回報無異常」並勾選 T5.1；「規格未涵蓋」8 項全部補進正文，其中首頁「即時錄音」連點同時在實作上擋掉。
