# meeting-analyzer の開発用コマンド。`just` で一覧を表示する。

set positional-arguments

app := justfile_directory() / "build/MeetingAnalyzer.app"
exe := app / "Contents/MacOS/MeetingAnalyzer"

default:
    @just --list

# build/MeetingAnalyzer.app（Apple silicon、ad-hoc 署名）を作る
build:
    ./scripts/build.sh

# ビルドして、メニューバーのアプリとして起動する。Dock にもウィンドウにも出ない（終了はメニューバーの項目から）
run: build
    open "{{app}}"

# ビルドして、開発用に ~/Applications へ入れて、起動する（INSTALL_DIR で場所、NO_OPEN=1 で起動なし）。実行中の同じアプリは、終了してから置き換える
install: build
    ./scripts/install.sh

# ビルドして、実行ファイルを CLI として呼ぶ（例: just cli doctor / just cli replay sample.aiff --hold 60）
cli *args: build
    "{{exe}}" "$@"

# 単体テスト（Swift Testing）。画面・音声・ネットワークは使わない
test:
    ./scripts/test.sh

# 実機の native E2E（CLI・本物の音声と認識・窓口と MCP・メニューバーのアプリの起動と終了）。手順は docs/verification.md
e2e: build
    ./scripts/e2e.sh
