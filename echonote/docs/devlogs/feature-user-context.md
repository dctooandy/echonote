# 使用者脈絡（自訂詞庫＋個人筆記）開發紀錄

分支：`feature/user-context`
狀態：已完成（實機驗收 10/10、`/spec-check` 落差已處理），待併入 master

這個分支讓使用者把「AI 不知道、但自己知道」的資訊交給 EchoNote：**自訂詞庫**處理「聽錯字」（人名、公司名、產品名），**個人筆記／★ 重點**處理「抓錯重點」。起因是 2026-10-21 和 Good Tape 的比較討論：EchoNote 不跟它比轉錄準確度，而是做「會議記憶」。規格：[`docs/specs/feature-user-context/`](../specs/feature-user-context/feature-user-context.md)。

## 目標

- 詞庫分三層使用：① 轉錄時放進 whisper 的 prompt；② 分析時請 Claude 依詞庫改正錯字；③ 使用者修改逐字稿時，可以把正確寫法學進詞庫。
- 詞庫全域一份，詞庫頁可新增、編輯、釘選、刪除；已轉錄的錄音可以「用目前詞庫重新轉錄」。
- 即時錄音中、回放時都能加 ★ 或文字筆記；分析時要求摘要涵蓋這些位置，摘要頁「你的重點」顯示使用者原文和 AI 補充說明。
- 長按逐字稿可修改；重新轉錄或批次修正後，分析標示「可能過時」。

## 踩到的坑

### 一、詞庫在 whisper（第 ① 層）

#### prompt 只影響開頭 30 秒

**現象**：寫好第 ① 層後讀 whisper.cpp 原始碼才發現，長錄音的後段等於沒有詞庫。

**原因**：whisper.cpp 預設只把 `initial_prompt` 放進第一個 30 秒視窗，之後每個視窗的上文是前面已轉出的文字，prompt 很快被擠出 224 token 的上文預算。`carry_initial_prompt` 可以讓每個視窗都帶著它，但 vendored 的 `whisper_ggml` 沒有接出這個參數。

**修法**：在 C++ 綁定（`packages/whisper_ggml/ios/Classes/whisper_flutter_plus.cpp`，iOS／Android 共用）、`TranscribeRequest`、DTO、`WhisperController.transcribe()` 接出 `carryInitialPrompt`，離線轉錄一律開啟。T4 實測證實必要：只帶開頭 30 秒的那組，錄音後段的詞又轉錯（Porture Strip、AirGoogle），每個視窗都帶的那組全對。

#### 第一次實測，詞庫反而讓詞轉得更錯

**現象**：使用者測完回報「原來的正確率比較高」，詞庫裡的詞本身轉錯，一般字句沒變。四組對照中，加了詞庫的兩組把講者說的 EchoNote 轉成 Ecklenote，比不送 prompt 的 Echo Note 還差。

**原因**：詞庫填的是**中文音譯**（「一可諾」「富的斯內鋪」），講者講的卻是英文名稱。等於叫 whisper 往錯的寫法靠。詞庫頁的說明只寫「加入專有名詞」，沒講要填正確寫法。

**修法**：詞庫改填 Flutter、EchoNote、EchoCore、FoodSnap、PostureCheck 後重測，5 個詞從「不送 prompt 一個都沒對」變成「幾乎全對、錄音後段也對」。詞庫頁的空狀態和新增欄位加上「填你希望逐字稿出現的寫法（例如 EchoNote），不是它聽起來的音」（規格決定 22）。中間曾把第 ① 層預設關掉，用 `WHISPER_PROMPT` 開關找原因，結論出來後恢復，開關在 T17 後移除。

#### 送 prompt 之後，逐字稿有標點但片段變長

**現象**：只送固定開頭那句話，標點就從 2 個變成約 200 個；但片段從 188 段變成 52～60 段。

**原因**：prompt 裡有標點，whisper 會模仿上文的風格輸出長句。

