# 使用者脈絡：自訂詞庫＋個人筆記 規格

分支：`feature/user-context`（尚未建立）
狀態：已確認（2026-10-21，15 項待確認事項皆採建議答案，見文末「已確認的決定」）

這份文件記錄 P1「使用者脈絡」功能：讓使用者把「AI 不知道、但使用者自己知道」的資訊交給 EchoNote，在**轉錄**和**分析**兩個階段使用。包含兩個子功能：

- **自訂詞庫**：處理「聽錯字」，例如人名、公司名、產品術語。
- **個人筆記／★ 重點標記**：處理「抓錯重點」，讓摘要包含使用者認為重要的內容。

做這個功能的原因（來自 2026-10-21 與 Good Tape 的比較討論）：EchoNote 要贏，不是在轉錄準確度上正面競爭，而是成為「會議記憶」。在這兩個子功能裡，詞庫的投入最少，對繁中使用者的痛點最大；筆記則是最容易做出差異化的功能。

## 現況（寫規格時查過的程式碼）

- `whisper_ggml`（vendored）已經支援 `initialPrompt`，會傳給 whisper.cpp 的 `initial_prompt`。
  - 即時預覽寫死 `'以下是繁體中文的會議逐字稿。'`（`lib/services/live_transcription_service.dart`，`kLivePreviewConfig`）。即時模式用 `no_context` 解碼，所以 prompt 就是唯一的上文。
  - **離線轉錄**（`TranscriptionService.transcribe()`）**完全沒有傳 `initialPrompt`**。匯入流程、即時錄音停止後的正式轉錄、「重新轉錄」都走這條路（`RecordingTranscriber`），所以正式逐字稿目前沒有任何 prompt。
- Cloud Function `analyzeMeeting`（`functions/src/index.ts`）只接收 `segments`，以 `[index] 文字` 格式送給 Claude Haiku 4.5，回傳的位置用 `source_segment_index`，再由 `AnalysisService._resolveSegmentIndices()` 在本機換算成時間戳。
- 逐字稿頁（`MeetingDetailScreen._buildTranscriptTab()`）**目前不能編輯**，只能點擊跳轉播放、複製、匯出。`TranscriptSegment` 的欄位都是 `final`。
- 「重新轉錄」按鈕**只在尚未轉錄的錄音上出現**（`_buildUntranscribed()`）。已經轉錄的錄音沒有入口。
- 錄音資料：每筆 `Recording` 存成 `Documents/history/<id>.json`，由 `RecordingStore` 讀寫。舊資料缺少的欄位要有預設值（參考 `source` 欄位的做法）。
- 即時錄音的「目前錄到第幾秒」以 `LiveRecording.sentSeconds` 計算（依送出的音訊 bytes 換算），和 WAV 檔裡的位置一致。

## 目標與範圍

### A. 自訂詞庫（三層）

| 層 | 時機 | 做法 |
|---|---|---|
| ① 轉錄前 | whisper | 把詞庫組成一句話，接在原本固定的那句話後面，作為 `initialPrompt`。例如「以下是繁體中文的會議逐字稿，會提到：台積電、EchoNote、王小明。」**離線轉錄一律使用**；即時預覽也使用，但實作後要在 iPhone 12 Pro Max 重新量測延遲，明顯變慢就退回只用固定開頭 |
| ② 分析時 | Claude | 詞庫一起送給 `analyzeMeeting`。系統提示要求：逐字稿裡發音或字形相近的錯字，在所有輸出中一律寫成詞庫的正確寫法 |
| ③ 事後學習 | 使用者修改逐字稿 | 使用者修改一個片段後，偵測到替換的字串，就詢問「加入詞庫？並套用到這場其他 N 處？」。**一律等使用者確認後才寫入**，不自動加入 |

- 詞庫**全域只有一份**。資料模型預留 `projectId`（P1 一律為 `null`），P2 做「專案」時再依專案分詞庫。
- 詞庫管理頁：新增、刪除、編輯、釘選詞條。
- 已轉錄的錄音提供手動的「**用目前詞庫重新轉錄**」按鈕。詞庫更新後，**不自動**重跑舊錄音。

