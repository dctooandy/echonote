# echo_core 第 3 週：Android 規格

分支：`feature/echo-core-w3`（從 `master` 75f6d05 開）
狀態：已確認（2026-10-10；17 項待確認事項皆採用建議，見「決定紀錄」）

四週 FFI 計畫的第 3 週（計畫頁：<https://claude.ai/artifact/9j2LTabW7yRuLDZ1YU12KR>；前兩週規格：[`../feature-echo-core/`](../feature-echo-core/feature-echo-core.md)、[`../feature-echo-core-w2/`](../feature-echo-core-w2/feature-echo-core-w2.md)）。目標是讓 echonote 在 Android 上跑通「匯入錄音 → 轉錄」與「即時錄音 → 即時文字 → 轉錄」，並在過程中補上職缺分析列出的 Android NDK／JNI／CMake／Gradle 經驗。

**測試環境**：本週先用模擬器（AVD `Pixel_6a` 與 `flutter_emulator`，皆為 arm64-v8a、Android 13／API 33、Google Play 映像）。Android 實機 2026-10-12（週一）才能用，所有效能數字與實機回歸都排在實機到手之後。Silero 接進 App 排在第 4 週（2026-10-10 使用者決定）。

## 現況（寫規格時查到的）

| 項目 | 現況 |
| --- | --- |
| `echo_core` | build hook（`hook/build.dart`）用 `native_toolchain_c` 編譯，Android 會由同一個 hook 產生 `.so`，但沒驗證過。C 用到 `sqrt`（`echo_core.c:30`、:78），Android 可能要明確連結 `libm` |
| `whisper_ggml`（內建版本） | 只保留 iOS 與 Dart；`pubspec.yaml` 的平台只有 `ios`。上游 2.4.0（pub cache）有 Android 建置：`android/build.gradle` + `android/src/whisper/CMakeLists.txt`，編一份自己的 whisper.cpp 和 `main.cpp`。上游 `main.cpp` 跟上游 iOS 的 `whisper_flutter_plus.cpp` 只差 include 路徑；但我們的 iOS 版本已經有 echonote 的修改（串流參數、metrics、audio_ctx 等） |
| Dart 端載入原生庫 | `whisper_live.dart`／`whisper.dart` 在 Android 已經是 `DynamicLibrary.open('libwhisper.so')`，不用改 |
| 麥克風串流 | 只有 iOS：`ios/Runner/MicStreamChannel.swift`（MethodChannel `echonote/mic`：`getPermissionStatus`、`requestPermission`、`start`、`stop`、`openSettings`；EventChannel `echonote/mic/pcm`；錯誤碼 `PERMISSION_DENIED`、`ALREADY_RUNNING`、`AUDIO_SESSION_ERROR`、`FORMAT_UNSUPPORTED`、`INTERRUPTED`、`BACKGROUNDED`）。Dart 端 `MicStreamService` 與平台無關 |
| Firebase | `lib/main.dart:9` 啟動時呼叫 `Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)`；`firebase_options.dart` 在 Android 直接丟 `UnsupportedError`，所以 **App 在 Android 上一啟動就崩潰** |
| 離線轉錄的格式轉換 | `ffmpeg_kit_flutter_new_min` 2.1.0 的 Android 要求 `minSdk 24`；App 的 `minSdk` 用 `flutter.minSdkVersion` |
| App 圖示 | `flutter_launcher_icons` 設定 `android: false` |

## 目標與範圍

### A. `echo_core` 在 Android 上編譯與執行

- 驗證 build hook 在 Android（arm64-v8a）產生 `libecho_core.so` 並被打包進 APK。需要時在 hook 加 `libraries: ['m']`（只對 Android 生效，或確認其他平台不受影響）。
- `integration_test/echo_core_smoke_test.dart` 在模擬器上通過。
- 效能比較（`echo_core_benchmark_test`）在模擬器上能跑，但**數字不寫進 README**，開發紀錄只提「模擬器可執行」；實機到手後再量（決定 #A1）。

### B. `whisper_ggml` 加回 Android 建置

