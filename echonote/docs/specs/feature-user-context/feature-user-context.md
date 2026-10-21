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

（2026-10-21 修訂，見已確認的決定 19、20）

1. 使用者儲存片段修改後，以**字元層級 diff**（code point 的最長共同子序列）比對修改前後的文字。
2. **只有剛好一段連續替換**、而且新舊字串長度都在 **2～10 字**之間，才詢問。其他情況（多段修改、純刪除、純新增、單字修改）不詢問。單字的修改（他／她、的／得）大多是一般錯字，不是專有名詞。
3. diff 抓到的是**最小的變動範圍**，可能只是詞的一部分：「太基電」改成「台積電」，抓到的是「太基」→「台積」（「電」兩邊都有）。所以對話框的「正確寫法」是**可編輯的欄位**，預設填 diff 抓到的字串，讓使用者補成完整的詞。
4. 錯誤寫法跟著推算：使用者在正確寫法前後補了什麼，錯誤寫法也補上同樣的字。例如把「台積」補成「台積電」，錯誤寫法就從「太基」變成「太基電」。正確寫法裡找不到 diff 抓到的字串時，錯誤寫法維持原樣。
5. 對話框即時顯示「會把『太基電』記成『台積電』」，以及本場其他片段裡還有幾處錯誤寫法（N）。選項：
   - **不用**
   - **只加入詞庫**
   - **加入並修正 N 處**（N = 0 時不顯示）
6. 「修正」是在本場其他片段，把**推算後的完整錯誤寫法**字面替換成正確寫法，被改到的片段標 `edited`，已有分析就設 `transcript_stale_analysis`。
7. 詞庫已有相同 `term` 時，把錯誤寫法加進它的 `aliases`（不重複），不建立新詞條；新詞條的 `source` 為 `learned`。兩種情況都更新 `last_used_at`。
8. 選「不用」時，把 diff 抓到的那組替換（`舊→新`）記進 `dismissed_replacements`，同一場錄音不再詢問；其他錄音照常詢問。點對話框外面關閉不算「不用」，下次還會問。

## 邊界案例與例外處理

- **詞庫是空的**：prompt 只用固定開頭；`analyzeMeeting` 不帶 `glossary`。
- **詞條重複**：新增時正確寫法相同（去掉前後空白後比對）就擋下，提示「已存在」。
- **詞條或詞庫超過上限**（單條 20 字、整份 200 條）：新增時擋下並提示。
- **詞條含有換行**：儲存前擋下，因為送給 Claude 的詞庫是一行一個詞。標點符號（`、`、`，`、`,`、`。` 等）可以使用，例如公司全名 `Apple, Inc.`（決定 25）。
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

- [x] **T1 詞庫資料層**：新增 `GlossaryTerm` model 和 `GlossaryStore`，讀寫 `Documents/glossary.json`。包含：檔案不存在時當作空詞庫；JSON 損毀時當作空詞庫且**不覆寫**；重複詞條（去掉前後空白後比對）擋下；單條 20 字、整份 200 條的上限；拒絕含換行的詞條（原本也擋 `、`、`，`、`。`，依決定 25 放寬）。附單元測試（`test/services/glossary_store_test.dart`）。
- [x] **T2 whisper prompt 組字**：純函式 `buildWhisperPrompt(terms, maxChars)`，包含固定開頭、`，會提到：`、`、` 分隔、排序（釘選 → `last_used_at` → `created_at`）、超過 `kGlossaryPromptMaxChars`（暫定 80）就停止。附單元測試，涵蓋空詞庫、剛好到上限、超過上限、排序。依賴：T1
- [x] **T3 離線轉錄接上 prompt**：`TranscriptionService.transcribe()` 新增 `initialPrompt` 參數並傳給 `WhisperController.transcribe()`；`RecordingTranscriber` 轉錄前讀取詞庫、組出 prompt。匯入、錄音停止後的正式轉錄、重新轉錄三條路徑都要生效。依賴：T2
  - 2026-10-21 完成。追加：在 vendored `whisper_ggml` 接出 `carry_initial_prompt`（C++ 綁定、`TranscribeRequest`、DTO、`WhisperController.transcribe()`），預設開啟。
