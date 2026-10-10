# echo_core 第 3 週：Android 開發紀錄

分支：`feature/echo-core-w3`
狀態：模擬器階段完成（2026-10-10）；Android 實機項目（T5.2、T5.3）待 2026-10-12

讓 echonote 在 Android 上跑通「匯入 → 離線轉錄」與「即時錄音 → 即時文字 → 離線轉錄」，同時補上 Android NDK／JNI／CMake／Gradle 的第一手經驗。規格：[`docs/specs/feature-echo-core-w3/`](../specs/feature-echo-core-w3/feature-echo-core-w3.md)；前一週：[`feature-echo-core-w2.md`](feature-echo-core-w2.md)。

## 目標

- A：`echo_core` 由 build hook 編給 Android，並在模擬器上執行。
- B：`whisper_ggml` 加回 Android 建置，跟 iOS 共用同一份原始碼（含 echonote 的串流修改）。
- C：Kotlin 版麥克風串流 `MicStreamChannel.kt`，channel、方法、錯誤碼跟 iOS 完全相同，Dart 不改。
- D：JNI 範例：Kotlin 不透過 Flutter 呼叫同一份 `echo_core.c`，跟 dart:ffi、Swift 並列成第三種包裝。
- E：Firebase 尚未設定 Android，App 一啟動就崩潰；改成不崩潰、分析顯示「Android 版尚未支援分析」。
- F：模擬器上跑完整流程；實機數據週一補。

## 踩到的坑

### 一、Gradle 與建置

#### AGP 9 下 file_picker 和其他套件的 Kotlin 設定互相衝突

**現象**：第一次 `flutter build apk` 失敗：`GeneratedPluginRegistrant.java: cannot find symbol FilePickerPlugin`。把 `android.builtInKotlin` 改成 `true` 之後，換 audio_session 失敗：`The 'org.jetbrains.kotlin.android' plugin is no longer required for Kotlin support since AGP 9.0`。

**原因**：App 用 AGP 9.0.1，Flutter 範本在 `gradle.properties` 設了 `android.builtInKotlin=false`。file_picker 11.0.2 在 AGP ≥ 9 時不套 Kotlin 外掛、改靠 AGP 內建 Kotlin，內建 Kotlin 被關掉，它的 Kotlin 原始碼就沒被編譯。反過來打開內建 Kotlin，audio_session、cloud_functions 等仍套 Kotlin 外掛的套件會被 AGP 9 拒絕。兩種設定不可能同時成立。

**修法**：AGP 從 9.0.1 退到 8.13.0（`android/settings.gradle.kts`）。AGP 8 下 file_picker 會自己套 Kotlin 外掛，其他套件不受影響；`builtInKotlin` 維持 `false`。另外用 `strings` 確認 `MainActivity`、`MicStreamChannel` 確實編進 APK 的 dex。

#### 以為 echo_core 要連結 libm，結果不用

**現象**：規格預期 `sqrt` 需要在 hook 加 `libraries: ['m']`，但 APK 第一次就建置成功。

**原因**：用 NDK 的 `llvm-readelf` 檢查，三種 ABI 的 `libecho_core.so` 都只有 `libc`、`libdl` 兩個相依、沒有未解析的 `sqrt`：clang 在 `-O3` 下把 `sqrt` 直接編成 CPU 指令。

**修法**：hook 不改。「建得過」不等於「執行時找得到符號」，所以用 `readelf` 查相依與未解析符號，而不是只看建置結果。

#### CocoaPods 不能引用 `ios/` 以外的原始碼

**現象**：決定 #B1 原本是把 whisper 原始碼搬到套件根目錄 `src/`，讓 podspec 和 CMake 都指向它。動手時發現 podspec 的 `source_files` 不能引用 podspec 所在目錄（`ios/`）以外的檔案。

**原因**：CocoaPods 的限制；Flutter 舊版 `plugin_ffi` 範本用「`ios/Classes/` 放轉接檔、內容只有一行 `#include "../../src/x.c"`」繞過去。whisper.cpp 有 30 個 `.c`／`.cpp`，就要 30 個轉接檔。

