# meeting-analyzer

Mac の**音声**（マイクと、Mac から出ている音）を、Mac の中で文字にして、Claude Code などのコーディングエージェントへ**ライブで転送**する macOS のメニューバーアプリ。終わると、エージェントへ**終了の出来事**を渡し、エージェントがプロジェクトの内容を元に、**詳細なサマリー**を出せる。

- 取り込む音声を選ぶ：**マイク**（本人）と、**システム音声**（相手。Mac から出ている音の全体、または選んだアプリ）。Mac のオンデバイスの音声認識で文字にする。**音声は保存も送信もしない。**
- 特定のサービスに依存しない。Mac で音が出るもの（会議・動画・通話）が対象。ブラウザの拡張機能は要らない。
- このプロジェクト単体で完結する。エージェントへ渡す受け口は、同じ実行ファイルの MCP サーバー（`meeting-analyzer mcp`）。Claude Code・omp・pi・opencode など、MCP を使えるエージェントに登録する。

```
アプリ（メニューバー）── Unix ドメインソケット ──> meeting-analyzer mcp（MCP）──> エージェント
```

失うもの：相手が複数人のとき、誰の発言かの区別（相手は「相手」にまとまる）。

## 状況（v0.1.7・開発の初期）

製品要件と実装の状況は、[SPEC.md](SPEC.md) の §8 が正本。いまできること：

| できる | まだ |
|---|---|
| メニューバーのアプリから、取り込む音声（マイク・システム音声の全体またはアプリ）を選び、開始・一時停止・再開・終了する。オンデバイスで文字にし、エージェントへ渡す窓口（Unix ドメインソケット）へ流し、記録を書く | 自動終了。エコーの疑いは、メニューでヘッドホンを案内する（検出の当たりは未確認） |
| エージェント側の MCP サーバー（`mcp`）：`get_events`（pull。Claude Code で実機確認済み）、`--channel`（push。Claude Code の Channels。合成音声で、字幕の自動の到着と、終了の出来事でのエージェントの反応を確認済み）。メニューから、登録コマンドをコピー | omp の MCP の接続での確認（pi は接続まで確認済み） |
| 音声ファイルの文字起こし（`transcribe`）・再生（`replay`）・この Mac で使えるかの確認（`doctor`） | |

マイク・システム音声の実取り込み（権限を含む）と、メニューからの開始〜終了の操作は、実機での人間の確認がまだ済んでいない（[検証手順と記録](docs/verification.md)）。

## 必要なもの

- macOS 26 以降、Apple silicon。Swift 6（Xcode または Command Line Tools）。外部パッケージはない。
- 開発用：`just`（任意。なければ `scripts/` を直接実行）。E2E には、`say` の日本語の声 Kyoko も使う。

## ダウンロード（リリースの DMG）