- [x] **T4 📱 實測詞庫效果和字數上限**：取一場真實錄音，列出 10 個專有名詞，比較沒有詞庫、詞庫 80 字、詞庫加長三種情況的**正確命中率**、**幻覺**（錄音沒講卻出現詞庫詞、prompt 被重複）和**轉錄時間**。另外比較 `carry_initial_prompt` 開和關，看**錄音後段**的命中率差異。依結果決定 `kGlossaryPromptMaxChars` 和是否維持開啟，把數字和結論寫回本規格「組成 whisper prompt 的規則」。依賴：T3
  - 詞庫輸入：在 App 的詞庫頁新增（T5 完成後，`GLOSSARY_SEED` 已移除）。
  - 關掉 carry：再加 `--dart-define=WHISPER_CARRY_PROMPT=false`。
  - 實際送出的 prompt 會印在 log：`[Transcriber] prompt mode=… carry=… initial prompt: …`。
  - **2026-10-21 第一次實測（使用者）**：錄音「手機應用開發技術介紹」，詞庫 3 個詞。結果**詞庫裡的詞本身反而轉錯**，一般字句沒有明顯變化。詞庫只有 3 個詞，prompt 很短，「詞庫擠掉前文空間」不太可能是主因；比較可能是 whisper 本來就聽不出這些詞，或 prompt 讓它往奇怪的寫法偏。
  - 因此第 ① 層**預設停用**（`WHISPER_PROMPT` 預設 `none`，等於這個分支以前的行為），改用下面的四組對照找原因。第 ② 層、第 ③ 層不受影響。
  - 四組對照（同一場錄音、同一份詞庫，每組重新 build 一次）：

    | 組 | 指令 | 送給 whisper 的 prompt |
    |---|---|---|
    | A | `flutter run --release` | 不送 |
    | B | `flutter run --release --dart-define=WHISPER_PROMPT=lead` | 只有固定開頭 |
    | C | `flutter run --release --dart-define=WHISPER_PROMPT=glossary --dart-define=WHISPER_CARRY_PROMPT=false` | 固定開頭＋詞庫，只影響開頭 30 秒 |
    | D | `flutter run --release --dart-define=WHISPER_PROMPT=glossary` | 固定開頭＋詞庫，每 30 秒都帶 |

  - 判讀：D、C 比 A 好就恢復第 ① 層並選較好的那組；都不比 A 好就把第 ① 層移出 P1，詞庫只用在摘要和學詞。
  - **2026-10-21 四組對照結果**（錄音「手機應用開發技術介紹」，詞庫：`flutter app`、`富的斯內鋪`、`一可諾`）：

    | 專有名詞（實際講法） | A 不送 | B 只送開頭 | C 詞庫、開頭 30 秒 | D 詞庫、每 30 秒 |
    |---|---|---|---|---|
    | Flutter | BLAD ×2 | BLAD | plut | plut |
    | EchoNote ×3 | Echo Note | EKO Note | Ecklenote | Ecklenote |
    | EchoCore | Echo Core ×2 | EKO Core ×2 | Ecklenote call ×2、後段 Echo Core ×2 | Ecklenote call ×2 |
    | FoodSnap | Full Snap ×2 | Full Snap、Foursnap | Fusenap、Foursnap | Fusenap |
    | 標點符號數 | 2 | 200 | 200 | 205 |
    | 片段數 | 188 | 52 | 62 | 87 |

    - 詞庫原字（`一可諾`、`富的斯內鋪`、`flutter app`）四組都沒出現。講者講的是英文名稱，詞庫卻放了**中文音譯**，等於叫 whisper 往錯的寫法靠，所以 C、D 的英文名反而更走樣（Echo Note → Ecklenote）。這組數據**不能**說明「詞庫填正確寫法」時有沒有效。
    - 意外發現：只要送固定開頭那句話（B），逐字稿就有標點（2 → 200），但片段變長（188 → 52 段），點逐字稿跳轉播放和筆記對應的位置會變粗。
  - **重測**：詞庫改成正確寫法 `Flutter`、`EchoNote`、`EchoCore`、`FoodSnap`、`PostureCheck`，重跑 C、D（A、B 不受詞庫影響，沿用第一次結果）。之後再一起決定第 ① 層的去留，以及要不要預設送固定開頭（標點 vs 片段精度）。
  - **2026-10-21 重測結果**（A、B 沿用第一次）：

    | 專有名詞 | A 不送 | B 只送開頭 | C2 詞庫、開頭 30 秒 | D2 詞庫、每 30 秒 |
    |---|---|---|---|---|
    | Flutter | BLAD ×2 | BLAD | **Flutter** | **Flutter** |
    | EchoNote | Echo Note ×3 | EKO Note ×3 | **EchoNote ×4** | **EchoNote ×3** |
    | EchoCore | Echo Core／Echo Code | EKO Core／Echo Code | **EchoCore ×4** | **EchoCore ×4**、EchoCorre ×1 |
    | FoodSnap | Full Snap ×2 | Full Snap、Foursnap | FoodSnap、ForeSnaps | **FoodSnap ×2** |
    | PostureCheck | Post-Cheer Check、Porture Strip／Check | 同 A | PostureCheck、後段 Porture Strip／Check | **PostureCheck ×2** |
    | 07:47 結尾的 EchoCore | Airco-cove | Ego Code | AirGoogle | **EchoCore** |
    | 標點／片段數 | 2／188 | 201／52 | 195／90 | 196／60 |

    - **D2 最好**：5 個詞幾乎全對，而且錄音後段（05:55、07:47）也對。C2 只有開頭 30 秒對，後段又變回 Porture Strip、AirGoogle，證明 `carry_initial_prompt` 是必要的。
    - 沒有 prompt 外洩（逐字稿裡沒出現「會議逐字稿」「會提到」）。
    - C2 在 01:47 出現「EchoNote是一個會議」，使用者聽原音確認**沒講 EchoNote，是幻覺**。D2 同位置沒有這個問題。之後 T17 要留意詞庫詞的幻覺。
    - 第一次實測變差的原因確定是**詞庫填了中文音譯**，不是第 ① 層本身的問題。

