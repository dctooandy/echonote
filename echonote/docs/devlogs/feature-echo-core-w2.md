# echo_core 第 2 週：whisper 餵資料、audio_ctx、零複製調查、VAD 評估、Swift 包裝 開發紀錄

分支：`feature/echo-core-w2`
狀態：第 2 週完成（2026-10-10）

把第 1 週做好的 `echo_core` 接進 whisper 即時串流的資料路徑，用實機數據調校即時預覽，查第 1 週留下的「零複製反而比較慢」，評估只對人聲觸發辨識的 VAD，並讓同一份 C 原始碼多一種 Swift 包裝。規格：[`docs/specs/feature-echo-core-w2/`](../specs/feature-echo-core-w2/feature-echo-core-w2.md)；第 1 週紀錄：[`feature-echo-core.md`](feature-echo-core.md)。

## 目標

- A：whisper worker 的 PCM16 → float 改用 `ec_pcm16_to_float`，去掉每個 chunk 一次的 `malloc`／`free`。
- B：即時預覽加入 `audio_ctx`（encoder 處理的音訊長度），用 iPhone 實測決定預設值。
- C：查 iPhone 上 `pcm16ToFloat` 零複製比 native buffer 慢的原因。
- D：評估 Silero VAD 與現有能量門檻，產出比較報告，不接進 App。
- E：SwiftPM 版的 `echo_core` 包裝，對照 dart:ffi 的指標與資源管理方式。

## 踩到的坑

### 一、FFI 的規則

#### `stream_feed` 不能直接拿 Dart 的記憶體

**現象**：原本想讓 whisper 的輸入也走零複製，直接把轉好的 `Float32List` 交給 `stream_feed`。

**原因**：Dart 只允許在 **leaf call** 裡把 Dart heap 的位址（`.address`）交給 C。`stream_feed` 會跑 whisper 推論（數百 ms），不能宣告成 leaf，期間 GC 可能搬動 Dart 物件。

**修法**：拆成兩半。轉換（`ec_pcm16_to_float`）是 leaf call，輸入可以零複製；輸出寫進 `PcmFloatBuffer` 持有、重複使用的 malloc buffer，再把這塊 native 指標交給 `stream_feed`。

#### 讀不到 Dart 陣列的位址

**現象**：H2 要統計新配置的 `Float32List` 是不是 16 bytes 對齊，`list.address.address` 被 analyzer 擋下：`The '.address' expression can only be used as argument to a leaf native external call`。先用 `lookupFunction(..., isLeaf: true)` 綁 `memmove`，再包進一個一般的 Dart 函式、把 `.address` 傳給它，一樣被擋。

**原因**：`.address` 不是一般的值，只能**直接**寫在 leaf 原生呼叫的參數位置；傳給一般 Dart 函式就不行。

**修法**：宣告一個 `@Native` leaf 綁定 libc 的 `memmove`，呼叫 `memmove(p, p, 0)`：長度 0 不碰記憶體，回傳值就是 `p`。

### 二、audio_ctx 調校

#### 依視窗動態調整 audio_ctx 會陷入重複迴圈

**現象**：動態模式（每次推論依視窗長度算 `audio_ctx`）中位數耗時從 1809 ms 降到 658 ms，但預覽文字變成一長串「有一個字，有一個字……」，還夾雜簡體字。

**原因**：每次推論的 `audio_ctx` 都不同（177～1377）。即時預覽為了速度關掉了 temperature fallback（`noFallback`），模型一旦開始重複，就沒有重新解碼的機會打斷迴圈。是 `audio_ctx` 變動造成不穩定還是單純太小，沒有再拆開驗證。

**修法**：不採用動態模式。改用固定 768（約 15 秒），commit 視窗同時縮短成 15 秒：中位數 1809 → 516 ms、最大落後 4.8 → 1.0 秒，文字品質使用者評為三組中最好。設成 `kLivePreviewConfig` 預設值。

#### 加速有一部分來自視窗變短

**現象**：固定 768 組的中位數視窗是 9.0 秒，基準組是 14.6 秒。

**原因**：固定的 `audio_ctx` 只涵蓋 15 秒，commit 視窗必須跟著從 25 秒降到 15 秒，兩個變數一起改了。

**修法**：結果照實記錄，沒有另外量「`audio_ctx` 0＋commit 15」把兩者拆開；採用門檻（中位數降 20% 以上且文字沒變差）以組合為單位判斷。

#### 切換設定不想改程式碼

**現象**：規格原本打算每量一組就改 `kLivePreviewConfig` 重新建置，容易改錯或忘記改回。

**修法**：`audioCtx`、`commitSec` 用 `int.fromEnvironment` 讀 `--dart-define`。因為沒有 const 的 `double.fromEnvironment`，`LivePreviewConfig.commitSec` 改成整數秒，傳給套件時再轉 `double`。另外加了 debug 建置限定的 `[live-metrics]` 摘要，錄音結束時印出中位數和預覽全文，不用從 console 抄 log。

### 三、零複製調查

#### 第 1 週的反常沒有重現

**現象**：第 1 週 iPhone 上零複製 0.87 µs、native buffer 0.59 µs，兩次都重現。這週加了 H1～H3 變體重量，零複製 0.49 µs、native buffer 0.54 µs，跟 Mac 一樣是零複製比較快。

**原因**：**沒有查明**。已知的差別只有執行方式：第 1 週在 Xcode 用 Profile 設定跑，這週用 USB 加 `flutter drive --profile`。依決定 #C1（時間上限一輪）沒有再回頭驗證。