### B. 個人筆記／★ 重點標記

- 筆記有兩種：
  - `star`：只記錄時間點，沒有文字。
  - `text`：時間點加上一段文字。
- 入口：
  - **即時錄音中**：★ 按鈕一按就記錄；筆記按鈕開啟輸入框。時間戳取**按下筆記按鈕的那一刻**的錄音位置（`sentSeconds`），不是送出的時間，因為使用者通常是聽完才開始寫。
  - **回放時**（匯入的錄音和即時錄音都可以）：在播放列上加 ★ 和筆記，時間戳取當下的播放位置。
- 筆記可以編輯文字、刪除，但**不能修改時間戳**；時間記錯就刪掉重記。
- 筆記入口**只放在**即時錄音畫面和播放列；逐字稿頁的長按保留給編輯片段。
- 匯出逐字稿（`.txt`）**不包含**筆記，維持現狀。
- 送進分析：每筆筆記在**分析當下**依時間戳換算成 `segment_index`，以「使用者重點」的形式送給 Claude，要求摘要必須涵蓋。
- 呈現：
  - 摘要頁最上方加「**你的重點**」區塊，顯示使用者的原文，**AI 不改寫**。
  - 每筆筆記底下可以附上 AI 產生的「這個時間點在討論什麼」補充說明，視覺上要和使用者的原文明確區隔。★ 沒有文字，所以特別需要這段補充。
  - 逐字稿頁在對應的片段旁邊顯示筆記標記，點一下跳轉播放。
- 「重新分析」**不會覆蓋**筆記本身，只會重新產生 AI 補充說明。

### 驗收方式（決定這個功能值不值得繼續的數字）

- **詞庫**：取一場真實錄音，列出裡面 10 個專有名詞，比較有詞庫和沒詞庫時的**正確命中率**；同時檢查有沒有出現**幻覺**，也就是錄音沒講、逐字稿卻出現詞庫詞，或 prompt 被整句重複。
- **筆記**：在一場會議標 5 個 ★／筆記，檢查摘要和待辦**涵蓋了幾個**；再由使用者主觀判斷，有標記的摘要是否更接近自己會寫的版本。

**明確不做的事**：

- 專案、依專案分詞庫（P2）。
- 跨會議問答、搜尋（P1 之後另立規格）。
- 用詞庫的別名（錯字對應）**自動替換**新錄音或其他錄音的逐字稿。P1 的替換只限使用者確認的「這一場」。
- 詞庫雲端同步、匯入或匯出、多裝置共用。
- 說話者標記。
- Android 專屬的 UI 調整（Android 分析功能目前本來就不支援）。
- 依詞庫重跑**所有**舊錄音的批次功能。

## API 異動

### Cloud Function `analyzeMeeting`（callable）

- 異動內容：新增兩個**選填**的 request 欄位、一個 response 欄位。舊版 App 不帶新欄位時，行為維持不變（向下相容）。
- Request（新增）：
  - `glossary?: string[]`：詞庫詞條的正確寫法，最多 200 條、每條最多 20 字。App 會**全部送出**，不依 whisper prompt 的字數上限截斷，讓第 ② 層補救 whisper 放不下的詞。
  - `highlights?: { note_index: number; segment_index: number; text: string | null }[]`
    - `note_index`：這筆筆記在本次請求中的序號，從 0 開始，讓 Claude 回傳時引用。
    - `segment_index`：由 App 換算的逐字稿片段序號。
    - `text`：`star` 為 `null`。
- 系統提示新增規則：
  - 詞庫詞是正確寫法，遇到發音或字形相近的錯字，在所有輸出中改用詞庫寫法；但不可把逐字稿沒提到的詞庫詞寫進輸出。
  - `highlights` 是使用者親自標記的重點，`summary.key_points` 必須涵蓋每一筆。
  - 逐字稿以 `<transcript>`、詞庫以 `<glossary>`、重點以 `<user_highlights>` 分段放進 user message，避免互相混淆。
