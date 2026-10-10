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

## 結果

（實機素材錄好後填入）
