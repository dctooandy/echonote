# echo_core 第 1 週：跨平台 C 音訊核心 開發紀錄

分支：`feature/echo-core`
狀態：第 1 週完成（待併入 master；第 2–4 週接續）

建立 echonote 自己的 C 音訊核心 `echo_core`：自己設計 C 介面、用 `ffigen` 產生 `dart:ffi` 綁定、自己管理 Dart 與 C 之間的記憶體，並用 AOT 實測數據比較純 Dart 與 C。這是四週 FFI 計畫的第 1 週（計畫頁：<https://claude.ai/artifact/9j2LTabW7yRuLDZ1YU12KR>），目的是補上前一個分支（即時錄音）缺的 FFI 第一手經驗。規格：[`docs/specs/feature-echo-core/`](../specs/feature-echo-core/feature-echo-core.md)。

## 目標

- `packages/echo_core`：一份 C 原始碼，由 build hook 編給 iOS 與 macOS（之後是 Android）。
- C 函式：PCM16 轉 float、RMS、波形降採樣、能量門檻 VAD（有狀態、不透明指標）。
- Dart 兩條呼叫路徑：零複製（`.address` + leaf call）與重複使用的 native buffer；`NativeFinalizer` 管理釋放。
- 純 Dart 參考實作 + 測試比對；Mac 與 iPhone 12 Pro Max 的 AOT 效能比較寫進套件 README。
- 錄音畫面加上即時音量條，證明 `echo_core` 在 iPhone 實機上執行。

## 踩到的坑

### 一、建置與工具鏈

#### `plugin_ffi` 範本已被棄用

**現象**：計畫頁原本寫用 podspec（`plugin_ffi`）。`flutter create --help` 顯示 `plugin_ffi` 已標為 deprecated，建議改用 `package_ffi`。

**原因**：Flutter 改用 build hooks（native assets）編譯原生程式碼，C 由 `hook/build.dart` + `native_toolchain_c` 在建置時編譯，iOS、Android、macOS 都走同一套機制。

**修法**：改用 `package_ffi`，第一個任務先驗證它能跟用 podspec 的 `whisper_ggml` 並存（macOS `dart test`、iOS 模擬器 `integration_test`、iPhone 實機 release 建置都通過）。附帶好處：`dart test` 會自動編出 macOS 的 `libecho_core.dylib`，測試直接呼叫真的 C。範本附帶的 `example/`（六個平台的完整 App）刪掉，以 echonote 本身當範例。

#### 原生產物最低版本是 13.0，不是 App 的 15.6

**現象**：`vtool -show-build` 顯示 `echo_core.framework` 的 `minos 13.0`，規格原本要求對齊 15.6。

**原因**：Flutter 傳給 build hook 的是它自己的最低支援版本，不是 App 的 deployment target。

**修法**：接受 13.0 並修訂規格。App 本身要求 15.6，裝得起來的裝置一定能跑；強行在 `flags` 再塞一個 `-mios-version-min` 等於跟工具鏈打架。

#### `ffigen` 對 `ec_vad` 報「找不到定義」

**現象**：產生綁定時出現 `No definition found for declaration ... struct ec_vad` 警告。

**原因**：`ec_vad` 刻意只在 `.c` 裡定義，標頭只有 `typedef struct ec_vad ec_vad;`，這正是不透明型別的寫法。

**修法**：不用修。ffigen 正確產生 `final class ec_vad extends ffi.Opaque`。

### 二、讓 C 與 Dart 結果完全一致

#### clang 的乘加合併讓 C 與 Dart 差一點點

**現象**（設計時發現）：VAD 的 `noise_floor += rate * (rms - noise_floor)` 在 `-O3` 下可能被合併成一個 FMA 指令，只捨入一次；純 Dart 版分兩步捨入，判斷可能在門檻附近不同。

**原因**：clang 預設允許浮點運算合併（`-ffp-contract=on`）。

**修法**：hook 加 `-ffp-contract=off`；純 Dart 的 VAD 在 C 用 float 運算的每一步都用 `Float32List` 捨入一次。測試裡「安靜 → 說話 → 安靜 → 吵雜」120 個 chunk 的判斷與 C 完全相同；iPhone 與 Mac 的效能比較 checksum 也逐位元一致。

### 三、效能比較（大部分的坑在這裡）

#### 無線 `flutter drive` 等了 10 分鐘找不到 App

**現象**：`flutter drive --profile` 對無線連線的 iPhone 建置、安裝都成功，但 `Did not find a Dart VM Service advertised`，620 秒後失敗。

**原因**：無線除錯要靠區域網路探索 App 的 VM Service；可能是手機鎖著、區域網路權限，或無線連線本身不穩。**實際是哪一個沒有確認**。

**修法**：改由使用者在 Xcode 執行（Edit Scheme → Run → Build Configuration = Profile），`Generated.xcconfig` 的 `FLUTTER_TARGET` 已指向效能比較的 `integration_test`。之後要用 `flutter drive` 建議接 USB。

#### debug 模式的數字看起來「C 沒有比較快」

**現象**：第一次在 Xcode 執行，`rms` 純 Dart 1.64 µs、C 1.56 µs，幾乎一樣快，跟 Mac 上的 AOT 結果（4 倍差距）對不上。

**原因**：Xcode 的 Run 預設是 Debug 設定，Dart 是 JIT 執行。JIT 會依實際型別即時最佳化數值迴圈，純 Dart 因此快很多。在 Mac 上用 `dart run`（JIT）重現了同樣的模式（純 Dart 1.45 µs）。