- Response（新增）：
  - `highlight_contexts: { note_index: number; context: string }[]`：每筆重點「在討論什麼」的一兩句補充，繁體中文，**每筆 50 字以內**（寫在 schema 的 description 和系統提示裡）。沒有 `highlights` 時回傳空陣列。
  - `max_tokens` 維持 4096；長會議加上多筆筆記的情況要實測，被截斷再調整。
- 錯誤情境（新增，都回 `invalid-argument`）：
  - `glossary` 不是字串陣列，或超過上限。
  - `highlights[].segment_index` 超出 `segments` 的範圍。
  - `highlights[].note_index` 重複。
- App 端：`AnalysisService.analyze()` 的參數改成也接收詞庫和筆記；`note_index` 換回筆記 `id` 的工作在本機完成，和 `_resolveSegmentIndices()` 同樣的原則。

## 資料表異動

本機 JSON，沒有資料庫。

### 新檔案：`Documents/glossary.json`

```json
{
  "version": 1,
  "terms": [
    {
      "id": "1729500000000",
      "term": "台積電",
      "aliases": ["太基電"],
      "pinned": false,
      "source": "manual | learned",
      "project_id": null,
      "created_at": "ISO8601",
      "last_used_at": "ISO8601 | null"
    }
  ]
}
```

- `aliases`：第 ③ 層學到的錯誤寫法。P1 只記錄、不用來自動替換，保留給之後的功能。
- `last_used_at`：使用者修改逐字稿時命中、或新增或編輯詞條時更新，用來排序（見下方）。
- 檔案不存在就當作空詞庫。讀取失敗（JSON 損毀）時，見邊界案例。

### 組成 whisper prompt 的規則

1. 固定開頭：`以下是繁體中文的會議逐字稿`（保留，因為這句話負責壓住簡體輸出）。
2. 有詞條時接上 `，會提到：` 加上詞條，以 `、` 分隔，最後以 `。` 結尾。
3. 排序：`pinned` 優先，其次 `last_used_at` 由新到舊，再其次 `created_at` 由新到舊。
4. 依序加入詞條，直到**詞條部分**（含 `、`，不含固定開頭和 `，會提到：`）的長度超過 `kGlossaryPromptMaxChars` 就停止；遇到放不下的詞就停，不跳過它去塞後面較短的詞，以免低優先的詞擠掉高優先的詞。初始值暫定 **80 個中文字**，第 ① 層完成後用真實錄音實測，再修正這個值。
5. 離線轉錄一律開啟 whisper.cpp 的 `carry_initial_prompt`：預設情況下 prompt 只會影響第一個 30 秒視窗，之後就被已解碼的前文擠出上下文，長會議的後段等於沒有詞庫。原本的 `whisper_ggml` 綁定沒有接出這個參數，T3 一併補上（`TranscribeRequest.carryInitialPrompt`）。

### `Recording`（`Documents/history/<id>.json`）新增欄位

| 欄位 | 型別 | 預設值（舊資料） | 說明 |
|---|---|---|---|
| `notes` | `List<UserNote>` | `[]` | 個人筆記 |
| `transcript_stale_analysis` | `bool` | `false` | 已有分析結果時，「重新轉錄」或第 ③ 層「套用到本場其他 N 處」後設為 `true`，用來顯示「分析可能過時」；重新分析後清回 `false`。單一片段的修改**不**設為 `true` |
| `dismissed_replacements` | `List<String>` | `[]` | 第 ③ 層被使用者選「不用」的替換，格式 `舊字串→新字串`；同一場錄音不再詢問同一組替換 |

`UserNote`：

| 欄位 | 型別 | 說明 |
|---|---|---|
| `id` | `String` | 毫秒時間戳字串，和 `Recording.id` 的做法一致 |
| `timestamp_ms` | `int` | 相對於錄音開頭的位置 |
| `kind` | `star` / `text` | |
| `text` | `String?` | `star` 為 `null` |
| `created_at` | `String` | ISO8601 |