- 從上游 2.4.0 取回 `android/`（`build.gradle`、`settings.gradle`、`AndroidManifest.xml`、`CMakeLists.txt`），標 `[echonote]` 修改。
- **CMake 改成編譯 `ios/Classes/` 底下同一份** `whisper/`（whisper.cpp v1.9.1）與 `whisper_flutter_plus.cpp`，不放第二份原始碼：把 `ios/Classes/` 的 `whisper/`、`json/`、`whisper_flutter_plus.cpp` 搬到套件根目錄的 `src/`，iOS podspec 與 Android CMake 都指向它（決定 #B1）。搬完後 iOS 模擬器與 iPhone 都要重新建置並回歸（決定 #R6）。這樣 iOS 與 Android 共用 echonote 的所有修改（串流參數、metrics、`audio_ctx`、`commit_sec`）。
- 輸出名稱維持 `libwhisper.so`（Dart 端已經這樣載入）。
- `pubspec.yaml` 的 `flutter.plugin.platforms` 加上 `android: ffiPlugin: true`。
- ABI：只編 `arm64-v8a`；32 位元與 x86 不支援（決定 #B2）。
- `ECHONOTE.md` 更新：不再是「只保留 iOS」。

### C. Android 麥克風串流（Kotlin）

新增 `android/app/src/main/kotlin/.../MicStreamChannel.kt`，在 `MainActivity` 註冊，**跟 iOS 用同一組 channel 名稱、方法、參數、錯誤碼**，讓 `MicStreamService` 與上層完全不用改。

| 方法／事件 | Android 做法 |
| --- | --- |
| `getPermissionStatus` | `RECORD_AUDIO` 已授權 → `granted`；沒授權且從沒問過 → `undetermined`；拒絕過且 `shouldShowRequestPermissionRationale` 為 true → `denied`；拒絕過且為 false → `permanentlyDenied`。「有沒有問過」存在 `SharedPreferences`（決定 #C1） |
| `requestPermission` | `ActivityCompat.requestPermissions`，在 `onRequestPermissionsResult` 回傳 bool |
| `start` | `AudioRecord`，來源 `VOICE_RECOGNITION`，實機再跟 `MIC` 比較（決定 #C2），16 kHz、mono、PCM16；每 100 ms（3200 bytes）送一個 chunk 到 EventChannel。錄音在背景執行緒讀取，送事件時切回主執行緒 |
| `stop` | 停止並釋放 `AudioRecord`，結束 EventChannel 串流 |
| `openSettings` | 開啟 App 資訊頁（`ACTION_APPLICATION_DETAILS_SETTINGS`） |
| 錯誤 | 沒權限 → `PERMISSION_DENIED`；已在錄 → `ALREADY_RUNNING`；`AudioRecord` 初始化失敗 → `AUDIO_SESSION_ERROR`；裝置不支援 16 kHz → `FORMAT_UNSUPPORTED`，降頻列待辦（決定 #C3）；失去音訊焦點（來電等）→ `INTERRUPTED`；App 進入背景（`onStop`）→ `BACKGROUNDED` |

- `AndroidManifest.xml` 加 `RECORD_AUDIO`。
- 不做背景錄音（不開 foreground service），跟 iOS 一致：進背景就結束。

### D. JNI 範例

讓 Kotlin **不透過 Flutter**，經由 JNI 呼叫同一份 `echo_core` C 原始碼，跟 dart:ffi、Swift 並列成第三種包裝。

- 新增 JNI 橋接 C 檔（例如 `echo_core_jni.c`），提供 `rms`（`ShortArray` → `float`）與 VAD（`create`／`process`／`destroy`，以 `long` 保存指標）。陣列用 `GetPrimitiveArrayCritical`（不複製；期間不呼叫其他 JNI 函式，對應 dart:ffi 的 leaf call，決定 #D2）。
- 用 CMake 把 `packages/echo_core/src/echo_core.c` 與橋接檔編成獨立的 `libecho_core_jni.so`，Kotlin 端 `System.loadLibrary`。
- 放在 `packages/echo_core/android_jni/`，是獨立的 Android library，附 instrumented test（`androidTest`）在模擬器上驗證；App 不使用（決定 #D1）。
- README 的包裝對照表加上 JNI 一欄。

### E. Firebase 在 Android 上的處理

App 目前在 Android 一啟動就崩潰。處理方式：Android 上 Firebase 初始化失敗時不崩潰，轉錄照常可用；按下「分析」時顯示「Android 版尚未支援分析」，畫面不變（決定 #E1、#E2）。`flutterfire configure` 留到之後（會動到雲端專案，且 `google-services.json` 要跟 GitHub 公開前的設定檔一起處理）。

### F. Android 上跑通整個流程（模擬器）

