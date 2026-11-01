# 分析評測集規格

分支：`feature/analysis-eval-set`
狀態：已確認（2026-11-01，待確認事項 1～14 全部依照建議；案例錄音已完成）

這份文件定義一套在本機執行的「分析評測集」：用固定的會議逐字稿和預期結果，重複呼叫跟正式環境同一份 prompt 和 schema，用程式檢查輸出、產出報告。目的是之後改 prompt 或換模型（評估 Haiku 5.5）時，能用數字判斷變好還是變差，不再只靠一次實機手動看。這是 2026-10-30 定案路線的第 ③ 步（見 Obsidian 的 D4），需求在 2026-11-01 用 12 題確認（全部依照建議）。

## 背景（2026-11-01 確認）

1. 案例來源：照稿錄的會議，加上 2～3 場使用者同意使用的真實會議。
2. 真實會議的逐字稿不進 git，放在 gitignore 的 `evals/private/`；照稿案例進 git。
3. 真實逐字稿的取得方式：用 Xcode 的 Devices 視窗下載 App 容器，取出 `history/<id>.json`。
4. 第一版 5～8 筆，涵蓋一般單場、接續上一場、自訂詞庫、個人筆記、長會議（30 分鐘以上）。
5. 在本機跑 node 腳本，共用 `functions/src/analyze.ts` 的 prompt 和 schema，直接呼叫 Anthropic API（不經 App Check、不算每日次數）。
6. API key 放在 gitignore 的 `functions/.env.local`，跟正式環境用不同的 key。
7. 評分：程式檢查「必須出現／不可出現／待辦狀態／決議變化」，再產出對照報告給人工看；LLM 評分之後再說。
8. 評全部輸出：摘要、待辦、會議紀錄、`follow_up`、`highlight_contexts`。
9. 每筆跑 3 次，報告寫出每一項在 3 次中通過幾次。
10. 每輪費用上限 US$0.5，超過先停下來問。
11. 可以指定模型和 prompt 版本，報告記錄下來，可以跟上一輪比較。
12. 先不接 CI，手動執行。

## 現況（寫規格時查過的程式碼）

- `functions/src/analyze.ts`：`AnalyzeMeetingRequest`、`validateRequest`、`buildUserMessage`、`SYSTEM_PROMPT`、`outputSchema`，不依賴 Firebase，已經可以單獨匯入。
- `functions/src/index.ts:78-86`：`messages.create` 的參數寫在 onCall 裡（`model: "claude-haiku-4-5"`、`max_tokens: 6000`、`output_config.format`），評測腳本要跟它一模一樣，目前沒有共用的地方。
- `functions/`：TypeScript，`npm test` 用 `tsconfig.test.json` 編譯到 `build-test/` 再跑 `node --test`；Node 22；`@anthropic-ai/sdk` ^0.112.4。
- `firebase.json` 的 functions `ignore` 已經包含 `*.local`，`functions/.gitignore` 也有 `*.local`，所以 `functions/.env.local` 不會進 git，也不會被部署上傳。
- App 端組 request 的邏輯是 Dart：`buildHighlights`、`segmentIndexFor`（`lib/services/analysis_service.dart`，這個檔案 import 了 `cloud_functions`，不能用純 Dart 執行）、`previousChain`、`toPreviousMeetingPayload`（`lib/services/meeting_chain.dart`，純 Dart）。
- `history/<id>.json` 就是 `Recording.toJson()`：`segments`、`notes`、`analysis`、`previous_recording_id` 等。
- 第一筆案例的稿子和預期結果：`docs/specs/feature-cross-meeting-memory/acceptance-script.md`。

## 目標與範圍

