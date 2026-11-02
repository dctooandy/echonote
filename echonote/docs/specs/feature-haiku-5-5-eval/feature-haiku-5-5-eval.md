# 評估換成 Haiku 5.5 規格

分支：`feature/haiku-5-5-eval`
狀態：已完成（2026-11-02，結論：維持 Haiku 4.5），待併入 master

會議分析目前用 Claude Haiku 4.5。這個分支用分析評測集，比較 Haiku 4.5 和 Haiku 5.5 的品質、速度、費用，決定要不要換。這是 2026-10-30 定案路線的第 ⑤ 步（評測集要先有，才評估換模型）。這個分支本身只跑評測、寫結論；真的要換時，才改正式環境的參數並部署（部署由使用者執行）。

## 現況（寫規格時查過的程式碼和資料）

- 正式環境的參數（`functions/src/analyze.ts` 的 `buildAnalysisParams`）：`model: claude-haiku-4-5`、`max_tokens: 6000`、`system`、`messages`、`output_config.format`（JSON schema）。沒有設 `temperature`、沒有 prefill、沒有 thinking。
- `functions/src/index.ts`：`analyzeMeeting` 的 `timeoutSeconds: 120`。
- 評測腳本 `npm run eval -- --model <id>` 已經可以換模型；目前只能換模型，不能設 effort、thinking、`max_tokens`。
- 價格表 `functions/eval/pricing.ts` 已有 Haiku 5.5（$0.10／$0.50，快取最低 512 token）。
- `@anthropic-ai/sdk` 0.112.4，型別已有 `output_config.effort` 和 adaptive thinking，不用升級。
- 最近一次全部案例的基準：`20261101-1750_claude-haiku-4-5`（notes-leak 第 1 版 prompt），6 筆 × 3 次，284/285。

### Haiku 5.5 跟 4.5 不一樣的地方（2026-11-02 用 claude-api skill 查證）

- **預設會思考**（adaptive thinking），思考量由 `output_config.effort` 控制，**預設 `medium`**，可選 `low`／`medium`／`high`／`xhigh`／`max`。可以用 `thinking: {type: "disabled"}` 關掉（只在 `high` 以下）。
- **思考會吃 `max_tokens`**：上限太小時，可能想完就沒額度寫答案（`stop_reason: max_tokens`）。
- **同樣的文字約多 30% token**（新的 tokenizer）。
- **價格**：輸入 $0.10、輸出 $0.50／百萬 token（提示在 10 萬 token 以內；Haiku 4.5 是 $1／$5），約便宜 10 倍；快取讀取 0.1 倍、寫入 1.25 倍，最低 512 token 就能快取（4.5 要 4096）。
- **不能設 `temperature`、不能 prefill**：我們本來就沒用，不受影響。
- **安全分類器可能拒答**（`stop_reason: refusal`），而且 Haiku 5.5 沒有伺服器端備援；會議內容一般不會碰到，但評測要記錄。
- 回應可能先有 `thinking` 區塊：評測腳本和正式環境都是用「找 `type === "text"`」拿答案，不受影響。

## 目標與範圍

1. 評測腳本可以設 effort、thinking 開關、`max_tokens`，報告記錄這些設定。
2. 用現在的 prompt，分別跑 Haiku 4.5 和 Haiku 5.5 的幾種設定（見待確認 1），全部案例各 N 次。
3. 報告加上速度（每次呼叫的秒數：中位數、最慢）和每次呼叫的平均費用，方便比較。
4. 依達標條件（待確認 4）寫出結論：換不換、用哪個設定。
5. 決定要換時：改 `buildAnalysisParams` 的模型和設定、補測試，問使用者後由使用者部署，部署後實機重新分析一場確認。

**明確不做的事**：

- 不改 prompt 和 schema（換模型和改 prompt 分開，才知道是誰造成的差異）。
- 不做 LLM 評分；只用現有的程式檢查加人工看附錄。
- 不評其他模型（Sonnet、Opus）。

## API 異動

- `buildAnalysisParams(req, { model?, effort?, thinking?, maxTokens? })`：新增選填參數，預設值跟現在正式環境一樣；評測用。
- 決定要換時，`ANALYSIS_MODEL`、`ANALYSIS_MAX_TOKENS` 和 effort 改成選定的值。

### 評測腳本：`npm run eval` 新增參數

- `--effort <low|medium|high>`：只對支援 effort 的模型送出。
- `--thinking <adaptive|disabled>`：不設就不送（模型的預設）。
- `--max-tokens <n>`：不設就用正式環境的值。
- 報告和 `run.json` 記錄這三個設定；跟基準輪比較時一併列出。

## 資料表異動

無。

## 權限與狀態機

無。

