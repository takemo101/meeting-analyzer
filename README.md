# meeting-analyzer

Mac の**音声**（マイクと、Mac から出ている音）を、Mac の中で文字にして、Claude Code などのコーディングエージェントへ**ライブで転送**する macOS のメニューバーアプリ。終わると、エージェントへ**終了の出来事**を渡し、エージェントがプロジェクトの内容を元に、**詳細なサマリー**を出せる。

- 取り込む音声を選ぶ：**マイク**（あなた）と、**システム音声**（相手。Mac から出ている音の全体、または選んだアプリ）。Mac のオンデバイスの音声認識で文字にする。**音声は保存も送信もしない。**
- 特定のサービスに依存しない。Mac で音が出るもの（会議・動画・通話）が対象。ブラウザの拡張機能は要らない。
- このプロジェクト単体で完結する。エージェントへ渡す受け口は、同じ実行ファイルの MCP サーバー（`meeting-analyzer mcp`）。Claude Code・omp・pi・agy・opencode など、MCP を使えるエージェントに登録する。

```
アプリ（メニューバー）── Unix ドメインソケット ──> meeting-analyzer mcp（MCP）──> エージェント
```

失うもの：相手が複数人のとき、誰の発言かの区別（相手は「相手」にまとまる）。

## 状況（v0.1.0・開発の初期）

製品要件と実装の状況は、[SPEC.md](SPEC.md) の §8 が正本。いまできること：

| できる | まだ |
|---|---|
| メニューバーのアプリから、取り込む音声（マイク・システム音声の全体またはアプリ）を選び、同意を確認して、開始・一時停止・再開・終了する。オンデバイスで文字にし、エージェントへ渡す窓口（Unix ドメインソケット）へ流し、記録を書く | **画面の取り込み**（SPEC §3.5）、自動終了。エコーの疑いは、メニューでヘッドホンを案内する（検出の当たりは未確認） |
| エージェント側の MCP サーバー（`mcp`）：`get_events`（pull。Claude Code で実機確認済み）、`--channel`（push。Claude Code の Channels。実機では未確認）。メニューから、登録コマンドをコピー | omp・agy・opencode での確認（pi は接続まで確認済み） |
| 音声ファイルの文字起こし（`transcribe`）・再生（`replay`）・この Mac で使えるかの確認（`doctor`） | |

マイク・システム音声の実取り込み（権限を含む）と、メニューからの開始〜終了の操作は、実機での人間の確認がまだ済んでいない（[検証手順と記録](docs/verification.md)）。

## 必要なもの

- macOS 26 以降、Apple silicon。Swift 6（Xcode または Command Line Tools）。外部パッケージはない。
- 開発用：`just`（任意。なければ `scripts/` を直接実行）。E2E には、`say` の日本語の声 Kyoko も使う。

## ビルドと実行

```sh
just build          # build/MeetingAnalyzer.app（Apple silicon、ad-hoc 署名）
just run            # メニューバーのアプリとして起動する（Dock・ウィンドウには出ない）
just install        # ~/Applications へ入れる（INSTALL_DIR で変更。実行中の同じアプリは、終了して置き換える）
just test           # 単体テスト（Swift Testing）
just e2e            # 実機の native E2E（CLI・本物の音声と認識・窓口と MCP・起動と終了）
```

## 使い方

### 1. エージェントに、MCP サーバーを登録する（一度だけ）

メニューの「エージェントに登録（コピー）」から、実行ファイルのパスを入れたコマンドをコピーして、ターミナルで実行できる（Claude Code・pi・agy・opencode・omp）。手で書くときは、次のとおり。

実行ファイルは `build/MeetingAnalyzer.app/Contents/MacOS/MeetingAnalyzer`（以下 `$EXE`。絶対パスで登録する）。MCP サーバーは、標準入出力で話す stdio のサーバーで、コマンドは `$EXE mcp`。

```sh
# Claude Code（ツール get_events で受け取る）
claude mcp add meeting-analyzer -- "$EXE" mcp

# Claude Code で、字幕を自動で押し込む（Channels。開発用の許可が要る）
claude mcp add meeting-analyzer-channel -- "$EXE" mcp --channel
claude --dangerously-load-development-channels server:meeting-analyzer-channel
```