### 階段 1：詞庫管理＋即時預覽

- [x] **T5 詞庫管理頁**：完成後移除 `main.dart` 的 `GLOSSARY_SEED`。新增 `GlossaryScreen`（列表、新增、編輯、刪除、釘選、顯示「前 N 個詞會送進轉錄」），在 `HomeScreen` 的 AppBar 加入口。UI 暫定。依賴：T1、T2
  - 2026-10-21 完成，**尚未實機驗證**。清單依 prompt 優先順序排列（排序抽成 `sortByPromptPriority`，和 prompt 共用）；放不進轉錄 prompt 的詞標「只用在摘要」，學到的詞標「從修改中學到」並列出常見誤寫。刪除可復原。新增詞條時也設定 `last_used_at`（規格原本就這樣寫，T1 漏了，一併補上）。`GLOSSARY_SEED` 已移除。
- [x] **T6 📱 即時預覽帶詞庫＋重新量測延遲**（T4 完成後恢復，見決定 23；**結論：不帶詞庫**，見決定 24）：`kLivePreviewConfig.initialPrompt` 改成執行時由詞庫組出（`LivePreviewConfig` 目前是 `const`，要調整成可以在執行時帶入）。在實機上用和 2026-10-10 相同的方式量測 median run 和 max lag；明顯變慢就退回固定開頭，並把結果寫回規格。依賴：T2
  - 2026-10-21 實機量測（debug 模式，各錄約 60 秒，各 20 次辨識）：

    | | 只送固定開頭 | 帶 5 個詞庫詞 |
    |---|---|---|
    | median total_ms | 503 | 650（**+29%**） |
    | median encode_ms | 319 | 325 |
    | max lag | 1.6 s | 1.8 s |

    - 超過約定的門檻（median 多 20% 以上），依約定退回只送固定開頭：`2a04233` 已 revert。正式逐字稿來自停止後的離線轉錄，那一步照常帶詞庫，不受影響。
    - encode 時間幾乎一樣，多出來的時間在解碼：prompt 變長，每次解碼要多處理這些 token。
    - 另外發現：兩組的即時預覽都有嚴重的**重複迴圈**（「經常經常經常…」「Helps,Helps,…」「金主很半斷標準」重複）。這是 `tiny` 模型即時預覽本來就有的問題，跟詞庫無關，不在這次範圍，記為後續項目。
    - 判讀限制：每組只量一次，講的內容也不同。

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

