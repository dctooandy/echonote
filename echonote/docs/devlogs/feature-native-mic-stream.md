# 原生麥克風串流＋即時逐字稿 開發紀錄

分支：`feature/native-mic-stream`
狀態：進行中（程式任務全部完成；T5.2 回歸測試待做）

這個分支在 App 內加入「一邊錄音、一邊顯示即時逐字稿」：自己寫 iOS 的 MethodChannel／EventChannel 收音（不用現成錄音套件），交給 `whisper_ggml` 做裝置端即時辨識，錄完再用 WAV 跑一次離線轉錄產生正式逐字稿。另一個目的是累積 Platform Channel 與修改 C++ 推論函式庫的經驗。規格：[`docs/specs/feature-native-mic-stream/`](../specs/feature-native-mic-stream/feature-native-mic-stream.md)。

## 目標

- 首頁「＋」展開「即時錄音」，錄音中顯示即時預覽（全程在裝置上，不呼叫雲端、不花 token）。
- 錄音同時寫 WAV；停止後先存成「未轉錄」紀錄，再跑離線 `base` 轉錄，完成後進詳細頁。
- 轉錄失敗或沒有內容時保留錄音，可從詳細頁「重新轉錄」。
- 處理插拔耳機、來電中斷、進入背景、2 小時上限、磁碟寫入失敗。
- 只做 iOS（Android 另開分支）。

## 踩到的坑

### 一、即時辨識的效能（技術驗證）

#### `base` 跟不上即時速度

**現象**：實機錄 25 秒，按停止後要等 17 秒才定稿；錄越久等越久。

**原因**：套件每累積 1.5 秒新音訊就重算一次，而 whisper 每次都把音訊補滿 30 秒再送進 encoder，單次耗時固定約 2–3 秒（encoder 占 70–90%）。重算比新音訊來得慢，佇列無上限累積。

**修法**：在 fork（後來內建成 `packages/whisper_ggml`）的 `stream_run_inference` 加上每次推論的量測（`total_ms`、`encode_ms`、`decode_ms_per_token`、`tokens`、`fed_sec`），用數據判定：`base` 不論 2 或 4 threads 都不通過；即時預覽改用 `tiny`，離線仍用 `base`。

#### `tiny` 錄到第 50 秒開始失控

**現象**：`tiny` × 4 threads 錄 5 分鐘，前 50 秒單次約 1 秒、落後約 1 秒；之後單次暴增到 5–20 秒，停止時積壓 216 秒，定稿等了 7 分鐘以上，手機「超燙」。

**原因**（從數據推論）：encoder 只從 0.8 → 1.3 秒（發熱降頻，次因），最後保留的 token 也不多，多出的 10 秒以上推測是 whisper 的 temperature fallback——結果不可靠時換溫度整段重解碼，最多重試 5 次，陷入重複輸出時每次還會生到 token 上限。

**修法**：套件新增 `stepSec`／`noFallback`／`maxTokens`，即時預覽設為每 3 秒重算、`temperature_inc = 0`、每段最多 64 token。重測 231 秒：單次中位數 898 ms、最大落後 2 秒、停止後 1.7 秒定稿、不燙。設定集中在 `kLivePreviewConfig`（`lib/services/live_transcription_service.dart`）。

#### 2 threads 不一定比 4 threads 好

**現象**：原本推測 iPhone 12 Pro Max 只有 2 顆效能核心，4 threads 會被節能核心拖慢。

**原因**：實測 4 threads 的 encoder 較快；但每個 token 的 decode 反而較慢（thread 同步成本，10.7 ms 對 5.9 ms）。encoder 占大宗，所以整體 4 threads 勝。

**修法**：維持 4 threads；套件開放 `threads` 參數以便之後調整。

#### 即時文字夾雜簡體字

**現象**：即時預覽大致正確但有不少簡體字（離線轉錄沒有這個問題）。

**原因**：串流模式每次重算都用 `no_context = true` 而且沒有 prompt，模型自由選字形。

**修法**：先讀 whisper.cpp 確認 `no_context` 只清掉前一段結果、`initial_prompt` 在之後才加入（即時模式也吃得到），再設 `initialPrompt: '以下是繁體中文的會議逐字稿。'`。1 分鐘實測全繁體、prompt 不會混進輸出，不需要另外做簡轉繁。

#### 某個 mp3 的逐字稿全部是「(咖啡)」

**現象**：匯入一個 22 分鐘的 mp3（師生討論論文），離線轉錄的每一段都是「(咖啡)」，時間戳每 30 秒一段；播放聲音正常。其他舊檔案重新匯入都正常。

**原因**：在 Mac 上用 App 同一份 whisper.cpp 原始碼與參數（`base`、`zh`、有時間戳）編譯測試程式重現：45 段全是「(咖啡)」。這是 whisper 的**非語音標註**（同類如「(音樂)」）——每個 30 秒視窗一開頭就輸出這個標註並跳到視窗結尾，整段人聲被略過。排除項：這個分支沒改離線轉錄的 C++；左右聲道相關 0.87、單聲道音量正常（不是相位抵消）；`no_context=true` 無效（不是前段結果帶偏）。為什麼偏偏這個檔案會這樣**原因未確認**（推測與錄音環境背景聲有關）。

