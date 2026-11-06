# 統一的分享入口 開發紀錄

分支：`feature/share`
狀態：已完成（實機確認），待併入 master

詳細頁原本有五個分散的入口，只能傳文字和 HTML，LINE 還收不了 .html，原始錄音也傳不出去。這個分支改成一個「分享」，先選用途再決定送出什麼。規格：[`docs/specs/feature-share/`](../specs/feature-share/feature-share.md)。

## 目標

- 右上角「分享」→ 底部選單：傳給對方的結論、會議紀錄（PDF）、完整資料（逐字稿，可加錄音）。
- 個人筆記一律不帶；錄音預設不勾，傳之前再確認一次。
- 不上傳雲端，不改分析（不用部署、不用跑評測）。

## 目前進度與下一步

- **已完成**：App、測試、實機確認。
- **下一步**：合併說明確認後，用 `--no-ff` 併入 master 並 push。
- **之後要留意**：`Printing.convertHtml` 如果被移除，要改成自己寫 Swift 或用純 Dart 重畫 PDF；換的地方只有 `_shareMinutes` 那一行。

## 踩到的坑

### 建議方案時還沒查文件，實作才發現方法已被標為 deprecated

**現象**：`flutter analyze` 提示 `Printing.convertHtml` is deprecated。

**原因**：規格階段只憑印象建議這個方法，說了「實作前會查」，但使用者已經依這個建議做決定。

**修法**：據實回報，讓使用者重新決定。changelog 顯示它最近還修了 iOS 26 的閃退，所以先用。之後建議方案前，先查文件再給建議。

### `flutter analyze` 全過，測試卻編譯失敗

**現象**：加 `printing` 後 analyze 沒有問題，但只要 import 到它的測試檔都載入失敗：`The method 'decodeLazy' isn't defined for the type 'ZLibDecoder'`。

**原因**：傳遞相依的 `image` 升到 4.11.0，`archive` 還鎖在 4.0.9。`image` 宣告的版本範圍有包含 4.0.9，實際卻用到新版才有的方法。analyze 只分析自己的程式，不分析相依套件。

**修法**：`flutter pub upgrade archive`（4.6.0）。加套件之後要跑測試或編譯，不能只看 analyze。

### 測試找 `逐字稿` 找到分頁標題

底部選單的「逐字稿」跟分頁標題同字，改用 `find.widgetWithText(CheckboxListTile, '逐字稿')`。

## 測試方法

- `flutter test` 309 個全部通過；`flutter analyze` 沒有問題；`flutter build ios --no-codesign --debug` 成功。
- 新增的 widget 測試（`meeting_detail_export_test.dart`）：PDF 由同一份 HTML 產生、過時先問、沒分析時前兩項停用、完整資料預設只帶逐字稿、勾錄音要確認、取消不送出、找不到錄音不能勾、舊入口不見了。
- **實機**（2026-11-06，使用者）：PDF 傳到 LINE 收得到、版面正常；逐字稿和錄音都傳到了；長標題夠看。
- 測試用假的 PDF，真正的轉檔只有實機驗證過，而且只試了一場會議。

## 合併說明（2026-11-06）

範圍：整個分支

### 改了什麼

- 詳細頁右上角多一顆「分享」，先選用途：傳給對方的結論、會議紀錄、完整資料。
- 會議紀錄改成 PDF，LINE 收得到了。
- 第一次可以把原始錄音傳出去：預設不勾，傳之前再確認一次。
- 原本分散的「複製成 LINE 訊息」「匯出會議紀錄」「匯出逐字稿」都併進來；「複製摘要」「複製全部逐字稿」留在原地。

### 怎麼證明能用

- **實機**：PDF 傳到 LINE 收得到、版面正常；逐字稿和錄音都傳到了；長標題夠看。
- **測試**：App 309 個全部通過，iOS 編譯成功。
- **未驗證**：Android（目前還不支援分析）；很長的會議產生 PDF 的速度和版面。

### 出事能不能退回

**雙向門**：沒有改資料格式，也沒有動 function。`git revert` 後重裝 App 就能復原，但已經傳出去的檔案收不回來。
**影響範圍**：僅詳細頁的分享——連帶升級了 `archive`、`image` 等相依套件。