1. **案例格式**：每筆案例一個資料夾，內含送給分析的 request（凍結，不再隨 App 資料變動）和預期結果。
2. **匯出工具**：用 Dart 寫（`tool/export_eval_case.dart`），把手機下載的 App 容器裡的 `history/<id>.json`（加上接續的前幾場、詞庫）轉成案例的 request，呼叫 App 同一批函式，跟 App 送出的完全一樣。每一場可以決定帶不帶詞庫（`--glossary` / 不帶），因為詞庫是全域的，C3 加的詞庫不該跟著 C1、C2、C4。
3. **評測腳本**：讀案例、每筆跑 N 次（預設 3）、用程式檢查、寫報告；可以指定模型、案例、次數、費用上限、比較的基準輪。
4. **共用參數**：評測和正式環境用同一個函式組 `messages.create` 的參數，避免兩邊不一致。
5. **第一版案例**：5 筆（C1～C5，見下方「第一版案例」），涵蓋背景第 4 點的五種情境。
6. **報告**：每一項檢查在 N 次中通過幾次、每筆的花費和 token 數、跟基準輪的差異；附上每次的原始輸出，方便人工看。

**明確不做的事**：

- 不用 LLM 評分（之後再說）。
- 不接 CI、不在部署前自動執行。
- 不改 App 的分析行為；只有 function 端抽出共用參數，線上行為不變。
- 不評轉錄（whisper）的品質，只評 Claude 的分析。
- 不做評測結果的畫面，報告是 Markdown。

## 第一版案例（2026-11-01 錄音完成）

| 代號 | App 裡的名稱 | 情境 | 放哪裡 | 稿子／預期結果 |
|---|---|---|---|---|
| C1 | 官網改版週會（第一場） | 一般單場 | `evals/cases/` | `docs/specs/feature-cross-meeting-memory/acceptance-script.md` |
| C2 | 官網改版週會（第二場，接續 C1） | 接續上一場 | `evals/cases/` | 同上 |
| C3 | 即時錄音 2026-11-01 13:11 | 自訂詞庫（轉錄後才加詞庫） | `evals/cases/` | [`recording-scripts.md`](recording-scripts.md) |
| C4 | 即時錄音 2026-11-01 12:33 | 個人筆記（含兩則陷阱筆記） | `evals/cases/` | 同上 |
| C5 | 分散式太陽光電推動策略與… | 長會議（真實） | `evals/private/` | 我先擬 `expect.json`，使用者確認 |

C6～C7（再 1～2 場真實會議）這一版不做。照稿案例的逐字稿用實機錄音轉出來的版本（決定 3），稿子放在 `README.md`。

## API 異動

`analyzeMeeting` 的對外行為不變。內部重構：

- `functions/src/analyze.ts` 新增 `ANALYSIS_MODEL = "claude-haiku-4-5"`、`ANALYSIS_MAX_TOKENS = 6000`，以及 `buildAnalysisParams(req, { model? })`，回傳 `messages.create` 的完整參數（`model`、`max_tokens`、`system`、`messages`、`output_config`）。
- `index.ts` 改呼叫 `buildAnalysisParams(data)`，評測腳本呼叫 `buildAnalysisParams(req, { model })`。
- `PROMPT_VERSION`：不手動維護，由 `SYSTEM_PROMPT` 加 `outputSchema` 的內容雜湊（取前 8 碼）自動算出，報告另外記錄 git commit。

### 評測腳本：`npm run eval`（在 `functions/` 執行）

- 參數：
  - `--model <id>`：預設 `ANALYSIS_MODEL`
  - `--cases <名稱,…>`：預設全部（含 `evals/private/` 底下存在的）
  - `--runs <n>`：預設 3
  - `--budget <美元>`：預設 0.5
  - `--baseline <輪次資料夾>`：預設上一輪
  - `--label <文字>`：寫進報告，方便辨識這一輪改了什麼
- API key：讀 `functions/.env.local` 的 `EVAL_ANTHROPIC_API_KEY`（用 Node 22 的 `--env-file`）。變數名稱刻意跟正式環境的 secret `ANTHROPIC_API_KEY` 不同，避免 Firebase 模擬器把兩者混在一起。
- 執行前先估算這一輪的費用（見邊界案例），超過 `--budget` 就停下來，列出估算，不送出任何請求。
- 依序執行，不並行；每次呼叫的 `stop_reason`、`usage`、耗時都記錄下來。
- 錯誤：key 沒設定、案例格式錯誤、request 沒通過 `validateRequest` → 開跑前就失敗，不花錢。單次呼叫失敗（SDK 重試後仍失敗）→ 那一次記為失敗，繼續跑其他的。

