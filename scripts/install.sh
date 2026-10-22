#!/bin/bash
# build/MeetingAnalyzer.app を、開発用に、ユーザーのアプリケーションフォルダ（既定 ~/Applications。管理者権限は不要）へ入れる。
# 置き場所を変えるときは INSTALL_DIR を渡す（例: INSTALL_DIR=/Applications ./scripts/install.sh）。
# 同じ場所で実行中のアプリは、SIGTERM で終了させてから置き換える（実行中のセッションは、appQuit で終わる）。
# 入れたあと、アプリを起動する（起動したくないときは NO_OPEN=1）。
# エージェントが起動した `mcp`（同じ実行ファイルの別プロセス）には、触れない。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=build/MeetingAnalyzer.app
[ -d "$SRC" ] || { echo "install.sh: $SRC がありません（先に just build）" >&2; exit 1; }

DEST_DIR="${INSTALL_DIR:-$HOME/Applications}"
mkdir -p "$DEST_DIR"
# 実行中のプロセスのコマンド行は、シンボリックリンクを解決した実パスなので、それに合わせる（例: /tmp は /private/tmp）。
DEST_DIR="$(cd "$DEST_DIR" && pwd -P)"
DEST="$DEST_DIR/MeetingAnalyzer.app"
EXE="$DEST/Contents/MacOS/MeetingAnalyzer"

# 引数なしで起動したアプリ本体だけを探す（コマンド行が、実行ファイルのパスと完全に一致するもの）。
running_pids() {
    ps -axo pid=,command= | awk -v exe="$EXE" '{ pid = $1; $1 = ""; sub(/^ /, ""); if ($0 == exe) print pid }'
}

pids="$(running_pids)"
if [ -n "$pids" ]; then
    echo "実行中のアプリを終了します: $pids"
    # shellcheck disable=SC2086
    kill -TERM $pids
    for _ in $(seq 1 100); do
        [ -z "$(running_pids)" ] && break
        sleep 0.1
    done
    [ -z "$(running_pids)" ] || { echo "install.sh: 10 秒たっても終了しません（置き換えません）" >&2; exit 1; }
fi

rm -rf "$DEST"
ditto "$SRC" "$DEST"
codesign --verify --deep --strict "$DEST"

echo "installed: $DEST"
if [ -z "${NO_OPEN:-}" ]; then
    open "$DEST"
    for _ in $(seq 1 50); do
        [ -n "$(running_pids)" ] && break
        sleep 0.1
    done
    if [ -n "$(running_pids)" ]; then echo "起動しました（メニューバーの波形のアイコン）"
    else echo "install.sh: 起動を確認できませんでした（open \"$DEST\" で起動してください）" >&2; exit 1; fi
fi
echo "エージェントへの登録（Claude Code の例）: claude mcp add meeting-analyzer -- \"$EXE\" mcp"
echo "注: ad-hoc 署名のため、入れ直すたびに、マイク・画面収録の許可が外れることがある"
