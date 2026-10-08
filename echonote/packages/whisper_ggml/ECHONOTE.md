# whisper_ggml（echonote 內建版本）

- 來源：pub.dev `whisper_ggml` 2.4.0（MIT，見 `LICENSE`），上游 https://github.com/sk3llo/whisper_ggml
- 只保留 Dart（`lib/`）與 iOS（`ios/`）原始碼；`pubspec.yaml` 的平台只留 iOS，並加上 `publish_to: none`。
- echonote 的修改都在這個資料夾之後的 commit，標註 `[echonote]`。規格與量測結果見
  `docs/specs/feature-native-mic-stream/`。