### `TranscriptSegment` 異動

- `text` 改為可修改（拿掉 `final`）。
- 新增 `edited: bool`，預設 `false`，用來在重新轉錄前提醒使用者「會蓋掉你改過的地方」。

### `MeetingAnalysis` 新增欄位

- `highlight_contexts: Map<noteId, String>`：本機已經把 `note_index` 換回筆記 `id`。重新分析時整份覆蓋。

### 筆記換算成 `segment_index` 的規則（在分析當下計算，不儲存）

- 取 `startMs <= timestamp_ms` 的最後一個片段。
- 時間戳比第一個片段還早，就取 0。
- 不儲存換算結果，因為重新轉錄後片段會整份換掉；筆記只保存時間戳。

## 權限與狀態機

沒有角色區分。

錄音的狀態轉移（新增的部分以粗體標示）：

```
未轉錄 ──轉錄──▶ 已轉錄 ──分析──▶ 已分析
                 ▲  │                 │
                 │  └─重新轉錄─┐      │ **重新轉錄 / 編輯逐字稿**
                 │             ▼      ▼
                 └──────── 已轉錄   **已分析（可能過時）** ──重新分析──▶ 已分析
```

- 已分析的錄音重新轉錄後，**保留原本的分析結果**（待辦的勾選和修改是使用者的資料），並標記為「可能過時」。
- 編輯逐字稿只有在第 ③ 層「套用到本場其他 N 處」時才標記「可能過時」；單一片段的修改不標記。
- 筆記在任何狀態都可以新增，包括未轉錄。

## UI／畫面

**暫定，待正式設計。** 目前全 App 使用 Flutter 預設的 Material 主題，還沒有視覺設計。以下只確定「功能入口在哪裡」，版面、圖示、文案都是暫定。

| 畫面 | 異動 |
|---|---|
| `HomeScreen` | AppBar 新增「詞庫」入口 |
| 新增 `GlossaryScreen` | 詞條列表（釘選的在最上面）、新增、編輯、刪除、釘選；顯示「目前前 N 個詞會送進轉錄」的提示，讓使用者知道有上限 |
| `LiveRecordScreen` | 錄音中新增 ★ 按鈕和筆記按鈕；筆記輸入框不能擋住「停止」按鈕；按下後短暫顯示「已標記 12:34」 |
| `MeetingDetailScreen` 播放列 | 新增 ★ 和筆記按鈕，時間取目前的播放位置 |
| `MeetingDetailScreen` 摘要頁 | 最上方新增「你的重點」區塊：使用者原文，下面附上 AI 補充說明（區隔樣式）。**還沒分析時也要顯示**，放在「尚未分析」提示的上方；分析可能過時時顯示提示列和「重新分析」 |
| `MeetingDetailScreen` 逐字稿頁 | **長按片段**跳出編輯對話框（點擊維持跳轉播放）；有筆記的片段顯示標記；編輯後觸發第 ③ 層詢問 |
| `MeetingDetailScreen` AppBar | 已轉錄的錄音新增「用目前詞庫重新轉錄」（放在選單裡）；按下後先跳確認對話框 |

### 第 ③ 層詢問的觸發規則

1. 使用者儲存片段修改後，以**字元層級 diff** 比對修改前後的文字。
2. **只有剛好一段連續替換**、而且新舊字串長度都在 1～10 字之間，才詢問。其他情況（多段修改、純刪除、純新增）不詢問。
3. 對話框內容：「把『太基電』記成『台積電』？」，選項：
   - **加入詞庫並套用到本場其他 N 處**（N = 0 時不顯示這個選項）
   - **只加入詞庫**
   - **不用**
4. 「套用」是在本場其他片段做字面替換，被改到的片段標記 `edited = true`。
5. 如果詞庫已經有同樣的 `term`，就把舊字串加進它的 `aliases`，不建立重複詞條。
6. 選「不用」時，把這組替換記進 `dismissed_replacements`，同一場錄音不再詢問；其他錄音照常詢問。