[Releases](https://github.com/takemo101/meeting-analyzer/releases) から、版ごとの `MeetingAnalyzer-X.Y.Z.dmg`（と `.sha256`）をダウンロードできる。

1. DMG を開き、MeetingAnalyzer を「Applications」へドラッグする。
2. 初回は、署名が ad-hoc（Developer ID の署名・公証なし）のため、Gatekeeper に止められる。右クリック →「開く」、または `xattr -dr com.apple.quarantine /Applications/MeetingAnalyzer.app`。
3. コマンド（`meeting-analyzer claude` など）を使うなら、メニューバーの MeetingAnalyzer のメニューから「コマンド「meeting-analyzer」をインストール（/usr/local/bin）」を選ぶ（管理者のパスワードを求められる。もう一度選ぶと外れる）。アプリを「アプリケーション」へ移してから。

照合：`shasum -a 256 -c MeetingAnalyzer-X.Y.Z.dmg.sha256`。作り方（タグ → DMG）は [開発手順](docs/development.md#リリース) を参照。

## ビルドと実行

```sh
just build          # build/MeetingAnalyzer.app（Apple silicon、ad-hoc 署名）
just dmg            # build/MeetingAnalyzer.dmg（リリースと同じ手順。検査つき）
just run            # メニューバーのアプリとして起動する（Dock・ウィンドウには出ない）
just uninstall      # install で入れたアプリとコマンドを取り除く（記録・エージェントの設定・OS の許可は残す）
just install        # ~/Applications へ入れて起動する（INSTALL_DIR で場所、NO_OPEN=1 で起動なし。実行中の同じアプリは、終了して置き換える）
just test           # 単体テスト（Swift Testing）
just e2e            # 実機の native E2E（CLI・本物の音声と認識・窓口と MCP・起動と終了）
```

## 使い方

### 0. Claude Code を、コマンド 1 つで起動する（登録は不要）

`just install` が、コマンド `meeting-analyzer` を `~/.local/bin` に置く（PATH に無ければ、足す）。DMG から入れたときは、メニューの「コマンド「meeting-analyzer」をインストール」で、`/usr/local/bin` に置ける。

```sh
meeting-analyzer claude            # アプリ（窓口）が動いていなければ起動し、Claude Code を、文字起こしのチャンネルつきで起動する
meeting-analyzer claude "今日の打ち合わせを聞いて、気になる点を教えて" --resume   # 引数は、そのまま claude へ渡す
```

- MCP の設定は、その起動だけに渡す（Claude Code の設定ファイルは、書き換えない）。字幕は、チャンネルで自動で届く。
- Channels には、開発用の許可（`--dangerously-load-development-channels`）が付く。起動時に「Loading development channels」の警告が出たら、「1. I am using this for local development」を選ぶ。
- 起動後に `server:meeting-analyzer-channel · no MCP server configured with that name` と表示されても、字幕の自動の到着は動く（`--mcp-config` で、その起動だけに渡した設定を、Claude Code の起動時の確認が、設定済みの一覧に数えないための表示。実機で、字幕と終了の出来事が `← meeting-analyzer-channel: …` として届き、Claude Code が反応することを確認した）。
- **pi・omp・opencode も、同じ形で起動できる**：`meeting-analyzer pi`／`omp`／`opencode`（引数は、そのまま渡す）。**初回だけ、そのエージェントの設定ファイルへ、`meeting-analyzer` の MCP サーバーを自動で登録する**（他の内容は、そのまま。最初に、元のファイルを `*.meeting-analyzer.bak` へ控える。登録済みなら、何も書かない。コメントを含む設定は、書かずに、手で足す文を示す）。登録先：pi＝`~/.pi/agent/mcp.json`、omp＝`~/.omp/agent/mcp.json`、opencode＝`~/.config/opencode/opencode.json`。
- **字幕が自動で届くのは、Claude Code（Channels）、pi、omp、opencode**。pi と omp には、アプリに同梱した拡張（`-e`）を渡す。opencode には、同梱のプラグインを、その起動だけ載せる（環境変数 `OPENCODE_CONFIG_CONTENT`。設定ファイルは書き換えない）。拡張・プラグインが、アプリの窓口へつなぎ、字幕と終了の出来事を、セッションのメッセージとして押し込み、エージェントが動き出す。
- **opencode は、この起動だけ、専用のサーバー（`--standalone`）で動く**（既定の共有のバックグラウンドサービスには、環境変数が届かないため）。`opencode mcp list` などの管理コマンドは、そのまま。
- agy は対象外（外から会話へメッセージを入れる仕組みが無く、自動の押し込みができないため）。
- 確認済み：pi・omp は、拡張が、字幕を受け取ること（実機の `--mode rpc`）。pi は、モデルが出来事を受けて動き出すことも。opencode は、実機で、字幕が会話へ届き、モデルが処理すること。

### 1. エージェントに、MCP サーバーを手で登録する（`meeting-analyzer <名前>` を使うなら不要）

手で書くときは、次のとおり（登録の項目は、メニューにない）。

実行ファイルは `build/MeetingAnalyzer.app/Contents/MacOS/MeetingAnalyzer`（以下 `$EXE`。絶対パスで登録する）。MCP サーバーは、標準入出力で話す stdio のサーバーで、コマンドは `$EXE mcp`。

```sh
# Claude Code（ツール get_events で受け取る）
claude mcp add meeting-analyzer -- "$EXE" mcp

# Claude Code で、字幕を自動で押し込む（Channels。開発用の許可が要る）
claude mcp add meeting-analyzer-channel -- "$EXE" mcp --channel
claude --dangerously-load-development-channels server:meeting-analyzer-channel
```

pi（`pi mcp add meeting-analyzer -- "$EXE" mcp`）・opencode（`opencode mcp add --global …`）も、同じ形で登録できる。omp は `~/.omp/agent/mcp.json` に stdio サーバーを足す。**確認済みなのは、Claude Code（`get_events`）と、pi（接続とツールの一覧）だけ**。エージェントの設定ファイルは、自動では書き換えない。

アプリが後から起動しても、エージェントを起動し直す必要はない（`mcp` が、窓口へつなぎ直す）。

### 2. アプリで取り込みを始める

1. `just run` でアプリを起動する。メニューバーに波形のアイコンが出る。メニューに「エージェント: N 件接続中」が出れば、エージェントが受け取れる状態。
2. メニューで、取り込む音声を選ぶ。「マイク」（オン／オフ）と、「システム音声」（オフ／全体／起動中のアプリ）。既定はマイクだけ。
   「画面の取り込み」（オフ／画面全体／アプリのウィンドウ。既定はオフ）を選ぶと、画面に変化があったときだけ、縮小した画像（JPEG）を、字幕に添えて渡す（エージェントは、画面を指す話のときに読む。会議の記録（`transcript.md`）にも、**撮った画像がすべて、時刻の順に入る**。記録と画像は、同じフォルダ `sessions/<id>/` にあり、メニューの「記録の保持期間」（既定 7 日。「消さない」も選べる）を過ぎたら、フォルダごと消える）。
   「分析のプリセット」も選べる（既定は「標準」）：**何を・どう分析して・どう出すか**（解説・提案・サマリーの出し方）を切り替える。同梱は、標準／議事録／技術レビュー／学習ノート／動画・アニメのあらすじ／商談・面談。**自分のプリセットを足せる**（メニューの「プリセットのフォルダを開く」→ `<ID>.md`。同じ ID の同梱のものは、自分のものが優先）。一覧は `meeting-analyzer presets`。詳しくは [プリセット](docs/presets.md)。
   「転送のまとめ方」も選べる（既定は「発話の区切りごと」）：**発話の区切りごと**（1.2 秒静かになったら）／**会話の区切りごと**（3 秒静かになったら。話の 1 まとまりを渡す。解説・提案に向く）／**まとまってから解説**（5 秒静かになり、80 字以上たまったら。相づちだけでは動かさない。エージェントを動かす回数が、いちばん少ない）／約 30 秒ごと／約 5 秒ごと。
3. 「開始」を選ぶ（確認のダイアログは出ない）。初回は、マイクと画面収録の許可の確認が、OS から出る。
4. 途中で「一時停止」「再開」ができる。終わったら「会議を終了」（アプリの終了でも終了する）。
5. エージェントに、`get_events` で文字起こしを読ませる（`--channel` なら自動で届く）。終了の出来事（`ended`）には、記録のファイル（`transcriptPath`）がある。それを読ませて、サマリーを頼む（手順は [skills/meeting-analyzer/SKILL.md](skills/meeting-analyzer/SKILL.md)）。

### 許可（マイク・画面収録）がオンなのに、「許可されていません」と出る

**許可は、アプリの署名の識別（指定要件）に紐づきます。** ad-hoc 署名の既定の識別は、実行ファイルのハッシュ（cdhash）で、ビルドごとに変わるため、入れ直すと、システム設定の一覧ではオンに見えたまま、無効になります。いまの `build.sh` は、識別を bundle ID だけにして、ビルドが変わっても同じアプリとして扱われるようにしている（開発用）。**この版を初めて入れたときは、古い許可（旧い識別のもの）が残っているので、下の手順で一度だけ付け直す。** そのあとは、入れ直しても残るはず（実機で確認中）。

1. システム設定 > プライバシーとセキュリティ > **マイク**（システム音声は **画面とシステムオーディオの録音**）を開く（失敗のダイアログの「システム設定を開く」からも行ける）。
2. 一覧の meeting-analyzer を選び、「−」で**一度削除**する。
3. もう一度「開始」する。許可の確認が出るので、許可する。

ターミナルなら、**`just reset-permissions`** で、画面収録とマイクの許可を、まとめて取り消せる（内部は `tccutil reset`）。`RESET_PERMISSIONS=1 just install` なら、入れる前に取り消す。`just uninstall` は、既定の場所のとき、アプリの削除と一緒に、許可も取り消す。

マイク・画面収録の許可は、このアプリ（ad-hoc 署名のビルドは、ビルドのたびに外れることがある）に付く。スピーカーで聞くと、相手の声がマイクに回り込むことがある。ヘッドホンを使うと確実。

## CLI

アプリと同じ実行ファイルに引数を付けると、CLI になる（ウィンドウは出ない）。

```sh
$EXE claude [claude の引数...]            # Claude Code を、MCP サーバー（チャンネル）つきで起動する
$EXE mcp [--channel]                      # エージェント向けの MCP サーバー（標準入出力）
$EXE doctor                               # この Mac で、その言語のオンデバイス認識が使えるか
$EXE transcribe sample.aiff               # 確定した結果を出す（パイプなら 1 行 1 件の JSON）
$EXE replay sample.aiff --wait 30 --hold 60   # 検証用：音声ファイルをセッションとして再生し、窓口を開ける
$EXE --help
```

- 端末へ出すときは、人が読む形（見出し・表・`✔`/`!`/`✖`。色は `NO_COLOR` で消せる）。パイプ・ファイルへ出すときは JSON（失敗は、標準エラーの 1 行）。終了コードは、1 使い方・2 入力・3 窓口・4 文字起こし・5 エージェントを起動できない。
- アプリの窓口は `~/Library/Application Support/MeetingAnalyzer/hub.sock`（`MEETING_ANALYZER_SOCKET` で変更）。`replay` は、同じ窓口を開けるので、アプリが起動していると使えない（終了コード 3）。

## プライバシー

- 音声は、ファイルにもネットワークにも出さない（メモリ上で処理して捨てる）。外へ出るのは、文字と、画面の画像（選んだときだけ）で、この Mac の中の窓口（Unix ドメインソケット。0600・同じユーザーだけ）を通って、エージェントへ渡る。**エージェントを通じて、エージェントの提供元（例：Anthropic）へ送られうる。**
- 記録（`transcript.md`）は、`~/Library/Application Support/MeetingAnalyzer/sessions/<id>/` に、利用者だけが読める権限で書く。
- **相手の発言を処理します。** 参加者への周知・同意、組織の規程、送信先のエージェントのデータの取り扱いの確認は、利用者の責任です（アプリは、開始の前に確認を求めません。SPEC §3.10）。

## ドキュメント

[docs/README.md](docs/README.md) が入口。製品要件は [SPEC.md](SPEC.md)、作業規約は [AGENTS.md](AGENTS.md)、構成は [docs/architecture.md](docs/architecture.md)、検証は [docs/verification.md](docs/verification.md)、エージェント向けのサマリーの手順は [skills/meeting-analyzer/SKILL.md](skills/meeting-analyzer/SKILL.md)。

## ライセンス

MIT（[LICENSE](LICENSE)）。