**修法**：README 改寫成目前能證明的結論：配置輸出陣列（0.31 µs）佔了大半，轉換本身只要 0.13 µs；新配置的 `Float32List` 1000 次都是 16 bytes 對齊，故意錯開 4 bytes 只慢 0.03 µs，對齊排除。

#### Mac 第一次執行的數字是離群值

**現象**：Mac 第一次跑，零複製和 native buffer 都是 0.55 µs；後兩次是 0.31 和 0.46 µs。

**修法**：Mac 連跑三次，排除第一次，規格記錄的是後兩次的範圍。

### 四、VAD 評估

#### 評估程式的巨集被 shell 吃掉引號

**現象**：`build.sh` 編 whisper.cpp 時報 `invalid suffix '.1' on floating constant`，指向 `return WHISPER_VERSION;`。

**原因**：`-DWHISPER_VERSION="1.9.1"` 經過 `eval` 後引號被剝掉，巨集變成數字 `1.9.1`。

**修法**：在 `DEFS` 字串裡寫成 `\"1.9.1\"`，`eval` 展開後才是 C 字串。

#### Silero 的視窗不能在串流中間補零

**現象**：Silero 以 512 個樣本為一個視窗，一個 100 ms chunk 是 1600 個樣本，不是整數倍。`whisper_vad_detect_speech_no_reset` 遇到不足一個視窗的尾巴會補零。

**修法**：每次只送 512 的整數倍，剩下的樣本留到下一個 chunk，串流中不補零。

#### 電視素材錄到的是對白，驗證不到非語音聲音

**現象**：`tv_only` 上 Silero 誤判 93.7%，比能量門檻（66.2%）更糟。

**原因**：電視在播對白，對白本來就是人聲，語音型 VAD 分辨不了現場的人和電視（規格決定 #D4 的已知限制）。這段素材回答不了「能不能濾掉音樂、雜訊」。

**修法**：補錄 20 秒只有音樂的 `music_only`：能量門檻誤判 86.0%，Silero 0%（最高機率 0.059）。結論因此成立：Silero 能濾掉非語音聲音，濾不掉電視對白。

#### 標記草稿會偏向 Silero

**現象**：為了省人工，標記從 Silero 的判斷產生草稿再請使用者確認；`speech_tv` 的草稿是整段（因為 Silero 連電視一起判成人聲），沒有參考價值。

**修法**：使用者確認 `quiet_speech` 草稿可用、`speech_tv` 幾乎整段都在說話；報告註明標記可能偏向 Silero、`speech_tv` 的非人聲樣本只有 9 個、素材每類一段約 20 秒，結論是方向性的。

#### `devicectl` 的裝置 ID 跟 Flutter 的不一樣

**現象**：拿 `flutter devices` 的 ID（`00008101-…`）給 `xcrun devicectl device copy from` 找不到裝置。

**原因**：Flutter 用的是裝置 UDID，`devicectl` 用的是 CoreDevice 的 Identifier（`BC5C89A2-…`），兩者不同。

**修法**：先 `xcrun devicectl list devices` 查 Identifier；`tool/vad_eval/README.md` 已寫明。

## 測試方法

- **`echo_core` 單元測試**：`cd packages/echo_core && dart test`（20 項）。新增 `PcmFloatBuffer`：結果與 whisper worker 舊迴圈逐位元相同、buffer 只在需要時變大、空輸入回 `nullptr`、`dispose` 前後。
- **Swift**：`cd packages/echo_core && swift test`（6 項：邊界案例、VAD 安靜→說話→安靜、`deinit` 釋放）；`xcodebuild -scheme EchoCore -destination 'generic/platform=iOS Simulator' build`。
- **App**：`flutter test`（11 項）；每次改動後 `flutter build ios --simulator --debug`。
- **效能比較**：Mac `dart build cli` AOT 跑三次；iPhone 12 Pro Max 用 USB 跑 `flutter drive --profile --target=integration_test/echo_core_benchmark_test.dart`。結果在 `packages/echo_core/README.md`。
- **即時預覽調校**：iPhone 12 Pro Max、debug 建置（whisper C++ 固定 `-O3`），同一份 521 字朗讀稿，三組設定各錄一次，讀 `[live-metrics]` 摘要；文字品質由使用者目視比較。
- **A 的回歸**：即時錄音時文字持續出現、停止後離線轉錄完成、紀錄正常保存（使用者確認）。
- **VAD**：`tool/vad_eval/build.sh` 後，對 4 段實機素材跑 `build/vad_eval <模型> <wav> <標記>`；先用 `say` 合成的中文語音做冒煙測試。

## 待辦／已知限制

- 第 3／4 週：把即時串流的觸發條件改成 Silero，能量門檻當模型下載失敗時的備援；先量 iPhone 上 Silero 的處理時間（目前只有 Mac 的約 200 µs／100 ms）。
- 電視對白無論哪種 VAD 都濾不掉，要分辨需要說話者辨識或方向性收音，不在計畫範圍。
- 沒有拆開「`audio_ctx` 768」和「commit 15 秒」各自貢獻多少加速；有需要時加量一組 `LIVE_AUDIO_CTX=0 LIVE_COMMIT_SEC=15`。
- 動態 `audio_ctx` 的重複迴圈是 `audio_ctx` 變動還是太小造成，沒有驗證；參數保留但不建議使用。
- 第 1 週零複製反常的原因未查明（可能與執行方式有關）。
- VAD 素材每類只有一段約 20 秒，標記可能偏向 Silero。
- 第 3 週 Android、第 4 週 C 單元測試／ASan／CI 照原計畫；JNI 範例、CI 是先前職缺分析列的補強項目。
- GitHub 公開前處理 Firebase 設定檔（使用者決定之後再做）。