## 邊界案例與例外處理

- **詞庫是空的**：prompt 只用固定開頭；`analyzeMeeting` 不帶 `glossary`。
- **詞條重複**：新增時正確寫法相同（去掉前後空白後比對）就擋下，提示「已存在」。
- **詞條或詞庫超過上限**（單條 20 字、整份 200 條）：新增時擋下並提示。
- **詞條含有 `、`、`，`、`。` 或換行**：儲存前擋下或去除，以免破壞 prompt 格式。
- **`glossary.json` 損毀**：視為空詞庫並繼續轉錄，**不覆寫**損毀的檔案（避免使用者資料永久遺失），在詞庫頁顯示錯誤。
- **詞庫太大**：超過 `kGlossaryPromptMaxChars` 的詞不會進入 whisper prompt，但仍然全部送給 Claude。
- **重新轉錄失敗**：沿用 `RecordingTranscriber` 現有的保證，失敗時原本的逐字稿、修改、筆記都不動。
- **重新轉錄後**：片段整份換掉，使用者修改過的片段（`edited`）會遺失，因此確認對話框要依有沒有 `edited` 片段顯示不同警告；筆記保留，因為它們只依賴時間戳。
- **筆記時間戳超過錄音長度**：例如即時錄音被截斷（`writeFailed` 等）。換算時取最後一個片段；顯示時夾在錄音長度內。
- **即時錄音中按下筆記，還沒送出就按停止**：草稿有文字就存成 `text` 筆記，沒有文字就丟棄。
- **即時錄音太短被刪除**（`audioDuration < 1s`）：筆記一起丟棄。
- **即時錄音的筆記在錄音結束前只存在記憶體**：App 當掉時會遺失，P1 接受這個風險，和即時預覽的處理一致（WAV 已寫入的部分仍會保留）。
- **錄音沒有轉錄**：筆記可以新增和顯示，但不能分析（沿用現有限制）。
- **★ 連續快速點擊**：同一秒內的重複 ★ 合併成一筆。
- **分析回傳的 `highlight_contexts` 缺少某筆，或 `note_index` 不存在**：缺的就不顯示補充說明，不當成錯誤。
- **分析後刪除筆記**：連同它的 AI 補充說明一起移除；不需要重新分析。
- **分析後新增筆記**：新筆記沒有補充說明，摘要頁提示「有新的重點尚未分析」。
- **Android**：分析本來就不能用，詞庫第 ① 層和筆記仍然可以用。

---

## 任務拆解

2026-10-21 初版。這是個人專案，**全部任務都屬於「可獨立進行」**，沒有需要外部團隊配合的項目。標 📱 的任務需要用實機（iPhone 12 Pro Max）和真實錄音驗證，只能由你本人執行。專案沒有 `CLAUDE.md`，不需要對照「已知重大問題」清單。

### 階段 0：詞庫基礎＋第 ① 層（先做，後面的設計都依賴實測出來的字數上限）

- [x] **T1 詞庫資料層**：新增 `GlossaryTerm` model 和 `GlossaryStore`，讀寫 `Documents/glossary.json`。包含：檔案不存在時當作空詞庫；JSON 損毀時當作空詞庫且**不覆寫**；重複詞條（去掉前後空白後比對）擋下；單條 20 字、整份 200 條的上限；拒絕含 `、`、`，`、`。` 或換行的詞條。附單元測試（`test/services/glossary_store_test.dart`）。
- [x] **T2 whisper prompt 組字**：純函式 `buildWhisperPrompt(terms, maxChars)`，包含固定開頭、`，會提到：`、`、` 分隔、排序（釘選 → `last_used_at` → `created_at`）、超過 `kGlossaryPromptMaxChars`（暫定 80）就停止。附單元測試，涵蓋空詞庫、剛好到上限、超過上限、排序。依賴：T1
- [x] **T3 離線轉錄接上 prompt**：`TranscriptionService.transcribe()` 新增 `initialPrompt` 參數並傳給 `WhisperController.transcribe()`；`RecordingTranscriber` 轉錄前讀取詞庫、組出 prompt。匯入、錄音停止後的正式轉錄、重新轉錄三條路徑都要生效。依賴：T2
  - 2026-10-21 完成。追加：在 vendored `whisper_ggml` 接出 `carry_initial_prompt`（C++ 綁定、`TranscribeRequest`、DTO、`WhisperController.transcribe()`），預設開啟。
