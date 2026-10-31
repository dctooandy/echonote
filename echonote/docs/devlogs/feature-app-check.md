# 分析服務防盜用（App Check＋呼叫上限）開發紀錄

分支：`feature/app-check`
狀態：已完成（已部署到正式環境、實機驗收通過、`/spec-check` 落差已處理），待併入 master

這個分支讓 Cloud Function `analyzeMeeting` 只接受從 EchoNote App 發出的呼叫，並限制每天的呼叫次數，避免拿到 Firebase 設定檔的人直接呼叫 function、用掉 Anthropic 額度。起因是 2026-10-30 討論 Anthropic 開源的資安參考範本時，回頭檢查 echonote 發現的風險。規格：[`docs/specs/feature-app-check/`](../specs/feature-app-check/feature-app-check.md)。

## 目標

- `analyzeMeeting` 強制檢查 App Check。目前只用免費 Personal Team，所以所有 build 都用 debug provider，token 用 `--dart-define-from-file=app_check.local.json` 帶入（決定 18）。
- 每天全部裝置合計 50 次，以台北時間切換日期，用 Firestore transaction 計數；`maxInstances: 3`。
- App 依錯誤種類顯示中文訊息。
- 最後一道防線：Anthropic Console 每月上限 US$10，用量到 50% 時通知（手動設定）。

## 目前進度與下一步

- **已完成**：T1～T5、U1 全部完成（見規格的「任務拆解」）。function 已經以 `enforceAppCheck: true` 部署；Firestore 規則已經發布。
- **還沒 commit**：斷網訊息的修正（`lib/services/analysis_errors.dart`、對應測試）、規格的 spec-check 紀錄、這份 devlog。
- **下一步**：commit 上面這些 → 寫合併說明（`/merge-notes`）→ 用 `--no-ff` 併入 master 並 push。
- **之後的路線**（2026-10-30 討論定案）：跨會議記憶（手動選「接續哪一場」，只送前 1～3 場的結構化紀錄）→ 分析評測集 → 會議紀錄匯出成 HTML → 評估換成 Haiku 5.5。
- **要上架時**：改成 App Attest（需要付費 Apple Developer Program、加 entitlement、App ID 開啟 App Attest），另開分支。

## 踩到的坑

### 一、部署與建置

#### 加入 `firebase_app_check` 後，pod install 說「需要更高的最低 iOS 版本」

**現象**：`flutter pub add firebase_app_check` 之後，`flutter build ios` 在 pod install 失敗，訊息是 `The pod "Firebase/Functions" required by the plugin "cloud_functions" requires a higher minimum iOS deployment version`。但最低版本 15.6 其實符合要求。

**原因**：加套件時，`firebase_core` 從 4.12.1 被升到 4.15.2，它需要 Firebase iOS SDK 12.19；但 `cloud_functions` 還停在 6.3.5，`Podfile.lock` 也還鎖著 `Firebase/Functions` 12.15.0。兩個版本衝突，CocoaPods 卻把它說成部署版本的問題。

**修法**：`flutter pub upgrade cloud_functions`（升到 6.5.1），再執行 `pod update Firebase FirebaseCore FirebaseFunctions --repo-update`。之後又遇到 `'FLTFirebaseCorePlugin' has different definitions in different modules`，原因是舊的 module 快取，刪掉 `build/ios` 再建置就好。

#### Node.js 20 剛好在部署當天停用

**現象**：`firebase deploy` 失敗，訊息是 `Runtime Node.js 20 was decommissioned on 2026-10-30`。

**原因**：`functions/package.json` 的 `engines.node` 是 `"20"`，Google 在部署當天停用了這個執行環境。

**修法**：改成 `"22"`（commit `2161423`），測試、建置通過後重新部署。

### 二、App Check

#### SDK 印出的 debug token 跟我們帶進去的不一樣

**現象**：實機 Profile 啟動時，log 印出 `Firebase App Check debug token: 9F2792B7-…`，跟 `app_check.local.json` 裡的值不一樣，看起來像是 `--dart-define` 沒有生效。

**原因**：iOS SDK 啟動時，會印出它自己產生、存在手機上的 token，不管有沒有指定自訂 token。實際送出的是 `AppleDebugProvider(debugToken:)` 指定的那個。證據：只記錄、不擋的版本 log 顯示 `App Check ok`；改成強制檢查之後實機照常分析，而 `9F2792B7-…` 從來沒有登記過。