## 資料表異動

無資料庫異動。新增檔案格式：

### 案例：`evals/cases/<案例名>/`（照稿，進 git）、`evals/private/<案例名>/`（真實，不進 git）

- `request.json`：`AnalyzeMeetingRequest`，就是 App 當時會送出的內容（`segments`、`glossary`、`highlights`、`previous_meetings`）。
- `expect.json`：預期結果，格式如下（每一項都是選填）：

```jsonc
{
  "description": "這筆案例在測什麼",
  "must_include": [
    // 在指定欄位裡，any_of 任一個詞出現就算通過
    { "id": "延期", "in": ["summary", "structured_minutes"], "any_of": ["11 月 22", "11/22", "十一月二十二"] }
  ],
  "must_not_include": [
    // 在指定欄位裡，任一個詞出現就算失敗（陷阱）
    { "id": "Meetup 陷阱", "in": ["summary", "todos", "structured_minutes"], "terms": ["Meetup", "贊助"] }
  ],
  "todos": [
    // 這次的待辦裡，要有一筆 task 包含 any_of 任一個詞；owner 選填
    { "id": "FAQ 草稿", "any_of": ["FAQ", "常見問題"], "owner_any_of": ["小華"] }
  ],
  "todo_progress": [
    // previous_todo_index 對應的狀態
    { "id": "文案完成", "previous_todo_index": 0, "status": "done" }
  ],
  "decision_changes": [
    // previous_decision 包含 any_of 任一個詞的那筆，change 要符合
    { "id": "主色推翻", "previous_any_of": ["藍"], "change": "reversed" }
  ],
  "new_topics": [{ "id": "FAQ", "any_of": ["FAQ", "常見問題"] }],
  "highlight_contexts": { "count": 2 }
}
```

- 欄位代號對應：`summary` ＝ overview＋key_points；`todos` ＝ task＋owner＋due_date；`structured_minutes` ＝ title＋attendees＋agenda_items 全部文字；`follow_up`；`highlight_contexts`。
- `README.md`（選填）：照稿案例附上稿子或稿子的連結。

### 每筆案例都自動加的通用檢查

- 回傳是合法 JSON，而且通過 schema（必填欄位都在）。
- `stop_reason` 不是 `max_tokens`（沒有被截斷）。
- 所有 `source_segment_index` 都在逐字稿範圍內（或 null）。
- 所有 `previous_todo_index` 都在 `previous_meetings` 最後一場的待辦範圍內。
- 輸出沒有簡體字（用常見簡繁對照字的小清單檢查）。

### 評測結果：`evals/runs/<YYYYMMDD-HHmm>_<model>/`（不進 git）

- `run.json`：模型、PROMPT_VERSION、git commit、label、每次呼叫的原始輸出、usage、耗時、每項檢查的結果。
- `report.md`：
  - 開頭：模型、prompt 版本、總花費、總體通過率、跟基準輪的比較（哪幾項變好、變差）。
  - 每筆案例：每項檢查「3 次中通過幾次」，失敗的列出實際內容。
  - 附錄：每次的摘要、待辦、`follow_up` 原文，方便人工比對。

## 權限與狀態機

無。

## UI／畫面

無（報告是 Markdown 檔）。

## 邊界案例與例外處理

- **費用估算**：用 `messages.countTokens` 算每筆的輸入 token，輸出以 `max_tokens` 的上限估算最壞情況，乘上次數和模型單價。單價寫在腳本的價格表裡，見待確認 5。
- **實際花費超過上限**（估算偏低時）：每次呼叫後累加實際花費，超過 `--budget` 就停在那裡，報告標示「未跑完」。
- **模型不支援結構化輸出或參數**（例如之後換模型）：那一次記為失敗，錯誤訊息寫進報告。
- **SDK 重試後仍然 429 或 5xx**：那一次記為失敗，繼續跑。
- **`evals/private/` 不存在或是空的**：只跑照稿案例，報告註明。
- **基準輪不存在、或案例不同**：只比較共同的案例和檢查項目，其他的標成「新增」或「已移除」。
- **案例的 request 沒通過 `validateRequest`**（例如 prompt 規則改了長度上限）：開跑前列出來，不花錢。
- **長會議超過模型的輸入上限**：目前的模型不會遇到；遇到時那一次記為失敗。