- [ ] **T4 📱 實測詞庫效果和字數上限**：取一場真實錄音，列出 10 個專有名詞，比較沒有詞庫、詞庫 80 字、詞庫加長三種情況的**正確命中率**、**幻覺**（錄音沒講卻出現詞庫詞、prompt 被重複）和**轉錄時間**。另外比較 `carry_initial_prompt` 開和關，看**錄音後段**的命中率差異。依結果決定 `kGlossaryPromptMaxChars` 和是否維持開啟，把數字和結論寫回本規格「組成 whisper prompt 的規則」。依賴：T3
  - 詞庫輸入：`flutter run --release --dart-define=GLOSSARY_SEED=詞1、詞2、詞3`（啟動時寫入，重複的會略過）。
  - 關掉 carry：再加 `--dart-define=WHISPER_CARRY_PROMPT=false`。
  - 實際送出的 prompt 會印在 log：`[Transcriber] initial prompt: …`。

### 階段 1：詞庫管理＋即時預覽

- [ ] **T5 詞庫管理頁**：完成後移除 `main.dart` 的 `GLOSSARY_SEED`。新增 `GlossaryScreen`（列表、新增、編輯、刪除、釘選、顯示「前 N 個詞會送進轉錄」），在 `HomeScreen` 的 AppBar 加入口。UI 暫定。依賴：T1、T2
- [ ] **T6 📱 即時預覽帶詞庫＋重新量測延遲**：`kLivePreviewConfig.initialPrompt` 改成執行時由詞庫組出（`LivePreviewConfig` 目前是 `const`，要調整成可以在執行時帶入）。在實機上用和 2026-10-10 相同的方式量測 median run 和 max lag；明顯變慢就退回固定開頭，並把結果寫回規格。依賴：T2

### 階段 2：Cloud Function（第 ② 層＋筆記所需的 API）

- [x] **T7 `analyzeMeeting` 擴充**（`functions/src/index.ts`）：
  - request 新增選填的 `glossary`、`highlights`；
  - 驗證三種 `invalid-argument` 情境（`glossary` 格式或超過上限、`segment_index` 超出範圍、`note_index` 重複）；
  - user message 改成 `<transcript>`、`<glossary>`、`<user_highlights>` 三段；
  - 系統提示新增詞庫規則和重點涵蓋規則；
  - output schema 新增 `highlight_contexts`（每筆 50 字以內）。

  確認不帶新欄位時行為和現在一樣，部署後用 emulator 或實際呼叫驗證（測試方式見待確認事項 2）。
  - 2026-10-21 程式完成、**尚未部署**。邏輯抽到 `functions/src/analyze.ts`（純函式），`index.ts` 只留接線。
  - 已驗證：直接呼叫純函式跑 12 個情境；emulator 上三種錯誤都回 `INVALID_ARGUMENT`，舊版請求通過驗證。
  - 2026-10-21 已部署，並用 6 句假逐字稿加詞庫（台積電、EchoNote、王小明）和 2 筆筆記實際呼叫：
    - 「太基電」在所有輸出中都改成「台積電」；「小明」補成「王小明」。
    - 「依可諾」**沒有**改成「EchoNote」：中文音譯對應到英文詞的情況，第 ② 層救不回來，要靠第 ① 層 whisper 直接轉對，T4 實測時要特別看這種詞。
    - `highlight_contexts` 兩筆都有回傳，都在 50 字以內，★ 那筆也有正確描述該處內容。
    - **發現問題**：使用者筆記「要跟老闆確認底線」被寫進 `key_points` 和 `highlight_contexts`，而且說成「會議決議」。會議裡沒有人這樣說，這是使用者自己的想法。見待確認事項。
    - 舊版請求（只帶 `segments`）正常回傳，`highlight_contexts` 為空陣列。