- 匯入錄音 → 離線轉錄（base）→ 逐字稿。
- 即時錄音（模擬器的虛擬麥克風使用 Mac 的麥克風輸入，需要在模擬器設定中開啟）→ 即時文字（tiny、`audio_ctx` 768）→ 停止後離線轉錄。
- 刪除、播放等既有功能在 Android 上正常。
- 實機到手後（週一）：同樣流程回歸一次，量即時預覽的 `[live-metrics]`，以及 `echo_core` 效能比較。

**明確不做的事**：

- Silero 接進 App（第 4 週）。
- CI、sanitizer、C 單元測試（第 4 週）。
- Android 的 release 簽章、上架。（App 圖示要做，決定 #R4。）
- 背景錄音、藍牙麥克風切換、多聲道或其他取樣率。
- 效能調校：本週只求跑通，Android 的 `kLivePreviewConfig` 先沿用 iOS 的值（tiny、4 執行緒、`audio_ctx` 768、commit 15 秒，決定 #F1）。模擬器只驗證功能，不判斷跟不跟得上（決定 #R7）。
- 不改 `MicStreamService` 的 Dart 介面。

## API 異動

### 後端 API

無（Android 本週不呼叫 `analyzeMeeting`，決定 #E1）。

### `echo_core`

- `hook/build.dart`：Android 時連結 `libm`（若實測需要）。
- C 介面：無異動。
- 新增 JNI 橋接（`packages/echo_core/android_jni/`）：

```kotlin
object EchoCoreJni {
    external fun rms(samples: ShortArray): Float
    external fun vadCreate(): Long          // 0 表示配置失敗
    external fun vadProcess(handle: Long, samples: ShortArray): Boolean
    external fun vadDestroy(handle: Long)
}
```

### `whisper_ggml`（內建版本）

- 新增 `android/`；Dart API 無異動。

### App 端

- `android/app/src/main/AndroidManifest.xml`：`RECORD_AUDIO`。
- `MainActivity.kt`：註冊 `MicStreamChannel`。
- `android/app/build.gradle.kts`：`minSdk` 明確設成 24（ffmpeg kit 的要求，決定 #R1）。
- `pubspec.yaml`：`flutter_launcher_icons` 改成 `android: true`（決定 #R4）。
- `lib/main.dart`：Firebase 初始化失敗時記下狀態、不崩潰；分析入口依此顯示提示（決定 #E1、#E2）。

## 資料表異動

無。

## 權限與狀態機

麥克風權限（Android）：

```text
undetermined ──requestPermission──▶ granted
      │                              
      └──拒絕──▶ denied ──再次拒絕並勾選不再詢問（或系統判定）──▶ permanentlyDenied
                    │                                                │
                    └──requestPermission──▶ granted                  └──openSettings（使用者手動開）
```

錄音串流：`idle → start → running → (stop | INTERRUPTED | BACKGROUNDED | 錯誤) → idle`，與 iOS 相同。

## UI／畫面

無新畫面。既有畫面在 Android 上沿用 Material 預設樣式，**視覺暫定，不另做 Android 調整**。Android 上按「分析」顯示 SnackBar「Android 版尚未支援分析」（文字暫定，決定 #E2）。

## 邊界案例與例外處理

| 情境 | 處理方式 |
| --- | --- |
| 模擬器沒開虛擬麥克風 | `AudioRecord` 會讀到全 0；App 照常錄音（音量條不動），不視為錯誤。測試步驟寫明要先開啟 |
| 裝置不支援 16 kHz 錄音 | 回 `FORMAT_UNSUPPORTED`（決定 #C3） |
| 錄音中來電／其他 App 搶走音訊焦點 | 結束串流並送 `INTERRUPTED` |
| 錄音中切到背景 | 結束串流並送 `BACKGROUNDED` |
| 錄音中螢幕旋轉（Activity 重建） | `MicStreamChannel` 綁在 `FlutterEngine`，錄音不中斷；列為模擬器測試項目（決定 #R2） |
| 權限在錄音中被撤銷 | `AudioRecord.read` 回傳錯誤 → 結束串流並送 `AUDIO_SESSION_ERROR` |
| `libwhisper.so` 或 `libecho_core.so` 沒被打包 | 啟動時 `DynamicLibrary.open` 失敗；以模擬器 `integration_test` 及實際操作抓出 |
| 32 位元裝置 | 不支援（決定 #B2） |
| Firebase 未設定 | 不崩潰，分析顯示提示（決定 #E1） |

---

## 決定紀錄

17 項待確認事項皆於 2026-10-10 採用建議，內容已寫回上方各章節：