**修法**：效能比較一律 AOT：Mac 用 `dart build cli` 編成執行檔，iPhone 用 profile 模式。寫進規格與 README。

#### `for-in` 讓純 Dart 在 AOT 下慢了 4 倍

**現象**：Mac AOT 下 `rms` 純 Dart 5.69 µs、C 1.32 µs，看起來 C 快 4.3 倍。

**原因**：純 Dart 參考實作用 `for (final s in samples)` 走訪 `Int16List`，AOT 編譯成透過 iterator 的呼叫，比索引迴圈慢很多。這是比較對象寫得不好，不是語言差距。

**修法**：純 Dart 改成索引迴圈後，`rms` 變成 1.43 µs，跟 C（1.34 µs）只差 1.1 倍。公平比較的前提是 Dart 那邊要寫得合理。

#### double 累加讓 C 無法向量化

**現象**：修正寫法後，`rms` 與 VAD 的 C 只比 Dart 快 1.1 倍；同時 `waveform` 快 24 倍、`pcm16ToFloat` 快 4 倍。

**原因**：`rms` 把平方加進一個 double 總和，每次加法都依賴前一次，而浮點加法換順序結果會變，clang 不能重排成 SIMD 平行計算。`waveform`、`pcm16ToFloat` 每個樣本各自計算，clang 會向量化，Dart AOT 不會。

**修法**：C 與 Dart 都改成 **int64 累加 `s * s`**（每個平方 ≤ 2^30，兩小時的總和遠小於 int64 上限）。整數加法可以換順序，C 因此能向量化：`rms` 從 1.34 → 0.10 µs，相對純 Dart 8.4 倍（iPhone 8.7 倍）；結果也從「逐步捨入」變成精確，C 與 Dart 逐位元相同。

#### 兩小時的測試資料放不進手機記憶體

**現象**（設計時發現）：2 小時 16 kHz PCM16 約 230 MB；先產生好再量，記憶體吃緊，產生時間也可能混進量測。

**修法**：產生 60 秒合成訊號，切成 100 ms chunk 循環使用，呼叫 72,000 次（等於 2 小時的量）；每種實作先暖身 1,000 次。

#### iPhone 上零複製反而比 native buffer 慢

**現象**：iPhone profile 模式下，`pcm16ToFloat` 零複製 0.87 µs、native buffer 0.59 µs，兩次都重現；Mac 上則是零複製較快，其他函式在 iPhone 上也是零複製較快。

**原因**：**未查明**。兩者都會在 Dart heap 配置一個 1600 個 float 的輸出陣列，差別在零複製版讓 C 直接寫進剛配置的 Dart 陣列，native buffer 版則是 C 寫進 native 記憶體再複製出來。

**修法**：尚未處理，記在 README。第 2 週改寫 whisper 的餵資料介面時會面對同樣的「資料怎麼在 Dart 與 C 之間移動」問題，到時一起查。

### 四、App 整合

#### 音量條也會對電視聲音反應

**現象**：實機錄音時，說話音量條約到一半，但電視的聲音也會讓它動。

**原因**：RMS 量的是所有聲音的能量，不區分人聲；VAD 也是能量門檻，同樣會把電視當成有人說話。這是設計本質，不是錯誤。

**修法**：第 1 週不處理。是否改成只對人聲反應（例如依頻譜特徵判斷的 VAD），留到第 2 週評估。

---

## 測試方法

- **單元測試**：`cd packages/echo_core && dart test`（16 項）。C 與純 Dart 比對（`pcm16ToFloat` 完全相同，`rms`／`waveform` 容許 1e-6 相對誤差）、零複製與 native buffer 結果一致、-32768、帶 offset 的 view、空輸入、`buckets` 邊界、buffer 只在需要時變大、VAD 逐 chunk 與純 Dart 相同、`dispose` 前後行為、C 與 Dart 預設值一致。
- **iOS 冒煙測試**：`flutter test integration_test/echo_core_smoke_test.dart -d <模擬器>`，確認原生程式碼被打包並能執行。
- **效能比較**：Mac `dart build cli -t bin/benchmark.dart -o build/benchmark && build/benchmark/bundle/bin/benchmark`；iPhone 用 Xcode 的 Profile 設定執行 `integration_test/echo_core_benchmark_test.dart`。結果與方法見 `packages/echo_core/README.md`。
- **編譯參數**：從 `.dart_tool/hooks_runner/.../stdout.txt` 確認實際編譯命令含 `-std=c11 -O3 -Wall -Wextra -Werror -ffp-contract=off`。
- **App 大小**：`flutter build ios --release --no-codesign`，41.0 → 41.2 MB（`echo_core.framework` 108 KB）。
- **實機**：錄音時音量條隨說話變化；即時預覽、轉錄、播放與加入 `echo_core` 前相同（使用者確認）。

## 待辦／已知限制

- 第 2 週：用 `ec_pcm16_to_float` 改寫 whisper worker 的 int16 → float 迴圈與每次 `malloc`／`free`、新增 `audio_ctx`；同時查 iPhone 上零複製較慢的原因。
- 音量條與 VAD 是否改成只對人聲反應，第 2 週評估。
- 無線 `flutter drive` 失敗的確切原因未確認；之後用 USB 再試。
- 第 3 週 Android：`package_ffi` 已產生 Android 建置設定但未驗證；Android 的 `libm` 連結可能需要在 hook 加 `libraries: ['m']`（`sqrt`）。
- 第 4 週：C 端單元測試、AddressSanitizer、CI。
- GitHub 公開前處理 Firebase 設定檔（使用者決定之後再做）。