**修法**：`TranscriptionService` 呼叫 `transcribe` 時加 `suppressNonSpeechTokens: true`。Mac 上同檔重跑得到 848 段真實內容（繁體、涵蓋全長）。副作用：離線逐字稿不再有「(音樂)」「(笑聲)」等標註。

### 二、Dart 端串流與 Platform Channel

#### 按開始後立刻結束，再按一次變成 `alreadyRunning`

**現象**：測試畫面按開始，短暫「準備中」就跳回「開始」；log 是 `live session started` 緊接 `session done, final chars=0`，音訊只送了 0–0.2 秒。第一次測試時再按一次還出現 `MicStreamException(alreadyRunning)`。

**原因**：兩個 bug 疊加。(1) 想「等 session 結束」而寫了 `session.stop().then(...)`，但 `WhisperLiveSession.stop()` 會**主動結束** session；(2) session 自己結束時沒有一併停麥克風，Dart 端的串流一直開著，下次 `start` 就被判定重複。

**修法**：改用 `partials` 串流的 `onDone` 判斷 session 結束；session 結束時停麥克風；`MicStreamService.stop()` 在原生端沒有送出 endOfStream 時自行關閉 Dart 端串流（commit `d0d6f8a`）。

#### 重複 `start` 會搶走正在錄的串流

**現象**（設計時發現）：第二次 `start` 若送到原生端，會被回 `ALREADY_RUNNING`，但在那之前 Dart 已經重新監聽 EventChannel。

**原因**：EventChannel 在原生端只有一個 sink，再次 `listen` 會把 sink 換成新的；失敗後取消這個 listen，原生端的 `onCancel` 還會把正在錄的麥克風關掉。

**修法**：`MicStreamService.start()` 在 Dart 端先擋（`_controller != null` → `alreadyRunning`），不碰 EventChannel。

#### `StreamController.close()` 卡住錯誤處理

**現象**（臨時測試時發現）：`start` 失敗路徑若 `await controller.close()` 會永遠不返回。

**原因**：從沒被監聽過的單一訂閱 controller，`close()` 的 future 要等 done 事件送達才完成，沒有 listener 就不會完成。

**修法**：改成 `unawaited(controller.close())`。

### 三、iOS 原生層

#### 新的 Swift 檔沒有被編譯

**現象**：新增 `ios/Runner/MicStreamChannel.swift` 後，Xcode 專案看不到它。

**原因**：這個專案的 `project.pbxproj` 用明確的檔案參照，不是 Xcode 16 的資料夾自動同步。

**修法**：手動在 `project.pbxproj` 加入 `PBXFileReference`、`PBXBuildFile`、群組與 Sources phase 四處。

#### Channel 註冊位置

**現象／原因**：`AppDelegate` 使用 `FlutterImplicitEngineDelegate`，沒有 `window.rootViewController` 可以取 messenger。

**修法**：在 `didInitializeImplicitFlutterEngine` 裡透過 `engineBridge.pluginRegistry.registrar(forPlugin:)` 取得 messenger 建立 channel，並由 `AppDelegate` 持有。

#### 插拔耳機後收不到音訊（設計時處理）

**現象**：規格原本寫監聽 `routeChangeNotification` 後重建 converter。

**原因**：硬體格式改變時 `AVAudioEngine` 會**自行停止**，只聽 route change 接不回來；另外在 main thread 換 converter 會跟 audio thread 的 tap callback 搶同一份狀態。

**修法**：監聽 `AVAudioEngineConfigurationChange`，收到後重裝 tap 並重新啟動 engine；converter 與暫存改成每個 tap 各自持有的 `TapPipeline`，由該 tap 的 closure 獨占。

### 四、套件與依賴

#### fork 放在 repo 外，commit 會讓別人編譯不過

**現象**：測試畫面用到 fork 才有的 API，而 fork 透過不進版控的 `pubspec_overrides.yaml` 指向 repo 外的路徑。

**原因**：commit 進去的程式依賴一個不在版控裡的東西。

**修法**：技術驗證期間刻意不 commit 那些檔案；判定後把套件內建到 `echonote/packages/whisper_ggml`（只放 iOS＋Dart），分成「原版」`2a472c2` → 「修改」`082105c` → 「改 path 依賴」`496e0d5` 三個 commit，C++ 修改在歷史裡一目了然。

#### 模型下載整個讀進記憶體，而且不檢查 HTTP 狀態

**現象**（讀程式碼發現）：原版 `downloadModel` 用 `consolidateHttpClientResponseBytes`，`base` 約 147 MB 全進記憶體；沒檢查狀態碼，下載失敗可能把錯誤頁存成模型檔；也沒有進度可以顯示。