## UI／畫面

無。

## 邊界案例與例外處理

- **思考吃光 `max_tokens`**：那一次的 `stop_reason` 是 `max_tokens`，「通用:未截斷」會失敗；報告另外列出被截斷的次數。
- **拒答**：`stop_reason: refusal` 記為失敗，報告列出類別。
- **費用估算**：Haiku 5.5 的 token 數用 `countTokens` 帶 `model: claude-haiku-5-5` 算（新的 tokenizer），不沿用 4.5 的數字；估算的典型輸出要把思考算進去（見待確認 3）。
- **送了模型不支援的參數**（例如對 Haiku 4.5 送 effort）：腳本開跑前就擋下，不花錢。

## 測試接縫

- `buildAnalysisParams`：不帶選項時跟現在一模一樣；帶 effort／thinking／maxTokens 時參數正確；Haiku 4.5 帶 effort 會丟錯。
- 報告：速度（中位數、最慢）、截斷次數、設定欄位、跟基準輪的設定差異。
- 手動：使用者看附錄，比較兩個模型在 C2（與上次相比）、C5（長會議）的摘要品質。

---

## 決定（2026-11-02，使用者依照建議）

1. 比較三組：A Haiku 4.5（正式設定）、B Haiku 5.5 effort `low`、C Haiku 5.5 effort `medium`；B、C 都比 A 差時加跑 D（`high`）。全部 6 個案例各 3 次。
2. Haiku 5.5 的 `max_tokens` 用 16000。
3. 每輪費用上限 US$0.5。
4. 換的條件：通過率不低於 A、C4／C6 沒退步、人工看 C2／C5 不比 4.5 差、沒有截斷、最慢不超過 60 秒；B、C 都達標選 B。
5. 要換時正式環境的改動也在這個分支做（結果沒有要換，見評測紀錄）。
6. App 端「分析中」的提示先不調整。

## 評測紀錄

### 2026-11-02（prompt `42c49f61`，commit `52972f8`，每組 6 筆 × 3 次）

| 組 | 輪次 | 通過率 | 速度（中位數／最慢） | 每次費用 | 花費 |
|---|---|---|---|---|---|
| A Haiku 4.5 | `20261102-0812_claude-haiku-4-5` | **98%（278/285）** | 9.3／25.6 秒 | US$0.0084 | US$0.151 |
| B 5.5 low | `20261102-0817_claude-haiku-5-5` | 93%（264/285） | 7.8／11.5 秒 | US$0.0011 | US$0.020 |
| C 5.5 medium | `20261102-0821_claude-haiku-5-5` | 95%（270/285） | 12.8／19.2 秒 | US$0.0015 | US$0.027 |
| D 5.5 high | `20261102-0825_claude-haiku-5-5` | 93%（266/285） | 18.9／33.5 秒 | US$0.0022 | US$0.040 |

- 四組都沒有截斷、沒有拒答；C4／C6（筆記外洩）都沒有退步。合計花費 US$0.238。
- Haiku 5.5 退步的地方有規律：
  - **詞庫只套用到出席者，沒套用到待辦負責人**（C3：出席者寫「蔡宜蓁、吳承翰」，負責人卻是逐字稿的「一針」「乘汗」）：B 0/3、C 1/3、D 0/3（A 也有 1/3 沒改）。
  - **看不懂的字不推斷**：「新網欲」4.5 推成「網域」，5.5 常寫「逐字稿內容不清楚」（C1、C6 的「申請網域」）。
  - B 有一次 C4 的待辦整個是空的；C 有一次把小明的待辦掛到別人名下。
- effort 調高沒有改善上面兩點，只變慢（D 最慢 33.5 秒）。比較像 prompt 不夠明確，不是想得不夠。
- A 跟前一天同模型同 prompt 比，C3、C5 也有起伏：3 次的樣本只能看出大的差距。

### 結論（使用者 2026-11-02 確認）

- **維持 Haiku 4.5**，正式環境不改、不用部署（`buildAnalysisParams` 不帶選項時參數跟原本完全一樣，有測試）。換模型主要省的是錢，但目前每次分析約 US$0.008，用滿每天 50 次上限一個月也約 US$13，不值得用 3～5 個百分點的品質去換。
- 下一步另開 `fix/glossary-owner`：prompt 寫明「出席者、待辦負責人等所有欄位都套用詞庫」、「讀不通的字依上下文推斷最可能的詞」；先用 4.5 量（不可變差）再部署，之後用 4.5、5.5 各跑 5 次重新比較。
- Sonnet 5.5 先不評。
- C5 的「待辦:整理簡報或報告」拿掉（連 4.5 都只有 1/3，會議裡沒有明確交代；使用者決定）。