pi（`pi mcp add meeting-analyzer -- "$EXE" mcp`）・agy（`agy mcp add …`）・opencode（`opencode mcp add --global …`）も、同じ形で登録できる。omp は `~/.omp/agent/mcp.json` に stdio サーバーを足す。**確認済みなのは、Claude Code（`get_events`）と、pi（接続とツールの一覧）だけ**。エージェントの設定ファイルは、自動では書き換えない。

アプリが後から起動しても、エージェントを起動し直す必要はない（`mcp` が、窓口へつなぎ直す）。

### 2. アプリで取り込みを始める

1. `just run` でアプリを起動する。メニューバーに波形のアイコンが出る。メニューに「エージェント: N 件接続中」が出れば、エージェントが受け取れる状態。
2. メニューで、取り込む音声を選ぶ。「マイク」（オン／オフ）と、「システム音声」（オフ／全体／起動中のアプリ）。既定はマイクだけ。
3. 「開始…」→ 同意の 3 項目にチェックして「開始」。初回は、マイクと画面収録の許可の確認が、OS から出る。
4. 途中で「一時停止」「再開」ができる。終わったら「会議を終了」（アプリの終了でも終了する）。
5. エージェントに、`get_events` で文字起こしを読ませる（`--channel` なら自動で届く）。終了の出来事（`ended`）には、記録のファイル（`transcriptPath`）がある。それを読ませて、サマリーを頼む（手順は [skills/meeting-analyzer/SKILL.md](skills/meeting-analyzer/SKILL.md)）。

マイク・画面収録の許可は、このアプリ（ad-hoc 署名のビルドは、ビルドのたびに外れることがある）に付く。スピーカーで聞くと、相手の声がマイクに回り込むことがある。ヘッドホンを使うと確実。

## CLI

アプリと同じ実行ファイルに引数を付けると、CLI になる（ウィンドウは出ない）。

```sh
$EXE mcp [--channel]                      # エージェント向けの MCP サーバー（標準入出力）
$EXE doctor                               # {"installed":true,"locale":"ja_JP","supported":true}
$EXE transcribe sample.aiff               # 確定した結果を 1 行 1 件の JSON で出す
$EXE replay sample.aiff --wait 30 --hold 60   # 検証用：音声ファイルをセッションとして再生し、窓口を開ける
$EXE --help
```

- 失敗は、標準エラーの 1 行の JSON と、終了コード（1 使い方・2 入力・3 窓口・4 文字起こし）で返す。
- アプリの窓口は `~/Library/Application Support/MeetingAnalyzer/hub.sock`（`MEETING_ANALYZER_SOCKET` で変更）。`replay` は、同じ窓口を開けるので、アプリが起動していると使えない（終了コード 3）。

## プライバシー

- 音声は、ファイルにもネットワークにも出さない（メモリ上で処理して捨てる）。外へ出るのは、文字と、（後続で実装する）画面の画像で、この Mac の中の窓口（Unix ドメインソケット。0600・同じユーザーだけ）を通って、エージェントへ渡る。**エージェントを通じて、エージェントの提供元（例：Anthropic）へ送られうる。**
- 記録（`transcript.md`）は、`~/Library/Application Support/MeetingAnalyzer/sessions/<id>/` に、利用者だけが読める権限で書く。
- 取り込みの開始には、参加者の同意・組織の規程・送信先のデータ取扱いの確認が要る（開始の前に、3 項目のチェックを求める。SPEC §3.10）。

## ドキュメント

[docs/README.md](docs/README.md) が入口。製品要件は [SPEC.md](SPEC.md)、作業規約は [AGENTS.md](AGENTS.md)、構成は [docs/architecture.md](docs/architecture.md)、検証は [docs/verification.md](docs/verification.md)、エージェント向けのサマリーの手順は [skills/meeting-analyzer/SKILL.md](skills/meeting-analyzer/SKILL.md)。

## ライセンス

MIT（[LICENSE](LICENSE)）。
