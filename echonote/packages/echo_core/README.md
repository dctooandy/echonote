# echo_core

echonote 的跨平台 C 音訊核心。C 原始碼只有一份（`src/`），由 build hook 在建置時編譯給 iOS、macOS（以及之後的 Android），Dart 透過 `dart:ffi` 呼叫。綁定用 `ffigen` 從標頭檔產生，不手寫。

規格與決定紀錄：[`docs/specs/feature-echo-core/`](../../docs/specs/feature-echo-core/feature-echo-core.md)。

## 提供什麼

| Dart | C | 說明 |
| --- | --- | --- |
| `pcm16ToFloat` | `ec_pcm16_to_float` | PCM16 轉 float，範圍 [-1, 1)，與 whisper 的轉換公式相同 |
| `rms` | `ec_rms_pcm16` | 正規化 RMS 音量（0～1） |
| `waveform` | `ec_waveform_downsample` | 把一段音訊壓成固定段數的峰值，用來畫波形 |
| `EchoVad` | `ec_vad_*` | 能量門檻人聲偵測，演算法與 whisper 串流內建的門檻相同 |
| `EchoBufferedCore` | 同上 | 同樣的函式，改走「複製進 native buffer」的路徑（效能比較用） |
| `DartReference` | — | 每個函式的純 Dart 版本（測試比對與效能比較用） |

## 記憶體所有權

- **C 函式不配置記憶體、不保留傳入的指標**（`ec_vad_create` 除外）。所有 buffer 由呼叫端配置與釋放。
- **零複製（預設路徑）**：頂層函式把 Dart 的 `Int16List`／`Float32List` 位址（`.address`）直接交給 C。Dart 只允許在 **leaf call** 中這樣傳，所以所有函式都綁成 `@Native(isLeaf: true)`；代價是這些 C 函式必須很短、不能回呼 Dart，標頭檔有寫明這個約定。
- **native buffer 路徑**：`EchoBufferedCore` 用 `malloc` 配置、重複使用，不夠大才重新配置；每塊 buffer 各自掛在 `NativeFinalizer` 上，重新配置時先 `detach` 舊的再掛新的。
- **有狀態的 VAD**：`EchoVad` 持有不透明指標 `ec_vad*`，用 `NativeFinalizer` 綁定 `ec_vad_destroy`（函式位址由 ffigen 的 `symbol-address` 產生）。`dispose()` 先解除 finalizer 再釋放，所以不會重複釋放；釋放後呼叫會丟 `StateError`。同一個 `EchoVad` 只能在一個 isolate 使用。

## 建置

`hook/build.dart` 用 `native_toolchain_c` 編譯：`-std=c11 -O3 -Wall -Wextra -Werror -ffp-contract=off`。

- `-Werror`：hook 的警告平常沒人看，直接讓建置失敗。
- `-ffp-contract=off`：不讓 clang 把乘法和加法合併成一個乘加指令（FMA）。合併後捨入次數不同，結果會跟純 Dart 版本、跟其他平台差一點點；關掉之後 C、Dart、各平台逐位元相同，VAD 的判斷才能完全比對。

重新產生綁定：`dart run ffigen --config ffigen.yaml`。

## 測試

```sh
dart test   # macOS 上會由 build hook 編出 libecho_core.dylib，測試呼叫的是真的 C
```

C 與純 Dart 結果比對（`pcm16ToFloat` 要求完全相同；`rms`、`waveform` 容許 1e-6 相對誤差）、零複製與 native buffer 結果一致、邊界案例、VAD 在「安靜 → 說話 → 安靜 → 吵雜」每個 chunk 的判斷都與純 Dart 相同、`dispose` 前後的行為。App 端另有 `integration_test/echo_core_smoke_test.dart`，在 iOS 模擬器／實機上確認原生程式碼確實被打包並能執行。

## 效能比較

**工作量**：2 小時、16 kHz mono PCM16，以 100 ms（1600 個樣本）為單位呼叫 72,000 次，跟實際錄音時的呼叫粒度相同。訊號是固定種子的合成語音（2 秒有聲、1 秒近乎靜音，交替），先產生 60 秒循環使用，產生的時間不計入。每種實作先暖身 1,000 次。程式碼：[`lib/benchmark.dart`](lib/benchmark.dart)。

