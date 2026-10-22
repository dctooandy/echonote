# 錄音與轉錄時螢幕不自動鎖定 規格

分支：`feature/keep-screen-awake`
狀態：已確認（2026-10-22，5 項待確認事項皆採建議答案，見文末「已確認的決定」）

開會時手機放在桌上，螢幕過一陣子就會自動鎖定；目前一鎖定，錄音就停止並存檔（`LiveEndReason.backgrounded`），等於錄到一半就斷了。錄完後的轉錄也只在前景執行，44 分鐘的會議要轉約 16 分鐘，中途自動鎖定也會停下來。

這份規格讓**錄音中和轉錄中螢幕不自動鎖定**。使用者自己按電源鍵鎖屏、切到其他 App、來電，維持現在的做法：立刻停止並存檔。

## 為什麼不做背景錄音（2026-10-22 討論）

曾評估讓 App 在鎖螢幕和背景時繼續錄音（`UIBackgroundModes: audio`），決定不做：

- **使用情境**：錄音時通常是在開會或重要場合，使用者不會刻意切到其他 App 或鎖屏；真正會發生的是**螢幕自動鎖定**，只要讓螢幕不自動熄滅就解決了。
- **來電或緊急訊息屬於意外**：當下立刻存檔、停止錄音，是合理的處理。
- **背景錄音的代價**：要處理背景時的即時文字、App 在背景被系統終止時錄音檔救不回來的風險，以及上架審查要說明背景音訊的用途。

## 現況（寫規格時查過的程式碼）

- **錄音**（`lib/screens/live_record_screen.dart`）：狀態依序是 `checkingPermission → preparing → recording → finalizing → transcribing`。iOS 原生端一進背景就送出 `BACKGROUNDED` 並結束串流（`ios/Runner/MicStreamChannel.swift`），畫面顯示「App 進入背景，錄音已停止並保存」；結束時如果不在前景，轉錄延到回到前景才開始（`_pendingTranscription`）。
- **匯入後的轉錄**（`lib/screens/import_screen.dart`）：前景顯示進度，轉錄只在前景執行。
- **重新轉錄**（`lib/screens/meeting_detail_screen.dart`）：`_isTranscribing` 期間在播放列下方顯示進度。
- 專案目前沒有任何「保持螢幕開啟」的程式或套件。

## 目標與範圍

- 以下期間螢幕**不自動鎖定**（系統的自動鎖定計時暫停）：
  - 即時錄音畫面：`preparing`、`recording`、`finalizing`、`transcribing`（等待麥克風權限的 `checkingPermission` 不算，決定 3；進入 `error` 就釋放，決定 4）。
  - 匯入錄音後的轉錄畫面：從畫面開啟到轉錄結束（含複製檔案、下載模型，這些同樣只在前景進行；2026-10-22 spec-check 修訂）。
  - 詳細頁的「重新轉錄」進行中。
- 離開這些狀態或畫面（完成、失敗、返回、放棄錄音）就恢復系統的自動鎖定。
- 使用者手動鎖屏、切到其他 App：維持立刻停止並存檔，畫面說明改成「錄音已停止並保存（鎖定螢幕或切換 App 會停止錄音）」，讓使用者知道原因。
- 來電、Siri 等中斷：維持現狀（結束並存檔，決定 #11 不變）。

**明確不做的事**：

- 背景錄音（理由見上）。
- 省電處理（錄音畫面改深色、調暗亮度）：先上線看回饋，記為之後的選項。
- App 被系統終止時救回錄音檔：前景錄音被終止的機率很低，記為之後的項目。
- 鎖定畫面或動態島上的錄音控制。

## API 異動

App 內部新增「保持螢幕開啟」的開關，iOS 對應 `UIApplication.shared.isIdleTimerDisabled`，Android 對應視窗的 `FLAG_KEEP_SCREEN_ON`。自己寫 MethodChannel `echonote/screen`（方法 `setKeepAwake(bool)`），比照 `MicStreamChannel`，不加套件（決定 1）。Dart 端用「持有者集合」合併多個畫面的需求：有任何持有者就保持開啟，全部釋放才恢復（決定 2）。

## 資料表異動

無。

## 權限與狀態機

狀態機不變，只是在上面列出的狀態期間保持螢幕開啟。不需要新的權限。

## UI／畫面

不新增元素。只改一段文字：

| 情況 | 現在 | 改成 |
|---|---|---|
| 錄音中切到背景而停止 | App 進入背景，錄音已停止並保存 | 錄音已停止並保存（鎖定螢幕或切換 App 會停止錄音） |

## 邊界案例與例外處理

