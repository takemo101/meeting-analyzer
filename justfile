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

# ビルドして、実行ファイルを CLI として呼ぶ（例: just cli doctor / just cli replay sample.aiff --bridge http://127.0.0.1:43821）
cli *args: build
    "{{exe}}" "$@"

# 単体テスト（Swift Testing）。画面・音声・ネットワークは使わない
test:
    ./scripts/test.sh

# 実機の native E2E（CLI・本物の音声と認識・偽のブリッジ・メニューバーのアプリの起動と終了）。手順は docs/verification.md
e2e: build
    ./scripts/e2e.sh