**編譯模式一定要是 AOT**：Mac 用 `dart build cli`，iPhone 用 profile 模式。debug（JIT）模式下，純 Dart 的數值迴圈會被即時最佳化到跟 C 差不多快，數字不能代表正式版。

```sh
# Mac
dart build cli -t bin/benchmark.dart -o build/benchmark && build/benchmark/bundle/bin/benchmark
# iPhone：Xcode → Edit Scheme → Run → Build Configuration = Profile，
#        FLUTTER_TARGET 指向 integration_test/echo_core_benchmark_test.dart 後執行；
#        或 flutter drive --profile --driver=test_driver/integration_test.dart \
#             --target=integration_test/echo_core_benchmark_test.dart（建議接 USB）
```

### 結果（每次呼叫的耗時，2026-10-08）

| 函式 | 實作 | Mac M2 Pro | iPhone 12 Pro Max | 相對純 Dart（Mac／iPhone） |
| --- | --- | ---: | ---: | ---: |
| `pcm16ToFloat` | 純 Dart | 1.30 µs | 1.49 µs | 1.0× ／ 1.0× |
| | C 零複製 | 0.31 µs | 0.87 µs | 4.3× ／ 1.7× |
| | C native buffer | 0.46 µs | 0.59 µs | 2.8× ／ 2.5× |
| `rms` | 純 Dart | 0.84 µs | 0.99 µs | 1.0× ／ 1.0× |
| | C 零複製 | 0.10 µs | 0.11 µs | 8.4× ／ 8.7× |
| | C native buffer | 0.15 µs | 0.18 µs | 5.5× ／ 5.5× |
| `waveform`（32 段） | 純 Dart | 4.51 µs | 5.23 µs | 1.0× ／ 1.0× |
| | C 零複製 | 0.19 µs | 0.16 µs | 23.5× ／ 32.2× |
| | C native buffer | 0.25 µs | 0.24 µs | 17.9× ／ 21.8× |
| `vad` | 純 Dart | 0.89 µs | 1.17 µs | 1.0× ／ 1.0× |
| | C 零複製 | 0.11 µs | 0.13 µs | 8.3× ／ 8.9× |

Mac 連跑三次，各列差異在 ±10% 以內；兩台裝置的 checksum 相同，代表結果逐位元一致。

### 每次呼叫的記憶體配置（依設計，不是量測值）

| 實作 | `pcm16ToFloat` | `rms`／`vad` | `waveform` |
| --- | --- | --- | --- |
| 純 Dart | 1 個輸出陣列 | 0 | 1 個輸出陣列 |
| C 零複製 | 1 個輸出陣列（Dart heap），native 0 | 0 | 1 個輸出陣列（Dart heap），native 0 |
| C native buffer | 1 個輸出陣列＋1 次複製進 native；native buffer 只在不夠大時配置（整個比較共 2 次） | 1 次複製進 native | 同 `pcm16ToFloat` |

### 從數據學到的

1. **C 快在 SIMD，不是快在「C」**。每個樣本各自計算的函式（`waveform`、`pcm16ToFloat`）clang 會向量化，Dart AOT 不會，差距大。
2. **累加的資料型別決定能不能向量化**。`rms` 一開始用 double 累加平方和：浮點加法換順序結果會變，編譯器只能一個一個加，C 只比 Dart 快 1.1 倍。改成 int64 累加（精確、可換順序）後，C 可以向量化，變成 8 倍；Dart 也因為整數比較便宜而變快。
3. **公平比較要用寫得合理的 Dart**。純 Dart 版原本用 `for (final s in list)`，AOT 下比索引迴圈慢約 4 倍，會把 C 的優勢灌水；改成索引迴圈後才是真正的差距。
4. **零複製不一定比較快**。Mac 上零複製一律較快；iPhone 上 `pcm16ToFloat` 的零複製（0.87 µs）卻比 native buffer（0.59 µs）慢，兩次量測都重現。兩者都會在 Dart heap 配置一個輸出陣列，差別在零複製版讓 C 直接寫進剛配置的 Dart 陣列；**原因尚未查明**。

## App 大小

| | `Runner.app`（`flutter build ios --release`） |
| --- | ---: |
| 加入 `echo_core` 前 | 41.0 MB |
| 加入後 | 41.2 MB（`echo_core.framework` 108 KB） |