| # | 項目 | 決定 |
| --- | --- | --- |
| A1 | 模擬器效能數字 | 只在開發紀錄提一句，README 只放實機數字 |
| B1 | whisper 原始碼位置 | 搬到套件根目錄 `src/`，podspec 與 CMake 都指向它 |
| B2 | ABI | 只編 arm64-v8a |
| C1 | 記住是否問過權限 | `SharedPreferences` 布林值 |
| C2 | 錄音來源 | `VOICE_RECOGNITION`，實機再比較 `MIC` |
| C3 | 不支援 16 kHz | 回 `FORMAT_UNSUPPORTED`，降頻列待辦 |
| D1 | JNI 範例位置 | `packages/echo_core/android_jni/` 獨立 library＋instrumented test |
| D2 | JNI 陣列存取 | `GetPrimitiveArrayCritical` |
| E1 | Firebase | Android 初始化失敗不崩潰，分析停用 |
| E2 | 分析入口 | 按下顯示「Android 版尚未支援分析」 |
| F1 | 即時預覽設定 | 沿用 iOS |
| R1 | minSdk | 明確設 24 |
| R2 | 旋轉 | channel 綁 `FlutterEngine`，錄音不中斷 |
| R3 | 檔案路徑 | 沿用 |
| R4 | Android App 圖示 | 要做 |
| R5 | Swift Package 並存 | 不處理，建置時確認 |
| R6 | iOS 回歸 | 搬原始碼後 iOS 模擬器＋iPhone 重新建置並錄一次 |
| R7 | 模擬器速度 | 只驗證功能 |

## 任務拆解

> 2026-10-10 初版。依據本規格與程式碼現況拆解：`lib/main.dart:9` 是 Firebase 初始化；分析的唯一呼叫點是 `meeting_detail_screen.dart:85`；`MainActivity.kt` 目前是空的 `FlutterActivity`；上游 Android 建置在 pub cache 的 `whisper_ggml-2.4.0/android/`。專案沒有 `CLAUDE.md`。所有任務都「可獨立進行」，沒有需要外部團隊配合的項目。標 🤖 的在模擬器完成；標 📱 的需要實機（iPhone 隨時可用；Android 實機 2026-10-12 起）。

### 階段 0：讓 App 能在 Android 上啟動（必須最先完成）

- [ ] **T0.1** 🤖 Firebase：`main.dart` 用 try/catch 包住初始化，失敗時記下「分析不可用」，不崩潰；`meeting_detail_screen.dart` 的分析入口在不可用時顯示 SnackBar「Android 版尚未支援分析」。iOS 行為不變。依賴：無。
- [ ] **T0.2** 🤖 `android/app/build.gradle.kts` 的 `minSdk` 設成 24；`flutter build apk --debug` 跑一次，把所有建置錯誤列出來（預期：whisper_ggml 沒有 Android 建置、echo_core 可能缺 `libm`）。依賴：無。
- [ ] **T0.3** 🤖 `echo_core` 在 Android：視 T0.2 的結果在 hook 加 `libm`；確認 APK 內有 `lib/arm64-v8a/libecho_core.so`；`flutter test integration_test/echo_core_smoke_test.dart -d <模擬器>` 通過；`dart test`（macOS）仍通過。依賴：T0.2。

### 階段 1：whisper 的 Android 建置（最大的風險）

- [ ] **T1.1** 把 `packages/whisper_ggml/ios/Classes/` 的 `whisper/`、`json/`、`whisper_flutter_plus.cpp` 搬到 `packages/whisper_ggml/src/`（`git mv`）；podspec 改成透過 `Classes/` 內的轉接檔引用 `../src`（podspec 不接受套件外的相對路徑，沿用 `plugin_ffi` 範本的 forwarder 做法），`HEADER_SEARCH_PATHS` 同步更新；iOS 模擬器建置通過。依賴：無。
- [ ] **T1.2** 從上游取回 `android/`（`build.gradle`、`settings.gradle`、`src/main/AndroidManifest.xml`），`CMakeLists.txt` 改成編 `../src`（whisper.cpp＋`whisper_flutter_plus.cpp`），輸出 `libwhisper.so`，`abiFilters` 只留 `arm64-v8a`；`pubspec.yaml` 加 `android: ffiPlugin: true`；修改處標 `[echonote]`；`ECHONOTE.md` 更新。依賴：T1.1。
- [ ] **T1.3** 🤖 `flutter build apk --debug` 通過，APK 內有 `libwhisper.so`；模擬器上匯入一個錄音檔 → 離線轉錄（base）完成、逐字稿正確顯示；確認 `ffmpeg_kit` 的格式轉換在 Android 可用。依賴：T0.1、T0.3、T1.2。