- [x] **T11 📱 即時錄音的 ★／筆記**（`LiveRecordScreen`）：時間戳取 `sentSeconds`（按下按鈕當下）；同一秒內重複的 ★ 合併；輸入框不能擋住「停止」；停止時草稿有文字就存、沒文字就丟；錄音太短被刪除時筆記一起丟棄；在 `_onRecordingDone` 建立 `Recording` 時寫入 `notes`。依賴：T9
  - 2026-10-21 完成，實機驗收通過（即時錄音的 ★／筆記／停止時保存草稿、回放的 ★／筆記／刪除復原、分析後的 AI 補充說明與逐字稿標記、鍵盤不擋停止鈕）。筆記輸入框直接嵌在畫面裡（不用對話框，才不會擋住「停止」）；任何結束原因都會保存有文字的草稿；時間戳超過實際錄音長度的筆記，存檔時夾到錄音結尾。「同一秒內的 ★ 合併」抽成 `addStarNote`，和播放列共用。
- [x] **T12 播放列的 ★／筆記**（`MeetingDetailScreen`）：時間取目前播放位置；支援編輯文字和刪除（不能改時間）；刪除時連同 AI 補充說明一起移除。依賴：T9
  - 2026-10-21 完成。另外做了：同一秒內重複的 ★ 合併（原本只寫在 T11）、刪除後可從 SnackBar 復原（連同 AI 補充說明）。筆記清單先放在摘要頁上方、未分析也顯示；T13 再補 AI 補充說明、逐字稿標記和「有新的重點尚未分析」。
- [x] **T13 「你的重點」區塊＋逐字稿標記**：摘要頁最上方顯示使用者原文和 AI 補充說明（區隔樣式），**還沒分析時也要顯示**；分析後新增的筆記提示「有新的重點尚未分析」；逐字稿頁在對應片段顯示筆記標記，點一下跳轉播放。依賴：T10、T12
  - 2026-10-21 完成。「有新的重點尚未分析」改成判斷「筆記沒有 AI 補充說明」，提示文字為「有 N 筆重點還沒有 AI 補充說明，重新分析可補上」，這樣 Claude 漏掉某筆時也會提示。逐字稿標記和分析用同一個 `segmentIndexFor`，標記會落在 AI 看到的同一行。

### 階段 5：重新轉錄、逐字稿編輯、第 ③ 層

- [x] **T14 用目前詞庫重新轉錄**：已轉錄的錄音在 AppBar 選單新增入口；確認對話框依有沒有 `edited` 片段顯示不同警告；已有分析就設 `transcript_stale_analysis = true`，摘要頁顯示「分析可能過時」提示列和「重新分析」；轉錄失敗時原資料不動（沿用 `RecordingTranscriber` 的保證）。依賴：T3、T9
  - 2026-10-21 完成，實機驗收通過。「可能過時」標記改在 `RecordingTranscriber` 設定（轉錄成功且已有分析時），一次寫檔。提示列放在播放列下方、所有分頁都看得到（待辦和會議紀錄一樣會過時），不只摘要頁。重新轉錄進度改顯示在播放列下方，舊逐字稿在完成前照常可看。
- [x] **T15 逐字稿片段編輯**：長按片段跳出編輯對話框（點擊維持跳轉播放），儲存後標記 `edited = true` 並存檔。依賴：T9
  - 2026-10-21 完成。內容沒變（或清空）時不存、不標 `edited`。
- [x] **T16 第 ③ 層學詞**：
  - 純函式做字元層級 diff，只在「剛好一段連續替換、新舊字串都在 1～10 字」時回傳替換組；附單元測試。
  - 對話框提供三個選項：加入詞庫並套用到本場其他 N 處（N = 0 時不顯示）、只加入詞庫、不用。
  - 「套用」是在本場其他片段做字面替換，被改到的片段標 `edited`，已有分析就設 `transcript_stale_analysis`。
  - 詞庫已有相同 `term` 時，把舊字串加進 `aliases`，不建立重複詞條。
  - 選「不用」時記進 `dismissed_replacements`，同一場不再詢問。
  - 有命中時更新 `last_used_at`。

  依賴：T1、T15
  - 2026-10-21 完成，實機驗收通過，觸發規則依決定 19、20 修訂（見「第 ③ 層詢問的觸發規則」）。對話框做成自己管理輸入框生命週期的 widget：原本關閉動畫還沒結束就釋放了輸入框的 controller，debug 版會報錯，測試時發現並修正。