**修法**：改成串流寫入 `.part` 檔、完成才改名、檢查 HTTP 200 與長度、回報 `onProgress`（commit `7e0c5cd`）。在 Mac 上用真實網路下載 `tiny` 驗證過。

### 五、工具與編輯環境

#### Python 改檔把 CRLF 換成 LF，整份檔案變成修改

**現象**：只改了幾行 C++，`git diff --stat` 顯示 1400 行變動。

**原因**：`whisper_ggml` 的原始檔是 CRLF；Python 以文字模式讀寫會把換行統一成 LF。

**修法**：讀寫時用 `newline=''` 保留原本的換行，改完確認 diff 只有實際修改的行。

#### `dart format -l 100` 重排了既有檔案

**現象**：只在 `recording.dart` 加幾行，diff 變成 150 行。

**原因**：既有檔案用的是舊版 formatter 的排版風格，新版 formatter 會整份重排。

**修法**：還原後重新套用修改；之後只對**新檔案**跑 `dart format -l 100`。

#### VS Code 對 fork 的新參數報「未定義」

**現象**：命令列 `flutter analyze` 沒問題，但編輯器顯示 `stepSec` 等參數未定義。

**原因**：fork 在 workspace 之外，Dart 分析服務沒偵測到外部檔案變動，還在用舊的套件定義。

**修法**：`Dart: Restart Analysis Server`（套件內建進 repo 後就不再發生）。

#### Widget 測試 `pumpAndSettle` 逾時

**現象**：測首頁 FAB 的臨時測試卡在 `pumpAndSettle timed out`。

**原因**：首頁用真的檔案 I/O 讀紀錄，在測試的假時鐘裡不會完成，載入圈圈一直轉。

**修法**：FAB 不依賴清單，改用 `pump()` 直接測。

---

## 測試方法

- **單元測試**（`flutter test`，共 11 項）：`test/models/recording_test.dart`（舊格式 JSON、`source` 預設、未轉錄往返、`isTranscribed`）、`test/services/wav_writer_test.dart`（header 欄位、寫入順序、奇數 bytes、空檔、`headerFinalized`）。原生層與 UI 依決定只做實機驗收。
- **效能量測**：技術驗證期間的測試畫面每次推論印一行 `[spike] run #n ... total= enc= dec/tok= tokens= window= fed= lag= rss=`，停止時印 `summary`。判讀 `lag` 只看停止前的趨勢（停止後已送出的音訊不再增加，`lag` 會假性下降）。
- **WAV 正確性**：實機 60.8 秒錄音的檔案大小 1,945,644 bytes，等於 44 + 60.8 × 32000；Mac 上用 `afinfo` 檢查奇數 chunk 交錯寫入的正弦波，讀出 `1 ch, 16000 Hz, Int16`、1.000 秒。
- **模型下載**：Mac 上以 `flutter test` 實際下載 `tiny`（77,691,713 bytes），確認進度總量、沒有殘留 `.part`、第二次呼叫直接回傳。
- **臨時測試**（跑完即刪）：mock channel 驗證 `MicStreamService` 生命週期與錯誤轉換；widget 測試驗證展開式 FAB、未轉錄詳細頁、權限被拒畫面。
- **實機驗收**：錄音中插拔耳機、來電／Siri、切到背景、按返回確認、正常錄音轉錄。使用者回報自行實測無異常（未逐項記錄）。

## 待辦／已知限制

- **T5.2 回歸測試**：匯入含空白檔名的錄音檔 → 轉錄 → 分析 → 播放，並確認舊紀錄可開啟（T3.3 改動匯入流程後最需要確認）。
- **「(咖啡)」修正的實機確認**：手機上重新匯入該 mp3 與一個舊的正常檔案，確認前者正常、後者沒有變差。
- **定稿字數偏少**：早期 25 秒錄音的即時定稿只有約 40 字，使用者表示實際講得更多；推測與 25 秒視窗定稿或靜音裁切有關，**原因未查**（只影響預覽）。
- **未解的落差**：未調校的 `tiny` 第一次測試停止後等約 15 秒，但之後量測 `tiny` × 4 的落後只有約 1 秒，兩者對不上；當時的 `finalizeWait` 紀錄沒有留下，原因未確認。
- **磁碟寫滿**的處理路徑沒有實際測過（難以模擬）。
- 驗收情境 2（錄 30 分鐘）未有正式紀錄；長時間發熱仍需觀察。
- 之後的優化方向：縮小 `audio_ctx`（encoder 補滿 30 秒是主要成本，技能樹第 2 項）。
- Android（`AudioRecord`、`VOICE_RECOGNITION`）另開分支；內建的 `whisper_ggml` 屆時要補 Android 原始碼。
- `master` 上的 `31a033a`（`functions/node_modules`、`lib` 移出版控）尚未 push。
- 既有的 `formatDuration` 不顯示小時，超過 1 小時的逐字稿時間戳會從 00:00 重新開始（本分支沒改，錄音畫面另寫了時:分:秒）。
