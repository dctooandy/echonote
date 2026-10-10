# vad_eval

比較兩種人聲偵測（VAD）在實際錄音上的表現，每 100 ms（即時錄音的 chunk 大小）判斷一次：

| 名稱 | 實作 | 角色 |
| --- | --- | --- |
| `energy` | `echo_core` 的 `ec_vad`，演算法跟 whisper 即時串流內建的能量門檻相同 | 對照組（現況） |
| `silero` | 內建 whisper.cpp 的 Silero VAD，串流模式（chunk 之間保留 LSTM 狀態），機率 ≥ 0.5 算有人聲 | 候選 D-a |

規格：[`docs/specs/feature-echo-core-w2/`](../../docs/specs/feature-echo-core-w2/feature-echo-core-w2.md)（子項 D）。程式直接編譯 App 用的原始碼（`packages/whisper_ggml` 的 whisper.cpp、`packages/echo_core/src`），編譯參數跟 iOS podspec 相同。

## 建置與模型

```sh
./build.sh                       # 產生 build/vad_eval（第一次約 1 分鐘，之後只重編 vad_eval.cpp）
mkdir -p models && curl -L -o models/ggml-silero-v5.1.2.bin \
  https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin   # 約 885 KB
```

`build/`、`models/`、`data/*.wav` 不進 git。

## 執行

```sh
build/vad_eval models/ggml-silero-v5.1.2.bin data/quiet_speech.wav data/quiet_speech.txt
build/vad_eval models/ggml-silero-v5.1.2.bin data/quiet_speech.wav data/quiet_speech.txt --csv > out.csv
```

- 沒有標記檔：只輸出每個 chunk 的平均處理時間。
- 有標記檔：另外輸出 **recall**（標記為人聲的 chunk 有多少被判斷為人聲）與 **false-pos**（標記為非人聲的 chunk 有多少被誤判為人聲）。
- `--csv`：每個 chunk 一列（時間、標記、兩種判斷、Silero 最大機率），用來找誤判發生在哪裡。

輸入必須是 16 kHz、mono 的 WAV（echonote 即時錄音存的格式）。

## 標記檔格式

每行一段**有人聲**的區間，單位秒，以 0.5 秒為精度即可；`#` 開頭是註解。沒列到的時間都算非人聲。chunk 的中點落在區間內就算人聲。

```text
# quiet_speech.wav
0.5 4.0
6.5 12.0
```

## 評估素材（決定 #D5）

用 echonote 的即時錄音功能錄 3 段，每段 30～60 秒：

1. `quiet_speech`：安靜環境說話，中間停頓幾次。
2. `tv_only`：只有電視或音樂，沒有人在說話。
3. `speech_tv`：說話，背景開著電視。
4. `music_only`（補錄）：只有音樂／雜訊。`tv_only` 錄到的是電視對白，驗證不到非語音聲音，所以補這一段。

**電視對白是人聲**，語音型 VAD 無法分辨現場的人和電視裡的人（決定 #D4）。`tv_only` 的標記把電視對白標成非人聲，因此 Silero 在對白片段的「誤判」是預期中的已知限制；評估看的是音樂、雜訊、非語音聲音被濾掉多少。

### 從 iPhone 取出錄音

App 沒有開放檔案分享，用 `devicectl` 從 App 容器複製（裝置要解鎖並連線）：

```sh
xcrun devicectl list devices    # 找到 iPhone 的 Identifier
xcrun devicectl device copy from --device <Identifier> \
  --domain-type appDataContainer --domain-identifier com.example.echonote \
  --source Documents/recordings --destination data/
```

或在 Xcode → Window → Devices and Simulators → echonote → Download Container。

## 結果（2026-10-10）

素材：iPhone 12 Pro Max 用 echonote 即時錄音錄的 4 段，各約 20 秒（比原定的 30～60 秒短）。處理時間是 Mac M2 Pro 單執行緒。

| 素材 | 標記 | 能量門檻 | Silero |
| --- | --- | --- | --- |
| `quiet_speech` | 165 個人聲 chunk／37 個非人聲 | recall 70.9%，誤判 0% | recall 74.5%，誤判 0% |
| `speech_tv` | 205／9 | recall 83.9%，誤判 0% | recall 93.7%，誤判 0% |
| `tv_only`（電視對白） | 0／207 | 誤判 66.2% | 誤判 **93.7%** |
| `music_only` | 0／228 | 誤判 **86.0%** | 誤判 **0%**（最高機率 0.059） |
| 每 100 ms 處理時間 | | 0.2～0.3 µs | 約 200 µs（即時的 0.2%） |

**結論**

1. **非語音聲音：Silero 明顯勝出**。音樂讓能量門檻 86% 的時間都判成有聲音，會一直觸發 whisper 推論（浪費運算，也是幻覺文字的來源）；Silero 一次都沒有觸發。
2. **人聲：Silero 不比能量門檻差**，兩段說話素材的 recall 都比較高、誤判都是 0。
3. **電視對白：兩者都濾不掉，Silero 更糟**（93.7% vs 66.2%）。這是語音型 VAD 的本質，符合決定 #D4 的已知限制；要分辨現場的人和電視，需要說話者辨識或方向性收音，不在這個計畫的範圍。
4. **成本可以接受**：每 100 ms 約 200 µs（Mac），iPhone 即使慢好幾倍也遠小於即時；模型 885 KB；whisper.cpp 已經編進 App，不增加原生程式碼。

**限制**：`quiet_speech` 與 `speech_tv` 的標記是從 Silero 的判斷產生草稿、使用者聽過後確認，可能偏向 Silero；`speech_tv` 使用者幾乎整段都在說話，非人聲樣本只有 9 個。素材少（每類 1 段、約 20 秒），結論是方向性的。iPhone 上的處理時間沒有量。

**沒有實作的候選（決定 #D6，只做成本分析）**

| 候選 | 預期效果 | 成本 |
| --- | --- | --- |
| D-b：`echo_core` 加頻譜特徵（過零率、語音頻段能量比） | 能濾掉部分穩定的雜訊；音樂的頻譜跟語音重疊多，預期效果有限 | 中：要自己設計特徵與調參，沒有現成的評估基準 |
| D-c：移植 WebRTC VAD | 傳統 GMM 模型，對音樂的誤判公認比 Silero 多 | 中：移植約數千行 C、標示 BSD 授權；Silero 已經在 App 裡，沒有理由另外移植 |

**建議（第 3／4 週決定）**：把 whisper 即時串流的觸發條件改成 Silero（`whisper_vad_detect_speech_no_reset`），能量門檻保留為模型下載失敗時的備援；先在 iPhone 量處理時間。錄音畫面的音量條維持 RMS（它要表達的是音量，不是有沒有人聲）。