- [x] **T8 App 端送出詞庫**：`AnalysisService.analyze()` 新增詞庫參數，`MeetingDetailScreen._runAnalysis()` 讀取詞庫後**全部**送出（最多 200 條，不截斷）。依賴：T1、T7

### 階段 3：資料模型（筆記、編輯、過時標記）

- [x] **T9 `Recording` 相關 model 擴充**（`lib/models/recording.dart`）：
  - `Recording` 新增 `notes`、`transcript_stale_analysis`、`dismissed_replacements`；
  - 新增 `UserNote`；
  - `TranscriptSegment.text` 改成可修改，並新增 `edited`；
  - `MeetingAnalysis` 新增 `highlight_contexts`。

  舊 JSON 缺欄位時要讀得出預設值。在 `test/models/recording_test.dart` 補上新舊格式的往返測試。
- [x] **T10 筆記送進分析**：純函式把筆記時間戳換算成 `segment_index`（取 `startMs <= t` 的最後一個片段，早於第一個片段取 0），在分析當下計算、不儲存；`AnalysisService` 送出 `highlights`，並把回傳的 `note_index` 換回筆記 `id`，存進 `highlight_contexts`（缺少或不存在的序號直接略過）。重新分析時清掉 `transcript_stale_analysis`。附換算函式的單元測試。依賴：T7、T9
  - 2026-10-21 完成（T8 一併完成）：`segmentIndexFor`、`buildHighlights`、`resolveHighlightContexts` 都是純函式並附測試。和 T7 一樣，要等部署後用真實呼叫確認端到端。

### 階段 4：筆記 UI

- [ ] **T11 📱 即時錄音的 ★／筆記**（`LiveRecordScreen`）：時間戳取 `sentSeconds`（按下按鈕當下）；同一秒內重複的 ★ 合併；輸入框不能擋住「停止」；停止時草稿有文字就存、沒文字就丟；錄音太短被刪除時筆記一起丟棄；在 `_onRecordingDone` 建立 `Recording` 時寫入 `notes`。依賴：T9
- [x] **T12 播放列的 ★／筆記**（`MeetingDetailScreen`）：時間取目前播放位置；支援編輯文字和刪除（不能改時間）；刪除時連同 AI 補充說明一起移除。依賴：T9
  - 2026-10-21 完成。另外做了：同一秒內重複的 ★ 合併（原本只寫在 T11）、刪除後可從 SnackBar 復原（連同 AI 補充說明）。筆記清單先放在摘要頁上方、未分析也顯示；T13 再補 AI 補充說明、逐字稿標記和「有新的重點尚未分析」。
- [x] **T13 「你的重點」區塊＋逐字稿標記**：摘要頁最上方顯示使用者原文和 AI 補充說明（區隔樣式），**還沒分析時也要顯示**；分析後新增的筆記提示「有新的重點尚未分析」；逐字稿頁在對應片段顯示筆記標記，點一下跳轉播放。依賴：T10、T12
  - 2026-10-21 完成。「有新的重點尚未分析」改成判斷「筆記沒有 AI 補充說明」，提示文字為「有 N 筆重點還沒有 AI 補充說明，重新分析可補上」，這樣 Claude 漏掉某筆時也會提示。逐字稿標記和分析用同一個 `segmentIndexFor`，標記會落在 AI 看到的同一行。

### 階段 5：重新轉錄、逐字稿編輯、第 ③ 層