### 階段 2：Android 麥克風串流

- [ ] **T2.1** `MicStreamChannel.kt`：MethodChannel `echonote/mic`（5 個方法）與 EventChannel `echonote/mic/pcm`；權限狀態判斷（`SharedPreferences` 記是否問過）、`requestPermission`（`onRequestPermissionsResult`）、`openSettings`；`AudioRecord`（`VOICE_RECOGNITION`、16 kHz、mono、PCM16），背景執行緒讀取、每 3200 bytes 切回主執行緒送出；錯誤碼與 iOS 相同；在 `MainActivity.configureFlutterEngine` 註冊、綁在 `FlutterEngine`；`AndroidManifest.xml` 加 `RECORD_AUDIO`。依賴：無（可與階段 1 同時做）。
- [ ] **T2.2** 中斷處理：音訊焦點遺失 → `INTERRUPTED`；`onStop` → `BACKGROUNDED`；`AudioRecord.read` 錯誤 → `AUDIO_SESSION_ERROR`；16 kHz 初始化失敗 → `FORMAT_UNSUPPORTED`。依賴：T2.1。
- [ ] **T2.3** 🤖 模擬器（先開啟虛擬麥克風使用主機音訊輸入）：權限流程（第一次詢問、拒絕、永久拒絕後前往設定）；即時錄音出現即時文字、音量條會動、停止後離線轉錄完成；錄音中切到背景會結束並保存；錄音中旋轉螢幕不中斷。依賴：T1.3、T2.2。

### 階段 3：JNI 範例

- [ ] **T3.1** `packages/echo_core/android_jni/`：獨立的 Android library（Gradle 設定與 wrapper、`CMakeLists.txt` 編 `../src/echo_core.c`＋`echo_core_jni.c`）；`echo_core_jni.c` 用 `GetPrimitiveArrayCritical` 實作 `rms`、`vadCreate`／`vadProcess`／`vadDestroy`；Kotlin `EchoCoreJni` 物件 `System.loadLibrary("echo_core_jni")`。依賴：無。
- [ ] **T3.2** 🤖 instrumented test（`androidTest`）：`rms` 對已知輸入的結果（與 Swift 測試相同的案例）、VAD「安靜→說話→安靜」、`vadCreate` 回傳非 0、`vadDestroy` 後不再使用；在模擬器用 `./gradlew connectedAndroidTest` 通過。依賴：T3.1。

### 階段 4：其他

- [ ] **T4.1** `flutter_launcher_icons` 改 `android: true` 並產生圖示；模擬器桌面確認。依賴：無。

### 階段 5：實機

- [ ] **T5.1** 📱 iPhone 回歸（T1.1 搬了原始碼）：iPhone 建置、匯入轉錄、即時錄音一次，`[live-metrics]` 與第 2 週同量級。依賴：T1.1。
- [ ] **T5.2** 📱 Android 實機（2026-10-12 起）：T1.3、T2.3 的流程各一次；即時錄音用第 2 週的朗讀稿，記錄 `[live-metrics]`；跑 `echo_core_benchmark_test`（profile）。依賴：階段 1～2。
- [ ] **T5.3** 📱 Android 實機比較 `VOICE_RECOGNITION` 與 `MIC` 的辨識效果（同一份稿子各錄一次），決定預設值。依賴：T5.2。

### 階段 6：收尾

- [ ] **T6.1** 更新 `packages/echo_core/README.md`：Android 建置說明、JNI 用法、包裝對照表加 JNI 一欄、Android 實機效能數字。依賴：T3.2、T5.2。
- [ ] **T6.2** `/spec-check`、`/devlog`，merge 進 master 並 push。依賴：全部。

### 任務摘要

- 共 18 項，全部「可獨立進行」；🤖 模擬器 6 項、📱 實機 3 項（T5.1 iPhone 隨時可做，T5.2／T5.3 等 Android 實機）。
- 關鍵路徑：T0.2 → T0.3 → T1.1 → T1.2 → T1.3 → T2.3 → T5.2。階段 2 的 T2.1／T2.2、階段 3、T4.1 可以跟階段 1 同時做。
- 週一前可完成：階段 0～4 與 T5.1。

## 待確認事項

目前無。