**修法**：沒有另外處理。片段變長會讓點逐字稿跳轉、筆記對應的位置變粗，T17 用真實會議驗收後判定精度可接受。

#### 即時預覽帶詞庫會變慢

**現象**：debug 模式各錄約 60 秒，帶 5 個詞庫詞的 median 解碼時間 650 ms，只送固定開頭 503 ms（+29%）。

**原因**：即時模式用 `no_context`，prompt 就是每次解碼的全部上文。prompt 變長，每次解碼都要多處理這些 token；encode 時間幾乎不變（319 對 325 ms）。

**修法**：超過約定的 20% 門檻，revert 即時預覽帶詞庫的那個 commit（`2a04233` → `fd8705b`）。正式逐字稿來自停止後的離線轉錄，仍然帶詞庫，不受影響。

### 二、Claude 分析（第 ② 層、筆記）

#### 使用者筆記被寫成「會議決議」

**現象**：部署後實測，筆記寫「要跟老闆確認底線」，Claude 在 `highlight_contexts` 寫成「會議決議需與老闆確認」，`key_points` 也照列。

**原因**：系統提示只說「`key_points` 必須涵蓋每一筆重點」，Claude 把筆記文字當成會議內容的一部分。

**修法**：`functions/src/analyze.ts` 的系統提示改成「筆記只標出重要的**位置**，涵蓋的是那個位置的會議內容」，並加上「筆記是使用者自己的想法，不可寫成會議中有人說過、決議過的內容」。重測後不再出現「會議決議」，但意思仍以「需要與內部確認降價底線」的形式滲入；T17 用真實會議驗收沒有再出現，不再處理。

#### 中文音譯第 ② 層救不回

**現象**：逐字稿裡的「依可諾」沒有被 Claude 改成詞庫裡的 EchoNote；「太基電」→「台積電」則改得很好。

**原因**：Claude 能依字形、讀音判斷中文錯字，但看不出中文音譯對應到哪個英文詞。

**修法**：無。英文名稱只能靠第 ① 層讓 whisper 直接轉對。

### 三、App

#### 空詞庫第一次新增詞條就當掉

**現象**：使用者在 debugger 停在 `_terms.add(...)`：`UnsupportedError: Cannot add to an unmodifiable list`。

**原因**：`GlossaryStore.load()` 在檔案不存在時回傳 `const GlossaryLoadResult([])`，`const` 空清單不能修改。「新增詞條」的測試都先存過一個詞，從沒走到「檔案不存在」這條路。

**修法**：改回傳新的可修改清單（`lib/services/glossary_store.dart`），補「從空詞庫新增」的測試；把修正拿掉時兩個新測試都會失敗，確認擋得住。

#### 學詞對話框關閉時報錯

**現象**：widget 測試裡出現「A TextEditingController was used after being disposed」。

**原因**：對話框 `await showDialog` 一回來就 `dispose()` controller，但關閉動畫還在用那個輸入框。

**修法**：對話框改成自己持有 controller 的 StatefulWidget（`_LearnDialog`、`GlossaryTermDialog`），在自己的 `dispose()` 釋放。

#### diff 只抓到半個詞

**現象**：「太基電」改成「台積電」，字元 diff 抓到的是「太基」→「台積」，因為「電」兩邊都有。

**原因**：中文沒有分詞邊界，程式無法判斷「電」是不是詞的一部分。

**修法**：學詞對話框的「正確寫法」做成可編輯欄位；使用者在前後補了什麼，錯誤寫法就跟著補同樣的字（`expandToTerm`，`lib/services/correction_learning.dart`），「修正其他 N 處」也用補完的字串比對。單字替換（他／她）一律不詢問（決定 19、20）。

#### 修改逐字稿後學詞對話框沒出現，使用者以為壞了

**現象**：驗收 T5-3 時使用者回報「不知道怎麼修改」「改完無法選『只加入詞庫』」。