**修法**：不用改程式。判斷有沒有生效，要看 function 有沒有放行，不要看這行 log。這點已經寫進規格的邊界案例。

#### 刪掉 debug token 之後，App 照樣能分析

**現象**：驗收第 ③ 項，在 Console 刪掉 debug token 之後，實機的分析仍然成功。

**原因**：App Check token 在手機上會快取大約 1 小時，過期之前不需要向 Firebase 換發。刪掉 debug token，只會讓下一次換發失敗。

**修法**：這項驗收跳過。curl 不帶 token 會得到 `401 UNAUTHENTICATED`，已經證明沒有 token 會被擋；token 用 `npx firebase-tools@latest appcheck:debugtokens:create` 登記回去，因為本機的 firebase CLI 14.17 沒有這個指令。

### 三、錯誤訊息

#### 斷網時顯示英文的「分析失敗：the internet connection appears to be offline」

**現象**：實機開飛航模式分析，沒有出現規格寫的「網路連線有問題」。

**原因**：iOS 的 `cloud_functions` 外掛只轉換 `com.firebase.functions` domain 的錯誤（`FirebaseFunctionsPlugin.swift` 的 `createFlutterError`），iOS 網路錯誤（`NSURLErrorDomain`）一律變成 `unknown`，訊息是 iOS 的英文系統文字。規格假設斷網的錯誤碼是 `unavailable`，這個假設錯了。

**修法**：`analysisErrorMessage()` 的 `unknown` 也顯示「網路連線有問題，請稍後再試」，後面附上原始訊息，讓少見的非網路錯誤也查得到原因；加上單元測試。順帶確認了 function 的 `details` 會經由外掛的 `additionalData` 原封不動傳到 Dart，所以每日上限的判斷確實是靠 `details.reason`。

### 四、Console 設定的位置（跟原本預期不同）

- Firestore 建立畫面改成用「Standard／Enterprise 版」區分，Standard 就是一般的 Firestore；資料庫 ID 要保留 `(default)`，程式用 `getFirestore()` 連的是它。
- TTL 政策不在 Firebase Console，要到 Google Cloud Console → Firestore → 存留時間。
- App Check 不用選「Debug 提供者」，直接在 App 那一列的 ⋮ →「管理偵錯權杖」登記。
- Anthropic API 的上限在 Claude Console（platform.claude.com）→ 管理 → 支出限額 →「前往組織設定」，不是 claude.ai 訂閱方案的用量頁。

---

## 測試方法

- **自動化**：
  - `flutter test` 204 個全部通過，`flutter analyze` 沒有問題，`flutter build ios --no-codesign` 通過。新增 7 個錯誤訊息對照的測試（`test/services/analysis_errors_test.dart`）。
  - `functions/` 第一次有測試：`npm test`（`node:test`，用 `tsconfig.test.json` 編譯到 `build-test/`），3 個測試涵蓋上限判斷和台北時間的日期切換。
- **線上手動驗收**（2026-10-30～31，iPhone 12 Pro Max，Profile）：
  1. curl 不帶 token：只記錄的版本 log 顯示 `App Check missing`，請求被格式檢查擋下；強制檢查後回 `401 UNAUTHENTICATED`。
  2. 實機在只記錄的版本 log 顯示 `App Check ok (1:218763541305:ios:…)`；強制檢查後照常分析。
  3. 刪掉 token 被擋：跳過，原因見上面的坑。
  4. 在 Console 把 `usage_daily/2026-10-31.count` 改成 50，實機顯示「今天的分析次數已用完，明天再試」，之後改回原本的數字。
  5. 飛航模式：修正前顯示英文訊息，修正後的對應已經有單元測試（實機尚未重測）。

## 待辦／已知限制

- 只有 debug provider：debug token 外洩的話，任何人都能通過 App Check，只剩每日上限擋著。外洩時到 Console 刪掉，換一個新的。
- 模擬器跑不起來：`ffmpeg_kit_flutter_new_min` 不支援 arm64 模擬器，這是原本就有的問題。
- 斷網訊息修正後，還沒在實機重測。
- 計數失敗回 `unavailable`，App 會顯示「網路連線有問題」，跟實際原因不完全一樣，可以接受。
