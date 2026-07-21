# echonote

語音備忘 / 會議摘要助手。匯入既有的會議錄音檔，在裝置端完成語音辨識，再透過後端把逐字稿送給 Claude 產出摘要、待辦事項與結構化會議紀錄。

## 產品定位

- **v1 只做「匯入既有錄音檔」**，不做即時錄音轉錄；v1 僅支援 iOS，Android 排在第二階段。
- **語音轉文字完全在裝置端進行**（whisper.cpp），音訊本身不會離開手機。
- **只有轉錄出來的文字**會送到後端，由 Claude API 產出摘要 / 待辦 / 結構化紀錄——這同時是隱私設計（會議內容通常敏感）也是成本考量（文字比音訊便宜很多）。
- 四種輸出：**逐字稿**、**摘要**、**待辦事項清單**、**結構化會議紀錄**。

## 目前進度（2026-07-21）

- [x] whisper.cpp Flutter 套件選型定案：[`whisper_ggml`](https://pub.dev/packages/whisper_ggml)（MIT 授權、維護活躍）
- [x] 真機 POC 驗證（iPhone 12 Pro Max / iOS 26.3）：`base` 模型速度與準確度均可接受，定案為 v1 使用的模型尺寸
- [x] 逐字稿輸出確認為純繁體中文，不需額外轉換
- [x] 逐字稿分段點擊 → 跳轉到對應時間點播放音檔
- [x] Firebase Cloud Functions 後端代理（`analyzeMeeting`），呼叫 Claude API（Haiku 4.5）搭配 JSON Schema 強制輸出摘要 / 待辦 / 結構化紀錄
- [x] 待辦事項與議程項目皆帶時間戳記，可點擊跳轉回原音核對正確性
- [x] 本機歷史紀錄：轉錄與分析結果會存檔，同一筆記錄不需重複轉錄或重複呼叫 API
- [x] 實測驗證：即使逐字稿因多人交叉發言而破碎，Claude 產出的摘要/待辦仍然準確且維持繁體中文
- [ ] 正式 UI/UX 設計（目前畫面僅為驗證技術可行性的陽春介面）
- [ ] App icon（等視覺設計確定後一併製作）
- [ ] Android 版本（第二階段）

## 技術架構

| 項目 | 選擇 |
|---|---|
| 前端框架 | Flutter（iOS） |
| 語音轉文字 | whisper.cpp（透過 `whisper_ggml`），完全裝置端執行 |
| 音訊播放 | `just_audio` |
| 後端 | Firebase Cloud Functions（TypeScript） |
| LLM | Claude API（`claude-haiku-4-5`），透過 Anthropic SDK + `output_config` JSON Schema 強制結構化輸出 |
| 本機儲存 | 逐字稿與分析結果以 JSON 存於裝置本機 |

## Getting Started

這是一個 Flutter 專案。

```
flutter pub get
flutter run
```

Cloud Functions 部署於 `functions/` 目錄，需要先設定 Firebase 專案並透過 Secret Manager 設定 `ANTHROPIC_API_KEY`：

```
firebase functions:secrets:set ANTHROPIC_API_KEY --project echonote-64428
firebase deploy --only functions --project echonote-64428
```