- **多個畫面同時要求保持開啟**：例如錄音畫面轉錄完成後導向詳細頁，詳細頁又開始重新轉錄。以「目前還有沒有持有者」為準，每個畫面在 `dispose` 時一定釋放自己的（決定 2）。
- **詳細頁播放錄音**：不保持開啟（決定 5）。
- **畫面被系統回收或 App 當掉**：iOS 的設定只在 App 執行期間有效，App 結束後系統自動恢復，不會留下永久影響。
- **低電量模式**：iOS 在低電量模式下會把自動鎖定強制縮短為 30 秒；`isIdleTimerDisabled` 在這個模式下是否仍然有效，**要實機確認**。耗電是預期中的代價。
- **使用者在保持開啟期間手動鎖屏**：照現有流程停止並存檔；回到前景時如果還在錄音畫面，接著轉錄，轉錄期間同樣保持螢幕開啟。

## 測試接縫

- **保持開啟的狀態管理**：純 Dart 的計數或擁有者集合（暫定 `ScreenAwake`），測試「兩個需求方先後釋放，最後一個釋放才真的關閉」。平台呼叫的部分用假的實作注入。
- **畫面**：widget 測試確認錄音畫面進入 `recording` 時要求保持開啟、離開畫面時釋放。匯入後轉錄、重新轉錄要跑真的 whisper，由實機驗證（2026-10-22 spec-check 修訂）。
- **實機**：iPhone 系統設定的自動鎖定調成 30 秒，錄音 2 分鐘不碰手機，確認螢幕沒熄、錄音沒停；轉錄期間同樣不熄；結束後回到首頁放著，30 秒後正常自動鎖定。

---

## 任務拆解

2026-10-22 初版：依本規格（決定 1～5）與現有程式碼（三個畫面的轉錄／錄音狀態、`AppDelegate.swift`、`MainActivity.kt`）拆解。全部屬於「可獨立進行」軌道；專案沒有 `CLAUDE.md`。

**第一批可以開工**：T1
**建議做法**：依序做（共 3 張，一條直線）

- [x] **T1 保持螢幕開啟的開關＋原生通道**
  - 做完能看到：`ScreenAwake` 記錄持有者，有任何一個就不自動鎖定，全部釋放才恢復；iOS、Android 接上系統設定
  - 被誰卡住：無，可以直接開工
  - 主要會動的檔案：`lib/services/screen_awake.dart`（新）、`ios/Runner/AppDelegate.swift`、`android/app/src/main/kotlin/com/example/echonote/MainActivity.kt`、`test/services/screen_awake_test.dart`（新）
  - 軌道：可獨立進行
  - 驗收：
    - [x] 第一個持有者加入時打開、最後一個釋放時關閉；同一個持有者重複加入或釋放不影響
    - [x] 平台呼叫失敗（例如測試環境沒有原生端）不會丟例外
    - [x] `flutter test`、`flutter analyze`、`flutter build ios` 通過
  - 2026-10-22 完成。iOS 的 channel 寫在 `AppDelegate.swift` 裡（新增 Swift 檔要改 Xcode 專案檔，不值得）；Android 寫在 `MainActivity.kt`。平台呼叫排成佇列依序執行，最後要求的狀態為準；呼叫失敗只記 log，下一次變化時重試。`flutter build ios`、`flutter build apk --debug` 都通過。

- [x] **T2 三個畫面接上開關，並修改停止說明**
  - 做完能看到：即時錄音從 `preparing` 到轉錄完成都不自動鎖定，`error` 或離開畫面就恢復；匯入後轉錄、詳細頁重新轉錄期間也不鎖定；錄音因切到背景停止時顯示「錄音已停止並保存（鎖定螢幕或切換 App 會停止錄音）」
  - 被誰卡住：T1
  - 主要會動的檔案：`lib/screens/live_record_screen.dart`、`lib/screens/import_screen.dart`、`lib/screens/meeting_detail_screen.dart`、對應的 widget 測試
  - 軌道：可獨立進行
  - 驗收：
    - [x] 各狀態的持有／釋放符合「目標與範圍」，`dispose` 一定釋放
    - [x] 說明文字已更新
    - [x] `flutter test`、`flutter analyze` 通過
  - 2026-10-22 完成。錄音畫面的狀態改成經過 setter，每次切換狀態都同步開關，不用在每個 `_Phase` 賦值處各寫一次。匯入畫面從開啟就持有，失敗時釋放；詳細頁只在重新轉錄期間持有（`finally` 釋放）。新增 3 個錄音畫面 widget 測試（錄音中持有、離開釋放；放棄錄音釋放；切到背景停止時顯示新說明，錄音太短進入 `error` 也釋放），全部 145 個通過。匯入和重新轉錄要跑真的 whisper，沒寫 widget 測試，留給 T3 實機確認。

