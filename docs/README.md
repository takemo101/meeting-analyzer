# ドキュメント案内

meeting-analyzer の補助文書の入口。製品要件・受け入れ条件・対象外の唯一の正本は、ルートの [SPEC.md](../SPEC.md) である。`docs/` は仕様を別管理する場所ではなく、構成の理解・開発手順・検証のために使う。

## 文書の役割

| 文書 | 答えること | 管理しないこと |
|---|---|---|
| [README](../README.md) | どんなアプリか、いま何ができるか、どう使い、どうビルドするか | 詳細な要件・作業状態 |
| [SPEC](../SPEC.md) | 何を満たすか、何を対象にしないか、受け入れ条件と実装の状態、未決事項 | 検証の成功証拠 |
| [開発規約](../AGENTS.md) | どう調査・変更・検証・文書更新するか、守る不変条件 | 製品仕様の複製・Issue 状態・作業履歴 |
| [開発手順](development.md) | ビルド・テスト・E2E・mikan・GitButler・PR を、どう進めるか | 追加の実施権限・Issue 状態の複製 |
| [構成説明](architecture.md) | Module の責務・状態の所有・時間と並行・失敗はどう関係するか | 確定 API・実装順序・動作の保証 |
| [参考にした設計原則](references.md) | どの設計原則を選び、何を選ばなかったか。コードのどこに現れるか | 製品要件・原則の全文の複製 |
| [検証手順と記録](verification.md) | SPEC の条件をどう観測し、何をいつ確認したか、何が人間の確認待ちか | 新しい合格条件・未実施の成功・実施権限 |
| [macOS 共通検証スキル](../.agents/skills/verifying-macos-apps/SKILL.md) | アプリを問わず、実操作・期待値・証拠をどう検証し、何を主張してよいか | 製品仕様・成功履歴・追加の操作権限 |
| [固有レシピ](../.agents/skills/verifying-meeting-analyzer/SKILL.md) | 共通手順を、現存するケース・コマンドへどう対応付けるか | 仕様や Issue 状態の複製 |
| [エージェント向け skill](../skills/meeting-analyzer/SKILL.md) | 会議の終了の合図を受けたエージェントが、どうサマリーを出すか | 製品要件（正本は SPEC §3.8） |

文書間で矛盾を見つけた場合は、派生文書を根拠に製品要件を変更しない。SPEC の該当節とユーザーの判断を確認し、必要な修正を関係する文書へ反映する。

## 読む順序

- **アプリを知る**：README → SPEC の概要・機能要件・範囲外。
- **作業を始める**：SPEC の対象節と §8・§11 → 開発規約と開発手順 → 構成説明の該当 Module → 実際のソース。
- **動作を確かめる**：SPEC の受け入れ条件 → 共通検証スキルと固有レシピ → 検証手順の該当ケース。設計説明だけで動作確認を済ませない。
- **結果を判断する**：検証記録 → SPEC の受け入れ条件。自動の実機観測と、人間の確認を区別する。

## 配置

```text
README.md              概要・状況・使い方・ビルド
SPEC.md                製品要件・受け入れ条件（実装の状態つき）・対象外・未決事項
AGENTS.md              開発規約・不変条件
Package.swift          SwiftPM（macOS 26、外部依存なし）
Resources/Info.plist   バンドル設定（LSUIElement・配備下限・マイクの用途文）
Sources/MeetingAnalyzer/      実行ファイル（main.swift だけ）
Sources/MeetingAnalyzerKit/   実装（Core・Transcription・Capture・Hub・MCP・Platform・Session・CLI・App）
Tests/MeetingAnalyzerKitTests/ 単体テスト（Swift Testing）
justfile               開発用コマンド（build・run・cli・test・e2e）
scripts/
  build.sh             build/MeetingAnalyzer.app を作る（Apple silicon、ad-hoc 署名）
  install.sh           build/MeetingAnalyzer.app を、開発用に ~/Applications へ入れて起動する
  uninstall.sh         install.sh で入れたアプリとコマンドを取り除く
  install-lib.sh       install.sh・uninstall.sh の共通部分（入れ先の決定、実行中のアプリの終了）
  test.sh              単体テスト（Swift Testing のマクロプラグインのパスを渡す）
  e2e.sh               bundle ID を変えたコピーで native E2E を実行する
  native-e2e.swift     実機の操作・期待値・report（CLI・本物の音声と認識・窓口と MCP・起動と終了）
.agents/skills/
  verifying-macos-apps/        他の macOS アプリへ持ち出せる共通検証手順（shortnote から取り込み）
  verifying-meeting-analyzer/  meeting-analyzer 固有のケース・コマンド・証拠契約
skills/
  meeting-analyzer/    エージェント向け：終了の合図を受けたときのサマリーの手順
docs/
  README.md            この索引
  development.md       ビルド・テスト・E2E・mikan・GitButler・PR
  architecture.md      構成・状態・時間と並行・失敗
  references.md        参考にした設計原則（選択と不採用）
  verification.md      検証手順・記録・人間の確認待ち
```

`.mikan/` は Git 管理外のローカル作業状態で、この配置や文書のリンク先に含めない（mikan は未初期化。[AGENTS.md](../AGENTS.md)）。

現在の文書量では `docs/` 直下に役割別の文書を置き、空のサブディレクトリや重複する索引を作らない。SPEC を移動・分割せず、別の引き継ぎ書も維持しない。

## 更新時の扱い

- 製品の意味・数値・範囲を変える場合は、SPEC を正本として扱う。補助文書に同じ値を別管理せず、必要な節へ参照する。実装が進んだら、SPEC §8 の「状態」と README の「状況」を、同じ変更で更新する。
- 構成説明は選択した境界とその理由、検証記録は実際の操作と観測を記す。説明・予定・結果を混ぜない。
- 文書を追加・移動・削除したら、この索引と参照元を同じ変更で更新する。見出しを変えたら、その見出しを参照するリンクも確認する。
- 未実施・失敗・限定的な成功を残す。後の修正や再試行は別の記録として結び付け、過去の証拠を全面的な成功へ書き換えない。
- 利用していないツールの操作手順や架空のコマンドを案内しない。
