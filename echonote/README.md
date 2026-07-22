# echonote

語音備忘 / 會議摘要助手。匯入既有的會議錄音檔，在裝置端完成語音辨識，再透過後端把逐字稿送給 Claude 產出摘要、待辦事項與結構化會議紀錄。

## 產品定位

- **v1 只做「匯入既有錄音檔」**，不做即時錄音轉錄；v1 僅支援 iOS，Android 排在第二階段。
- **語音轉文字完全在裝置端進行**（whisper.cpp），音訊本身不會離開手機。
- **只有轉錄出來的文字**會送到後端，由 Claude API 產出摘要 / 待辦 / 結構化紀錄——這同時是隱私設計（會議內容通常敏感）也是成本考量（文字比音訊便宜很多）。
- 四種輸出：**逐字稿**、**摘要**、**待辦事項清單**、**結構化會議紀錄**。

## 目前進度（2026-07-22）

**核心功能已完整跑通、實機驗證過（iPhone 12 Pro Max / iOS 26.3）：**

- [x] whisper.cpp Flutter 套件選型定案：[`whisper_ggml`](https://pub.dev/packages/whisper_ggml)（MIT 授權、維護活躍），`base` 模型定案為 v1 使用尺寸
- [x] 逐字稿與 Claude 分析輸出皆確認為純繁體中文，不需額外轉換
- [x] Firebase Cloud Functions 後端代理（`analyzeMeeting`），呼叫 Claude API（Haiku 4.5）搭配 JSON Schema 強制輸出摘要 / 待辦 / 結構化紀錄
- [x] 待辦事項與議程項目皆帶時間戳記，可點擊跳轉回原音核對正確性；播放列固定顯示在所有分頁上方，隨時可暫停
- [x] 本機歷史紀錄：轉錄與分析結果會存檔，同一筆記錄不需重複轉錄或重複呼叫 API，可手動觸發「重新分析」
- [x] 實測驗證：即使逐字稿因多人交叉發言而破碎，Claude 產出的摘要/待辦仍然準確且維持繁體中文
- [x] 正式畫面：首頁錄音列表 → 匯入進度畫面 → 會議詳情（摘要/待辦/逐字稿/結構化紀錄四分頁，待辦與與會者可編輯）
- [x] App icon

**尚未進行：**

- [ ] 視覺風格設計（目前使用 Flutter 預設 Material 主題，尚未套用品牌色彩/字體）
- [ ] 歷史紀錄刪除功能
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