**原因**：驗收步驟給的範例（「Full Snap」→「FullSnap App」）是兩處修改，不符合「剛好一段 2～10 字替換」的規則，所以不會跳出對話框；而 App 對不符合規則的修改完全沒有提示。另外長按修改本身也不容易被發現。

**修法**：逐字稿頁上方加「點句子跳轉播放，長按可修改」；沒觸發學詞時，底部顯示「已修改」＋「加入詞庫」，開啟和詞庫頁共用的新增對話框（決定 26）。修正步驟後補測通過。

#### iOS `--release` 看不到 log

**現象**：用 `flutter run --release` 測 T4，終端機看不到 `[Transcriber]` 那行。

**原因**：iOS 實機的 release 模式不會把 App 輸出傳回 `flutter run`。

**修法**：改用 `--profile`（一樣是 AOT 編譯，速度和 release 相當）。另外 `[live-metrics]` 只在 debug 模式輸出，量即時預覽延遲要用 debug，和 2026-10-10 的基準一致。

### 四、測試

#### widget 測試裡的真實檔案 I/O 不會完成

**現象**：詞庫頁測試 `pumpAndSettle timed out`；學詞測試「加入並修正 2 處」之後逐字稿沒有改。

**原因**：`testWidgets` 跑在 fake async 裡，真實檔案 I/O 要真的時間才會完成；載入中的轉圈動畫又讓 `pumpAndSettle` 永遠等不到結束。

**修法**：交替 `tester.runAsync(() => Future.delayed(...))` 和 `tester.pump()` 幾輪，最後才 `pumpAndSettle`（`test/screens/glossary_screen_test.dart` 的 `settle`）。

#### just_audio 的 mock 回傳 null 會當掉

**現象**：讓真實時間前進後，出現 `Null check operator used on a null value`，在 `MethodChannelJustAudio.disposeAllPlayers`。

**原因**：mock 對所有呼叫回傳 `null`，但 `disposeAllPlayers` 預期回傳 map。

**修法**：mock 改回傳空的 `Map`。

---

## 測試方法

- **自動化**：`flutter test` 共 93 個（詞庫資料層、prompt 組字、學詞 diff 與推算、筆記換算、資料模型新舊 JSON 相容、詳細頁與詞庫頁的 widget 測試）；`flutter analyze` 無問題。
- **Cloud Function**：驗證和組 user message 抽成純函式（`functions/src/analyze.ts`），用 node 直接跑 12 個情境；Firebase emulator 確認三種 `invalid-argument` 和舊版請求向下相容；部署後用假逐字稿實際呼叫，確認 `highlight_contexts` 和詞庫改字。
- **詞庫效果（T4）**：同一場錄音跑 A（不送）、B（只送開頭）、C（詞庫只帶開頭 30 秒）、D（詞庫每 30 秒都帶）四組，匯出逐字稿用腳本數每個詞的轉對次數和錯誤寫法，可疑處聽原音確認幻覺。
- **即時預覽延遲（T6）**：debug 模式各錄約 60 秒，比較 `[live-metrics]` 的 median total_ms 和 max lag。
- **實機驗收**：iPhone 12 Pro Max。T11～T16 逐項驗收；最後一輪用可勾選的驗收清單（https://claude.ai/artifact/ReZXPi6g2kMzXkPhnsx73V ）10/10 通過，結果寫在規格的「驗收核對記錄」。

## 待辦／已知限制

- 即時預覽（`tiny`）有嚴重的重複迴圈（「經常經常經常…」），帶不帶詞庫都有，另開分支查（可能和 `max_tokens: 64`、`audio_ctx`、關掉 temperature fallback 有關）。
- 送 prompt 後片段變長，目前精度可接受；之後若要更細的跳轉，要另外切分片段。
- `kGlossaryPromptMaxChars` 維持 80，T4 只用了 5 個詞（約一半），還沒有依據調整。
- Android 上第 ① 層和筆記在程式上沒有平台差異，但沒有實機驗證。
- 依專案分詞庫、跨會議問答留給 P2（資料模型已預留 `project_id`）。