## 測試接縫

- **純函式**（`node:test`，沿用 `functions/test/`）：
  - `buildAnalysisParams`：預設模型和 `max_tokens` 跟現在的線上參數一致；可以覆寫模型。
  - `promptVersion()`：內容不變時雜湊不變；改一個字就變。
  - 檢查器 `gradeOutput(output, request, expect)`：每種檢查各有通過和失敗的例子（用手寫的假輸出，不呼叫 API）。
  - 費用估算 `estimateCost(tokens, runs, model)` 和報告比較 `compareRuns(current, baseline)`。
- **匯出工具**：直接呼叫 App 的 `buildHighlights`、`previousChain`、`toPreviousMeetingPayload`，所以只測轉檔本身：給一份假的容器資料夾，輸出的 `request.json` 欄位正確、帶不帶詞庫依參數、接續的前幾場正確凍結。
- **手動**：第一輪實際跑一次，人工看報告的附錄，確認檢查結果跟自己讀的判斷一致。

---

## 任務拆解

2026-11-01 初版：依本規格和 `functions/src/analyze.ts`、`functions/src/index.ts`、`lib/services/analysis_service.dart`、`lib/services/meeting_chain.dart` 的現況拆分。

**第一批可以開工**：T1、T2、T3（不改同一檔案，可以同時做）
**建議做法**：implement，依序做（共 6 張，符合並行門檻，但前三張份量小，依序做比較省）

```mermaid
flowchart LR
  T1 --> T4
  T2 --> T4
  T3 --> T5
  T2 --> T5
  T4 --> T6
  T5 --> T6
```

- [ ] **T1 正式環境和評測共用同一組參數**
  - 做完能看到：`buildAnalysisParams()`、`promptVersion()` 有測試；`index.ts` 改呼叫它，線上行為不變。
  - 被誰卡住：無，可以直接開工
  - 主要會動的檔案：`functions/src/analyze.ts`、`functions/src/index.ts`、`functions/test/analyze.test.ts`
  - 軌道：可獨立進行
  - 驗收：
    - [ ] 預設模型 `claude-haiku-4-5`、`max_tokens` 6000、system、messages、`output_config` 跟改動前一致
    - [ ] 可以覆寫模型
    - [ ] `promptVersion()` 內容不變時相同、改一個字就變
    - [ ] `npm test`、`npm run build` 通過（不部署，決定 14）

- [ ] **T2 評分程式**
  - 做完能看到：用手寫的假輸出，`gradeOutput(output, request, expect)` 對每一種檢查都給出正確的通過／失敗。
  - 被誰卡住：無，可以直接開工
  - 主要會動的檔案：`functions/eval/grade.ts`、`functions/test/grade.test.ts`、`functions/tsconfig.test.json`
  - 軌道：可獨立進行
  - 驗收：
    - [ ] `must_include`、`must_not_include`、`todos`、`todo_progress`、`decision_changes`、`new_topics`、`highlight_contexts` 各有通過和失敗的例子
    - [ ] 通用檢查：schema 必填欄位、沒有被截斷、序號在範圍內、`previous_todo_index` 在範圍內、簡體字
    - [ ] 欄位代號對應正確（例如 `summary` 包含 overview 和 key_points）

- [ ] **T3 匯出工具**
  - 做完能看到：`dart run tool/export_eval_case.dart` 把 App 容器裡的一場會議轉成 `request.json`，依參數帶不帶詞庫，接續的前幾場凍結在檔案裡。
  - 被誰卡住：無，可以直接開工
  - 主要會動的檔案：`lib/services/analysis_service.dart`、新的純 Dart 檔（`buildHighlights`、`segmentIndexFor`）、`tool/export_eval_case.dart`、`test/`
  - 軌道：可獨立進行
  - 驗收：
    - [ ] 前置重構後 `flutter test` 全部通過
    - [ ] 用假的容器資料夾測試：欄位正確、帶不帶詞庫、接續的前幾場、找不到會議時的錯誤訊息
    - [ ] 用名稱（標題或錄音名稱）或 id 都能指定會議

