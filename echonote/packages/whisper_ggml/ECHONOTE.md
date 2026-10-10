# whisper_ggml（echonote 內建版本）

- 來源：pub.dev `whisper_ggml` 2.4.0（MIT，見 `LICENSE`），上游 https://github.com/sk3llo/whisper_ggml
- 保留 Dart（`lib/`）、iOS（`ios/`）與 Android（`android/`）；`pubspec.yaml` 加上 `publish_to: none`。原生原始碼只有一份，放在 `ios/Classes/`；Android 的 `android/CMakeLists.txt` 直接編譯那一份（CocoaPods 只能引用 `ios/` 以內的檔案，CMake 沒有限制）。上游 2.4.0 的 Android 另有一份 whisper.cpp，沒有收進來。Android 只編 arm64-v8a。
- echonote 的修改都在這個資料夾之後的 commit，標註 `[echonote]`。規格與量測結果見
  `docs/specs/feature-native-mic-stream/`。
- 即時串流的 PCM16 → float 改由 `echo_core` 的 `PcmFloatBuffer` 執行（`pubspec.yaml` 因此依賴 `../echo_core`），見 `docs/specs/feature-echo-core-w2/`。
