# 開発手順

meeting-analyzer の調査・変更・Issue・PR を、一つの作業単位として進めるための手順。製品仕様ではなく、[AGENTS.md](../AGENTS.md) の規約を具体的な運用へ結び付ける。

## 正本と開始時の読取り順

| 対象 | 正本・役割 |
|---|---|
| 製品要件・受け入れ条件・実装の状態・未決事項 | [SPEC.md](../SPEC.md) が唯一の正本 |
| 作業規約・操作権限・不変条件 | [AGENTS.md](../AGENTS.md)。本書はその派生手順であり、追加の実施許可ではない |
| Issue の現在の状態・Report | mikan（未初期化。[下記](#mikan-の-issue-進行)）。文書に Status の写しを維持しない |
| 構成・観測方法・証拠 | [構成説明](architecture.md)、[検証手順と記録](verification.md) |

1. 依頼の対象と、SPEC の該当節（機能要件・§8 の受け入れ条件と状態・§11 の未決事項）を読む。
2. AGENTS と本書を読み、変更範囲、許可された操作、今回の確認方法を特定する。既存のユーザー変更を保持する。
3. Issue があれば、対象 Issue の本文・現在の Status・関連 Issue・Report を読む。
4. 構成説明の該当 Module と、実際のソース・`Package.swift` を読む。

## 作業単位と最小 E2E

一回の作業を、利用者に見える一つの成果と、それを観測する方法で定義する。文書量・試験件数・部品数・PR の数は完成基準にしない。許可された範囲の**最小で安全な端から端までの経路**を早く確かめ、周辺の抽象化や将来対応を先行させない。

- 既存の定義やソースで分かる環境前提を先に読む。調べられる事実はユーザーへ聞かず、設定・権限・鍵・認証を変更して前提不足を勝手に補わない。
- 変更・検証・独立レビュー・文書更新を、一貫した Issue サイズの変更にまとめる。
- **実機でしか確かめられない機能（マイク・システム音声・画面・権限）は、本体に組み込む前に、小さな試作（CLI など）で確かめる。** 実機試行の前に、仮説・結果を区別できる観測・停止条件を定める。ユーザーへ依頼するときは、画面・操作・期待する可視変化を具体的に示す。
- ユーザー報告は事実として扱う。同じ失敗を確認するだけの再試行や、根拠のない推測修正はしない。

## ビルドと実行

macOS 26 以降、Apple silicon、Swift 6 以降（Xcode または Command Line Tools）。外部パッケージはない。

`just` で入口を一覧できる（[justfile](../justfile)）。`just` が無い環境では、同じ処理を `scripts/` から直接実行する。

| レシピ | 内容 |
|---|---|
| `just build` | `./scripts/build.sh`。`build/MeetingAnalyzer.app`（Apple silicon）を ad-hoc 署名で作る。`VERSION=X.Y.Z` で版を指定でき、`SIGN_IDENTITY` を渡すと Developer ID で署名する |
| `just dmg` | `./scripts/dmg.sh` で `build/MeetingAnalyzer.dmg`（アプリと /Applications へのリンク入り）を作り、`./scripts/verify-dmg.sh` で検査する（リリースのワークフローと同じ）。`VERSION=X.Y.Z` でアプリの版を指定できる |
| `just icon` | `./scripts/make-icon.sh`。アプリのアイコン `Resources/AppIcon.icns` を、コード（`scripts/make-icon.swift`。CoreGraphics で描く。外部の素材なし）から作り直す。生成物は、コミットする（ビルドのたびには作らない）。図柄は、紫がかった青の角丸の四角に、白い吹き出しと波形 |
| `just run` | ビルドして `open` で起動する。メニューバーに常駐し、Dock・ウィンドウには出ない。終了はメニューの「終了」 |
| `just install` | ビルドして、`~/Applications/MeetingAnalyzer.app` へ入れて、**起動する**（`./scripts/install.sh`。管理者権限は不要。`INSTALL_DIR` で場所、`NO_OPEN=1` で起動なし）。同じ場所で実行中のアプリ本体は、SIGTERM で終了させてから置き換え、入れたあとに起動し直す（エージェントが起動した `mcp` には触れない）。署名が ad-hoc なので、入れ直すたびに、マイク・画面収録の許可が外れることがある。コマンド `meeting-analyzer` を `BIN_DIR`（既定 `~/.local/bin`）へ、シンボリックリンクで置く（`INSTALL_DIR` を変えているときは、`BIN_DIR` を渡さない限り置かない）。登録コマンドは出力に出る |
| `just uninstall` | `./scripts/uninstall.sh`。`just install` で入れたアプリ（`INSTALL_DIR`）と、それを指すコマンドのシンボリックリンク（`BIN_DIR`。別のものを指していれば残す）を取り除く。実行中なら、SIGTERM で終了させる。既定の場所のときは、**マイク・画面収録の許可も取り消す**（`tccutil reset`。bundle ID に紐づくので、`INSTALL_DIR` を変えているときは、`RESET_PERMISSIONS=1` を渡したときだけ）。**会議の記録・エージェントの設定（MCP の登録）には触れない**（取り除き方を、出力に出す） |
| `just reset-permissions` | `./scripts/reset-permissions.sh`。このアプリのマイク・画面収録の許可を取り消す（次の「開始」で、OS の許可の確認が、もう一度出る）。設定の一覧ではオンなのに「許可されていません」と出るときに使う。`just install` に `RESET_PERMISSIONS=1` を付けると、入れる前に取り消す |
| `just cli <引数>` | ビルドして、実行ファイルを CLI として呼ぶ（例：`just cli doctor`） |
| `just native` | `./scripts/build-native.sh`。文字起こしの推論の実行環境 transcribe.cpp（固定した commit。SPEC §3.12）を、`build/native` に、静的ライブラリとしてビルドする（ビルド済みなら何もしない。`build`・`test`・`e2e`・`dmg` が、先に呼ぶ）。GitHub からのソースの取得（と、cmake が無いときの PyPI）に、ネットワークを使う |
| `just test` | `./scripts/test.sh`。単体テスト（Swift Testing）。音声・画面・ネットワークは使わない。Command Line Tools だけの環境では、`swift test` にマクロプラグインのパスを渡す必要があり、素の `swift test` は失敗する |
| `just e2e` | ビルドして native E2E を実行する（[検証の入口](verification.md#検証の入口)） |

- 版は、`Resources/Info.plist` と `AppInfo.version` の 2 か所。単体テストが、一致を確認する。版を上げるときは、両方を変える。
- 生成物は `build/`（Git 対象外）。`build/native/` は、transcribe.cpp のソースとビルド（`src`・`cmake`・`install`）と、SwiftPM が使うヘッダ（`include`）・静的ライブラリ（`lib`）。固定する commit を変えるときは、`scripts/build-native.sh` の `COMMIT` を直す（版が違えば、自動でビルドし直す）。
- `swift build` で、`ld: warning: search path '…/CommandLineTools/Developer/…' not found` が出ることがある。Command Line Tools だけの環境で出る警告で、動作には影響しない。

## リリース

タグ `vX.Y.Z` を push すると、GitHub Actions（[release.yml](../.github/workflows/release.yml)）が、DMG を作って GitHub Release に添付する。版ごとに、`MeetingAnalyzer-X.Y.Z.dmg` と `.sha256` をダウンロードできる。

1. `Resources/Info.plist`（`CFBundleShortVersionString`・`CFBundleVersion`）と `AppInfo.version` を、新しい版へ上げて、main に入れる（単体テストが、2 か所の一致を確認する）。
2. main の commit にタグを付けて、push する：`git tag vX.Y.Z <mainのcommit> && git push origin vX.Y.Z`。
3. ワークフローが、**Info.plist の版がタグと一致すること**、**タグの commit が main に含まれること**を確かめ、単体テスト → DMG の作成 → 検査（`verify-dmg.sh`）→ `.sha256` → Release の作成、の順に進む。どれかが失敗したら、Release は作らない。
4. 変更点は、Release の自動生成の説明（`--generate-notes`）。インストール手順の定型文が、その前に付く。

- Release を作らない確認：Actions タブ → release → Run workflow（または、関係するファイルを変える Pull Request）。DMG をアーティファクトに残し、ダウンロードして SHA-256 を照合するところまで確かめる。
- 署名は ad-hoc（鍵・公証の認証情報は、ワークフローに渡さない）。Developer ID の署名・公証を足すときは、利用者の判断で、secrets と手順を決めてから。
- ローカルで同じ DMG を作る：`just dmg`。

## mikan の Issue 進行

**初期化済み**（Issue の ID は `MIK-NNN`）。以下は、shortnote で使っている進め方と同じである。

- `.mikan/` 全体は Git 管理外のローカル作業状態であり、別の clone へ Issue やボード設定は引き継がれない。配下を直接参照・編集せず、文書のリンク対象にも含めない。Issue の読取り、Status 更新、Report 追加は mikan MCP だけで行う。利用できる機能は `search_tools` で発見し、`get_tool_details` で schema と分類を確認し、読取り専用だけを `call_read_tool`、更新または未分類を `call_write_tool` から呼ぶ。
- 実装 Issue は **`backlog → ready → active → completed`** の順で進める。各遷移の直前に現在の Status を再読取りし、期待する前状態に一致することを確認する。

| Status | 扱い |
|---|---|
| `backlog` | 候補。Issue があるだけでは着手許可にならない |
| `ready` | 対象範囲、前提・依存、SPEC の条件と今回の操作権限を確認済み |
| `active` | 実装直前に移す。同時に active の実装 Issue は最大 1 件 |
| `blocked` | 未承認、前提不足、検査失敗、未解決レビュー、merge・同期・受け入れの阻害などを理由付きで記録する |
| `completed` | 必要な検証・レビュー・受け入れ、PR の normal merge、workspace 同期、Report が揃った後にだけ移す |

- 通常の流れ：実装 → 対象と失敗ケースの検証 → 全体検査（`just test`・`just e2e`） → 独立レビュー → 指摘修正 → PR → `main` へ normal merge → GitButler 同期 → Report → Status を再読取りして `completed`。
- 検査失敗・未解決レビュー・未マージ・同期の未完了・受け入れの不足は、`active` または理由付き `blocked` に残し、完成を宣言して次の実装 Issue を開始しない。**人間の確認（実機のマイク・システム音声・権限・会議での品質）は、別の判断として残る**。Issue の完了は、製品全体の受け入れではない。
- Report に、対象と SPEC 節、実行した検査と結果、独立レビューと指摘対応、PR・merge commit、同期結果、受け入れの範囲、未実施事項を記録する。詳細な実機の証拠は [検証記録](verification.md) へリンクする。

## GitButler と PR

**GitButler で進める**。GitHub のリポジトリ（https://github.com/takemo101/meeting-analyzer、公開）の `main` を target（`origin/main`）、push remote を `origin` にして、初期化してある（`but setup`。作業ツリーは `gitbutler/workspace` ブランチ。`main` へ直接 commit しない）。shortnote と同じ運用にする。target を変える・`but teardown` で通常の Git へ戻す、は、ユーザーの依頼があるときだけ。

- Git の書込みは `but`。raw Git の add・commit・checkout・merge・rebase・push などで書き込まない（読取りは可）。feature・fix は Issue 単位の専用 branch／stack で扱い、無関係な変更を混ぜない。`develop` を作らない。target の変更を、PR の権限だけで勝手に行わない。
- ユーザーが PR を依頼した場合の流れ：検証・独立レビュー → 必要な変更だけを `but commit -b <branch> -m <message> <ids...>` → `but pr new <branch> -F <message-file>`（push を含む） → PR の target・head・変更ファイル・required checks・reviews・mergeability の確認 → `main` へ normal merge → GitHub の実際の状態で `MERGED` を確認 → `but pull --check`・`but pull --status-after` で同期。
- `but` の PR merge が使えず、auto-merge も使えない場合だけ、レビュー済みの head に束縛した `gh pr merge <number> --repo <owner>/<repo> --merge --match-head-commit <sha>` を例外として使う。admin・force・checks／reviews／保護の迂回・auto-merge 設定の変更・`but land` による PR 回避は禁止。
- `but unapply <branch>` は、その stack のファイルを作業ツリーから外す。唯一の stack を unapply すると、ソースが一時的に消えたように見える（commit は残る）。target を切り替える前に、未 push の commit が無いことを確認する。conflict を reset・discard・強制同期で消さず、無関係な作業を保つ。
- リリース（タグ・DMG・GitHub Release）は、ユーザーの依頼があるときだけ。手順は [リリース](#リリース)。タグは、`main` が `origin/main` と同期している状態で付ける（`but pull` のあと）。