**修法**：修訂 #B1：原始碼留在 `ios/Classes/`，Android 的 `android/CMakeLists.txt` 直接引用那裡（CMake 沒有路徑限制）。規則是「限制最嚴的建置系統擁有原始碼」。上游 whisper_ggml 的做法是兩份一模一樣的 whisper.cpp，我們不採用（echonote 改過的串流參數只會改到一份）。長期解法是改用 build hook（echo_core 的做法，根本沒有這個問題），列為第 4 週候選。

#### CMake 的建置快取被 commit 進去

**現象**：whisper Android 的 commit 裡多了一堆 `android/.cxx/Release/...` 檔案。

**原因**：AGP 把 CMake 的中間產物放在模組目錄的 `.cxx/`，而 `packages/whisper_ggml/android/` 是新目錄，沒有 `.gitignore`。

**修法**：`git rm --cached` 後 amend，加 `android/.gitignore`（`/.cxx/`、`/build/`）。JNI library 一開始就把 `.cxx/` 列進 `.gitignore`。

### 二、模擬器

#### 模擬器空間不夠裝 APK

**現象**：`INSTALL_FAILED_INSUFFICIENT_STORAGE`。

**原因**：debug APK 220 MB（ffmpeg 的原生庫占大部分），`Pixel_6a` 的 `/data` 只剩 746 MB，上面還裝著使用者其他專案的 6 個 App。

**修法**：不動那些 App，改用另一台 AVD `flutter_emulator`（剩 4.4 GB）。

#### 模擬器的離線轉錄非常慢

**現象**：10 秒音檔的 base 轉錄約 1.5 分鐘、22 秒錄音約 5 分鐘，畫面長時間停在「準備中」。

**原因**：用 `top -H` 看到 4 個 whisper 執行緒接近滿載，不是卡住；`flutter_emulator` 只有 1.5 GB RAM、4 核，App 占 687 MB，swap 已用 647 MB。iPhone 上同一個模型只要錄音長度的 0.37 倍時間。

**修法**：照決定 #R7，模擬器只驗證功能；效能等 Android 實機。使用者決定不調大 AVD。

#### 模擬器麥克風收到的是環境聲音

**現象**：即時預覽出現一長串「切成，切成……」之類的幻覺文字。

**原因**：用 `adb emu avd hostmicon` 讓模擬器麥克風使用 Mac 的輸入，收到的是房間裡的雜音。

**修法**：用 Mac 的 `say -v Meijia` 念一段會議稿，喇叭聲由 Mac 麥克風收進模擬器；即時預覽辨識出「各位早安，我們開始今天的周會……」，確認整條路是通的。

### 三、麥克風權限

#### 「僅限這次」過期後被誤判為永久拒絕

**現象**：測試時權限被授予「僅限這次」。檢查邏輯時發現：權限過期或在系統設定撤銷後，系統其實還會再跳詢問，但原本的判斷會回報 `permanentlyDenied`，直接叫使用者去設定頁。

**原因**：Android 沒有「從沒問過」這個狀態。原本用「是否問過（存在 `SharedPreferences`）＋ `shouldShowRequestPermissionRationale` 為 false」判斷永久拒絕；但 rationale 在「從沒拒絕過」時也是 false，所以過期或撤銷後也會落入同一個判斷。

**修法**：只在「我們自己的請求被拒絕，而且當下 rationale 為 false」時記一個旗標，用旗標判斷永久拒絕；其他沒授權的情況，rationale 為 true 回報 `denied`，否則回報 `undetermined`。錄音畫面在 `denied` 時也再請求一次（iOS 不會回報 `denied`，不受影響）。

#### 重測權限流程要先把狀態重置乾淨

**現象**：測試時權限被誤點授予，要重測「第一次詢問」需要回到從沒問過的狀態；`pm clear` 會連 147 MB 的模型一起刪掉。