- [ ] **T4 評測腳本與報告**
  - 做完能看到：`npm run eval` 會先估算費用，超過上限就停；每筆跑 N 次（同一筆的逐字稿用快取）；寫出 `run.json`、`report.md`，並跟基準輪比較。
  - 被誰卡住：T1、T2
  - 主要會動的檔案：`functions/eval/`、`functions/package.json`、`.gitignore`
  - 軌道：可獨立進行
  - 驗收：
    - [ ] `estimateCost`、`compareRuns` 有測試（價格表用官方最新價格查證）
    - [ ] 沒有 key、案例格式錯誤、request 沒通過驗證時，開跑前就失敗
    - [ ] 報告標出 `expect.json` 被修改過的案例
    - [ ] `.gitignore` 加上 `evals/private/`、`evals/runs/`

- [ ] **T5 建立 C1～C5 案例**
  - 做完能看到：5 個案例資料夾都有 `request.json`、`expect.json`（C5 經使用者確認）、`README.md`。
  - 被誰卡住：T2（`expect.json` 的格式）、T3
  - 主要會動的檔案：`evals/cases/`、`evals/private/`
  - 軌道：需要使用者配合（用 Xcode 下載 App 容器、確認 C5 的預期結果）
  - 驗收：
    - [ ] C3 帶詞庫，其他不帶
    - [ ] C2 的 `previous_meetings` 有 C1 的結論
    - [ ] C4 的 `highlights` 有 3 筆
    - [ ] C5 只在 `evals/private/`，`git status` 看不到

- [ ] **T6 第一輪實際評測**
  - 做完能看到：一份真實報告；使用者看附錄的原始輸出，確認程式評分跟自己的判斷一致。
  - 被誰卡住：T4、T5
  - 主要會動的檔案：視需要修正 `expect.json` 或評分程式
  - 軌道：需要使用者配合（開跑前確認費用估算、看報告）
  - 驗收：
    - [ ] 開跑前把估算給使用者看，同意後才送出
    - [ ] 實際花費在 US$0.5 以內
    - [ ] 程式評分跟人工判斷不一致的地方都已處理（修 `expect.json` 或評分程式）

## 決定（2026-11-01 確認，全部依照建議）

1. 位置：案例放 App 根目錄的 `evals/cases/`、`evals/private/`，結果放 `evals/runs/`；腳本放 `functions/eval/`。`.gitignore` 加上 `evals/private/`、`evals/runs/`。
2. 匯出工具用 Dart（`tool/export_eval_case.dart`），呼叫 App 同一批函式。前置重構：把 `buildHighlights`、`segmentIndexFor` 從 `analysis_service.dart` 搬到不依賴 Flutter 外掛的檔案。
3. 照稿案例用實機錄音轉出來的逐字稿；稿子另外放 `README.md`。
4. 錄音：全部實機；C1～C5 已錄好（見「第一版案例」），C6～C7 這一版不做。詞庫依每一場決定帶不帶。
5. 費用：同一筆的 N 次用 prompt caching 快取；單價實作時用官方最新價格表查證；開跑前估算超過 `--budget` 就停下來問。
6. 真實會議的 `expect.json` 由我先擬，使用者確認後才算定案。
7. 新稿子：C3（詞庫）、C4（個人筆記，含兩則陷阱筆記），見 `recording-scripts.md`。
8. 溫度不設，跟正式環境一樣。
9. 保留「通過 schema」檢查。
10. 接續案例的 `previous_meetings` 凍結在匯出當下的版本。
11. 簡體字檢查只列約 20 個明確的簡體字，誤判時再調整。
12. `evals/runs/` 不進 git 就夠；要分享時只分享照稿案例的部分。
13. `any_of` 多列幾種說法；修改 `expect.json` 時，報告標出「檢查本身被修改過」（用 `expect.json` 的內容雜湊判斷）。
14. `index.ts` 抽出共用參數後，等下一次有實際改動時再一起部署；部署前先問。