### 階段 6：驗收與收尾

- [x] **T17 📱 筆記驗收**：在一場會議標 5 個 ★／筆記，檢查摘要和待辦涵蓋了幾個，並做主觀比較；同時用長會議（44 分鐘那場）加上多筆筆記，確認 `max_tokens: 4096` 不會被截斷，把結果寫回規格。依賴：T13
  - 2026-10-21 完成，結果見「驗收核對記錄」。
- [ ] **T18 核對與紀錄**：用 `/spec-check` 核對規格和實作，用 `/devlog` 整理開發紀錄，規格狀態改成「已完成」。依賴：全部

## 驗收核對記錄

### 2026-10-21 最後一輪實機驗收（iPhone 12 Pro Max，`flutter run --release`，詞庫：Flutter、EchoNote、EchoCore、FoodSnap、PostureCheck）

清單：https://claude.ai/artifact/ReZXPi6g2kMzXkPhnsx73V 。T11～T16 先前已逐項實機驗收通過（見各任務備註），不在這份清單裡。

| 編號 | 項目 | 結果 | 備註 |
|---|---|---|---|
| T17-1 | 5 個重點有沒有都進到摘要和待辦 | Pass | |
| T17-2 | 有標記的摘要是否更接近自己會寫的版本 | Pass | |
| T17-3 | 長會議加多筆筆記不會被截斷 | Pass | `max_tokens: 4096` 維持不變 |
| D18 | 筆記內容會不會被寫成會議裡有人說過 | Pass | 決定 18 的殘留問題在真實會議沒有出現，不再處理 |
| D23 | 片段變長後跳轉和筆記位置夠不夠準 | Pass | 片段長度不處理 |
| T4 | 詞庫詞有沒有出現在沒講的地方 | Pass | 沒發現幻覺 |
| T5-1 | 清單順序和「只用在摘要」標記 | Pass | |
| T5-2 | 新增、編輯、刪除與復原 | Pass | 已依決定 25 放寬標點 |
| T5-3 | 從修改逐字稿學到的詞顯示在詞庫頁 | **未完成** | 使用者備註：「不知道怎麼修改」 |
| T5-4 | 空詞庫第一次新增不會當掉 | Pass | |

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
| 19 | diff 只抓到半個詞（「太基」→「台積」）怎麼辦（T16 實作時發現） | 正確寫法做成可編輯欄位，錯誤寫法依使用者補的字自動推算；「修正其他 N 處」用推算後的完整錯誤寫法比對 |
| 20 | 單字替換要不要詢問 | 不詢問，長度規則從 1～10 字改成 2～10 字 |
| 21 | 第 ① 層實測讓詞庫的詞更不準（T4 第一次實測） | 第 ① 層預設停用（`WHISPER_PROMPT=none`），用 A～D 四組對照找原因後再決定去留；T6（即時預覽帶詞庫）暫停，等 T4 結論 |
| 22 | 詞庫頁沒說清楚要填正確寫法（T4 使用者填了中文音譯） | 空詞庫說明和新增欄位加上「填你希望逐字稿出現的寫法（例如 EchoNote），不是它聽起來的音」 |
| 23 | T4 結論：第 ① 層去留 | 恢復，預設採 D2（詞庫＋`carry_initial_prompt`），`WHISPER_PROMPT` 開關保留到 T17 驗收後移除；`kGlossaryPromptMaxChars` 維持 80（5 個詞遠低於上限，尚無依據調整）。片段變長（188 → 60 段）先實際使用，T17 再判斷跳轉和筆記位置夠不夠準。T6 恢復 |
| 24 | T6 即時預覽要不要帶詞庫 | 不帶。實測 median 解碼時間多 29%，超過 20% 門檻；`2a04233` 已 revert。即時預覽的重複迴圈另列後續項目 |
| 25 | 詞條能不能有標點（驗收 T5 時使用者提出） | 只擋換行，`、`、`，`、`,`、`。` 都可以用，讓 `Apple, Inc.` 這類名稱能放進詞庫；whisper prompt 裡的標點只是文字的一部分，影響很小 |