- [ ] **T14 用目前詞庫重新轉錄**：已轉錄的錄音在 AppBar 選單新增入口；確認對話框依有沒有 `edited` 片段顯示不同警告；已有分析就設 `transcript_stale_analysis = true`，摘要頁顯示「分析可能過時」提示列和「重新分析」；轉錄失敗時原資料不動（沿用 `RecordingTranscriber` 的保證）。依賴：T3、T9
- [ ] **T15 逐字稿片段編輯**：長按片段跳出編輯對話框（點擊維持跳轉播放），儲存後標記 `edited = true` 並存檔。依賴：T9
- [ ] **T16 第 ③ 層學詞**：
  - 純函式做字元層級 diff，只在「剛好一段連續替換、新舊字串都在 1～10 字」時回傳替換組；附單元測試。
  - 對話框提供三個選項：加入詞庫並套用到本場其他 N 處（N = 0 時不顯示）、只加入詞庫、不用。
  - 「套用」是在本場其他片段做字面替換，被改到的片段標 `edited`，已有分析就設 `transcript_stale_analysis`。
  - 詞庫已有相同 `term` 時，把舊字串加進 `aliases`，不建立重複詞條。
  - 選「不用」時記進 `dismissed_replacements`，同一場不再詢問。
  - 有命中時更新 `last_used_at`。

  依賴：T1、T15

### 階段 6：驗收與收尾

- [ ] **T17 📱 筆記驗收**：在一場會議標 5 個 ★／筆記，檢查摘要和待辦涵蓋了幾個，並做主觀比較；同時用長會議（44 分鐘那場）加上多筆筆記，確認 `max_tokens: 4096` 不會被截斷，把結果寫回規格。依賴：T13
- [ ] **T18 核對與紀錄**：用 `/spec-check` 核對規格和實作，用 `/devlog` 整理開發紀錄，規格狀態改成「已完成」。依賴：全部

## 待確認事項

無。

## 已確認的決定（2026-10-21）

15 項待確認事項（加上任務拆解時的 2 項）全部採用建議答案，內容已寫回上面各章節。

| # | 問題 | 決定 |
|---|---|---|
| 1 | `kGlossaryPromptMaxChars` 初始值 | 暫定 80 個中文字，第 ① 層完成後實測修正 |
| 2 | 即時預覽要不要帶詞庫 | 要帶；重新量測延遲，明顯變慢就退回固定開頭 |
| 3 | 送給 Claude 的詞庫要不要截斷 | 全部送，上限 200 條 |
| 4 | 逐字稿片段的編輯方式 | 長按片段跳出對話框 |
| 5 | 重新轉錄後，分析結果怎麼處理 | 保留，標為可能過時 |
| 6 | 編輯逐字稿要不要把分析標為過時 | 只有「套用到本場其他 N 處」時才標記 |
| 7 | 筆記能不能修改時間戳 | 不能，刪掉重記 |
| 8 | 停止錄音時未送出的筆記草稿 | 有文字就存，沒文字就丟 |
| 9 | 即時錄音中的筆記要不要邊記邊存 | P1 不做 |
| 10 | 逐字稿頁要不要有筆記入口 | 不要，長按保留給編輯 |
| 11 | 還沒分析時要不要顯示「你的重點」 | 要，放在「尚未分析」提示的上方 |
| 12 | 拒絕過的替換要不要再問 | 同一場錄音不再問，其他錄音照常詢問 |
| 13 | 詞條和詞庫上限 | 單條 20 字，整份 200 條 |
| 14 | 匯出逐字稿要不要包含筆記 | P1 不包含 |
| 15 | `max_tokens: 4096` 夠不夠 | 不改；`highlight_contexts` 每筆 50 字以內，實測後再決定 |
| 16 | T4 實測時詞庫怎麼輸入 | 用 debug 專用的 `--dart-define=GLOSSARY_SEED`，T5 完成後移除 |
| 17 | Cloud Function 怎麼測試 | P1 不引進測試框架；驗證和組 user message 抽成純函式，部署前用 Firebase emulator 手動驗證三種錯誤情境和向下相容 |
| 18 | 使用者筆記被當成會議內容（T7 實測發現） | 系統提示加上「筆記只標示重要位置，不可寫成會議發言或決議」（`270540c`，已部署）。重測後不再寫成「會議決議」，但筆記的意思仍以「需要與內部確認降價底線」的形式出現。殘留問題留到 T17 用真實會議判斷是否還要處理 |