- [x] **T3 📱 實機驗證**
  - 做完能看到：自動鎖定 30 秒的設定下，錄音和轉錄期間螢幕不熄、結束後恢復；低電量模式的行為；結果寫回本規格
  - 被誰卡住：T2
  - 主要會動的檔案：本規格文件
  - 軌道：可獨立進行（需要使用者本人在 iPhone 上操作）
  - 驗收：
    - [x] 錄音 2 分鐘不碰手機，螢幕沒熄、錄音沒停
    - [x] 轉錄期間螢幕不熄
    - [x] 回到首頁放著，30 秒後正常自動鎖定
    - [x] 低電量模式下重測一次並記錄結果
  - 2026-10-22 完成（iPhone 12 Pro Max，使用者）。錄音、錄音後轉錄、匯入後轉錄、手動鎖屏停止並顯示新說明都正常；**低電量模式下 `isIdleTimerDisabled` 仍然有效**，螢幕不熄。
  - 詳細頁從右上角選單「重新轉錄」，第一次測試時超過 30 秒螢幕就鎖定了（測試前沒有鎖屏或切換 App）；加上記錄後重測，沒有再出現。程式碼的持有、釋放時機都正確（開始轉錄前持有，`finally` 才釋放），原因不明，記為已知問題。第一次測試時鎖定的當下，轉錄是不是已經跑完，無法確認。

## 待確認事項

無。

## 已確認的決定（2026-10-22）

| # | 問題 | 決定 |
|---|---|---|
| 1 | 自己寫還是用套件 | 自己寫 MethodChannel，iOS `isIdleTimerDisabled`、Android `FLAG_KEEP_SCREEN_ON` |
| 2 | 多個需求方怎麼合併 | 持有者集合，有任何一個就保持開啟，全部釋放才恢復；`dispose` 時一定釋放 |
| 3 | 等待麥克風權限時要保持開啟嗎 | 不用，從 `preparing` 開始 |
| 4 | 錄音出錯停在錯誤訊息時 | 不用，進入 `error` 就釋放 |
| 5 | 詳細頁播放錄音時 | 這次不做 |

## 驗收核對記錄

### 2026-10-22

**結論**：實作符合規格，有 2 項小落差（使用者決定改規格配合實作，已修訂），另有 1 個實機上沒有重現的問題。

✅ 一致：
- **原生通道**：`echonote/screen` 的 `setKeepAwake(bool)`，iOS 設定 `isIdleTimerDisabled`（`ios/Runner/AppDelegate.swift` 的 `makeScreenAwakeChannel`），Android 加上或清除 `FLAG_KEEP_SCREEN_ON`（`MainActivity.kt` 的 `configureFlutterEngine`）。沒有加套件（決定 1）。
- **持有者集合**：`lib/services/screen_awake.dart` 的 `hold`／`release`／`isOn`，有任何一個持有者就保持開啟。三個畫面的 `dispose` 都會釋放（決定 2）。
- **錄音畫面**：`_awakePhases` 包含 preparing、recording、finalizing、transcribing。`checkingPermission`、`permissionDenied`、`error` 會釋放（決定 3、4）。狀態一律透過 `_phase` 的 setter 切換（`live_record_screen.dart`）。
- **詳細頁**：只在 `_retranscribe` 期間持有，播放錄音時不持有（決定 5）。
- **停止說明**：`LiveEndReason.backgrounded` 改成「錄音已停止並保存（鎖定螢幕或切換 App 會停止錄音）」。來電等中斷的說明不變。
- **手動鎖屏後回到前景**：等待轉錄的期間停在 `finalizing`，仍然持有；開始轉錄後切到 `transcribing`，持續持有。

⚠️ 落差：
1. **匯入畫面持有的範圍比規格寫的大**：規格寫「轉錄進行中」才持有，實作是從畫面開啟就持有（`initState`），包含複製檔案、下載模型。這些步驟同樣只在前景執行，比較可能是規格寫得太窄。建議把規格改成「匯入畫面開啟到轉錄結束」。
2. **測試接縫**：規格寫「轉錄畫面在轉錄期間保持開啟」要有 widget 測試，但匯入和重新轉錄都要跑真的 whisper，所以沒寫，改由 T3 實機驗證。建議規格改成「匯入、重新轉錄由實機驗證」。

❓ 規格未涵蓋：無。

📱 已知問題：詳細頁重新轉錄有一次超過 30 秒螢幕就鎖定，重測沒有重現（見 T3）。