**修法**：`adb shell pm revoke … RECORD_AUDIO`、`pm clear-permission-flags … user-set user-fixed`，再用 `run-as` 刪掉 `shared_prefs/echonote_mic.xml`。之後由使用者實際點權限視窗，我截圖確認每一步。

### 四、JNI

#### JNI 的陣列存取方式要對應 leaf call 的約定

**現象**：JNI 有兩種讀 Java 陣列的方法：`GetShortArrayElements`（可能複製）和 `GetPrimitiveArrayCritical`（通常不複製，但期間不能呼叫其他 JNI 函式、必須很短）。

**修法**：用 `GetPrimitiveArrayCritical`，`Release` 時傳 `JNI_ABORT`（唯讀、不用寫回）。這跟 dart:ffi 的 leaf call、Swift 的 `withUnsafeBufferPointer` 是同一個約定：C 函式很短、不回呼、不保留指標。`ec_vad*` 以 `jlong` 交給 Kotlin；Kotlin 沒有確定性的解構，`EchoVad` 實作 `AutoCloseable`，用 `use { }` 釋放，對應 Dart 的 `dispose()`。

## 測試方法

- **建置**：`flutter build apk --debug`；用 `unzip -l` 確認 APK 內有 `lib/arm64-v8a/libecho_core.so` 與 `libwhisper.so`；用 NDK 的 `llvm-readelf -d`／`--dyn-syms` 確認相依函式庫與匯出符號（`request`、`stream_start`、`stream_feed`、`stream_stop`）。
- **echo_core 冒煙測試**：`flutter test integration_test/echo_core_smoke_test.dart -d emulator-5554` 通過。
- **JNI**：`cd packages/echo_core/android_jni && ./gradlew connectedAndroidTest`，4 項通過（`rms` 已知值、VAD「安靜→說話→安靜」、`close` 兩次後使用丟例外、handle 為 0 時安全）。
- **模擬器實際操作**（`flutter_emulator`，arm64、Android 13）：用 `adb shell input tap` 操作、`adb exec-out screencap` 截圖確認每一步：
  - 匯入合成中文語音 → 下載 base 模型 → ffmpeg 轉檔 → 繁體逐字稿正確；播放正常；分析顯示「Android 版尚未支援分析」。
  - 即時錄音：音量條會動、即時文字出現；旋轉螢幕不中斷；按 Home 鍵後停止並保存、接著離線轉錄。
  - 權限五步驟（使用者操作）：拒絕 → 再問 → 再拒絕 → 不再問 → 前往設定開啟 App 資訊頁 → 允許後可直接錄音。
- **iOS 回歸**：iOS 模擬器建置、`flutter test`（11 項）、`dart test`（20 項）；iPhone 12 Pro Max 即時錄音 `[live-metrics]` 中位數 481 ms、最大落後 0.8 秒（第 2 週 516 ms／1.0 秒），分析正常產出。

## 待辦／已知限制

- **2026-10-12（Android 實機）**：T5.2 匯入與即時錄音回歸、用第 2 週的朗讀稿量 `[live-metrics]`、跑 `echo_core_benchmark_test`（profile）；T5.3 比較 `VOICE_RECOGNITION` 與 `MIC`；T6.1 README 補 Android 建置、JNI 用法與實機數字；T6.2 spec-check、merge、push。
- 只支援 arm64-v8a；32 位元與 x86 裝置上 `libwhisper.so` 不存在（`libecho_core.so` 有三種 ABI）。
- 裝置不支援 16 kHz 錄音時回 `FORMAT_UNSUPPORTED`，沒有降頻（決定 #C3）。
- Android 不能分析：Firebase 尚未設定 Android（`flutterfire configure` 會動到雲端專案，要跟 GitHub 公開前的設定檔一起處理）。
- AGP 退到 8.13.0；Flutter 已警告「未來版本會讓套用 Kotlin 外掛的套件建置失敗」，等 audio_session、cloud_functions 等套件支援內建 Kotlin 後要再升回 AGP 9。
- 第 4 週候選：whisper 改用 build hook（排在 CI 與 Silero 之後）。
