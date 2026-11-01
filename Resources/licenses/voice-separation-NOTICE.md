# 声による話者の分離：出典とライセンス

meeting-analyzer の「話者の分離（声）」（SPEC §3.14）は、次を使います。

## モデル（利用者が「ダウンロード」を押したときだけ取得します）

- 取得先：`FluidInference/speaker-diarization-coreml`（Hugging Face。版 `df2625ac79a7ac6b65ad868fee6d80f320da4232`）。
- ライセンス：**Creative Commons Attribution 4.0 International（CC-BY-4.0）** <https://creativecommons.org/licenses/by/4.0/>
- 出典（Attribution）：
  - **pyannote** — `pyannote/speaker-diarization-community-1`（CC-BY-4.0）<https://huggingface.co/pyannote/speaker-diarization-community-1>
  - **WeSpeaker**（話者の埋め込みの ResNet34。pyannote が組み込んだもの）
  - **BUT Speech@FIT**（PLDA の定数。`plda.npz`・`xvec_transform.npz`。CC-BY-4.0）
  - **Fluid Inference**（Core ML への変換）
- **改変**：上のモデルを、Core ML へ変換したものです（入力の形の固定・混合精度・FBank の分離・コンパイル）。元のモデルそのものではありません。
- 詳細：モデルのリポジトリの `NOTICE.md`・`PROVENANCE.md`。

## 実行（FluidAudio）

- **FluidAudio**（<https://github.com/FluidInference/FluidAudio>）：Apache License 2.0。ライセンスの全文を、`FluidAudio-LICENSE` として同梱しています。
- FluidAudio が使う、`fastcluster`・`vbx` のライセンスを、`FluidAudio-fastcluster-LICENSE.md`・`FluidAudio-vbx-LICENSE.md` として同梱しています。

## 音声の扱い

声の分離のために、システム音声を、会議の間、**メモリ上だけ**に持ちます。ファイルにも、ネットワークにも出しません。会議の終了で分離したら、捨てます。
