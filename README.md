# meeting-analyzer

会議の**音声**と**画面**を Mac の中で分析し、コーディングエージェントへ渡す macOS のメニューバーアプリ。会議が終わると、エージェントへ**終了の合図**を送り、エージェントがプロジェクトの内容を元に、会議の**詳細なサマリー**を出す。

- 自分の声（マイク）と、相手の声（会議アプリの音声）を分けて取り込み、Mac のオンデバイスの音声認識で文字にする。**音声は保存も送信もしない。**
- ブラウザにも会議サービスにも依存しない。Meet・Teams・Zoom（デスクトップ版を含む）など、Mac で音が出るものが対象。拡張機能は要らない。
- 連携するエージェント：Claude Code、omp、pi、agy、opencode v2。

前身の [live-support](https://github.com/takemo101/live-support-channel)（Chrome 拡張で字幕を読む）の仕様を踏襲し、入力を「字幕」から「Mac の音声」へ置き換える。得るもの：サービス内部の仕様への非依存、自分と相手の確実な区別、拡張機能との競合がないこと。失うもの：相手が複数人のとき、誰の発言かの区別（相手は「相手」にまとまる）。

## 状況（v0.1.0・開発の初期）

製品要件と実装の状況は、[SPEC.md](SPEC.md) の §8 が正本。いまできること：

| できる | まだ |
|---|---|
| 音声ファイルを日本語で文字起こしする（`transcribe`）。この Mac で使えるかの確認（`doctor`） | **マイクの取り込み、システム音声の取り込み、画面の取り込み**（SPEC §3.3・§3.5） |
| 音声ファイルを会議として再生し、バッチと終了の合図を、ブリッジへ送る（`replay`）。記録を `transcript.md` に書く | メニューからの開始・一時停止・終了、同意の確認の画面 |
| メニューバーに常駐する（状態の表示と終了だけ） | 各エージェントでの連携（live-support 側の変更が先に要る。SPEC §3.7）。サマリーの出力 |

実会議・実機のマイクやシステム音声での確認は、まだ済んでいない（[検証手順と記録](docs/verification.md)）。

## 必要なもの

- macOS 26 以降、Apple silicon。Swift 6（Xcode または Command Line Tools）。外部パッケージはない。
- 開発用：`just`（任意。なければ `scripts/` を直接実行）。E2E には、`node`（偽のブリッジ）と、`say` の日本語の声 Kyoko も使う。

## ビルドと実行

```sh
just build          # build/MeetingAnalyzer.app（Apple silicon、ad-hoc 署名）
just run            # メニューバーのアプリとして起動する（Dock・ウィンドウには出ない）
just test           # 単体テスト（Swift Testing）
just e2e            # 実機の native E2E（CLI・本物の音声と認識・偽のブリッジ・起動と終了）
```

## CLI

アプリと同じ実行ファイルに引数を付けると、CLI になる（ウィンドウは出ない）。

```sh
EXE=build/MeetingAnalyzer.app/Contents/MacOS/MeetingAnalyzer
$EXE doctor                              # {"installed":true,"locale":"ja_JP","supported":true}
$EXE transcribe sample.aiff              # 確定した結果を 1 行 1 件の JSON で出す
$EXE replay sample.aiff --bridge http://127.0.0.1:43821 --meeting 定例
$EXE --help
```

- 失敗は、標準エラーの 1 行の JSON と、終了コード（1 使い方・2 入力・3 ブリッジ・4 文字起こし）で返す。
- ブリッジのトークンは、エージェント側が置く `~/.live-support/token` から読む（`--token-dir` で変更）。コマンドラインの引数では受け取らない。送り先は `http://127.0.0.1:<ポート>` だけ。

## プライバシー

- 音声は、ファイルにもネットワークにも出さない（メモリ上で処理して捨てる）。外へ出るのは、文字と、（後続で）画面の画像で、ローカルのブリッジ経由でエージェントへ渡る。エージェントの提供元（例：Anthropic）へ送られうる。
- 会議の記録（`transcript.md`）は、`~/Library/Application Support/MeetingAnalyzer/sessions/<id>/` に、利用者だけが読める権限で書く。
- 取り込みの開始には、参加者の同意・組織の規程・送信先のデータ取扱いの確認が要る（実装は後続。SPEC §3.10）。

## ドキュメント

[docs/README.md](docs/README.md) が入口。製品要件は [SPEC.md](SPEC.md)、作業規約は [AGENTS.md](AGENTS.md)、構成は [docs/architecture.md](docs/architecture.md)、検証は [docs/verification.md](docs/verification.md)、エージェント向けのサマリーの手順は [skills/meeting-analyzer/SKILL.md](skills/meeting-analyzer/SKILL.md)。

## ライセンス

MIT（[LICENSE](LICENSE)）。
