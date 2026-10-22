#!/bin/bash
# install.sh で入れたアプリとコマンドを、取り除く。
# 入れ先は INSTALL_DIR（既定 ~/Applications）、コマンドの置き場所は BIN_DIR（既定 ~/.local/bin。INSTALL_DIR を変えているときは、BIN_DIR を渡したときだけ）。
# 取り除くのは、アプリ本体と、そのアプリを指すコマンドのシンボリックリンクだけ。
# 会議の記録（~/Library/Application Support/MeetingAnalyzer）、エージェントの設定（MCP の登録）、OS の許可（マイク・画面収録）には、触れない。
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=scripts/install-lib.sh
. scripts/install-lib.sh
resolve_install_paths

stop_running_app || { echo "uninstall.sh: 10 秒たっても終了しません（取り除きません）" >&2; exit 1; }

if [ -d "$DEST" ]; then
    rm -rf "$DEST"
    echo "removed: $DEST"
else
    echo "入っていません: $DEST"
fi

BIN="$(resolve_bin_dir)"
LINK="${BIN:+$BIN/meeting-analyzer}"
if [ -n "$LINK" ] && [ -L "$LINK" ]; then
    if [ "$(readlink "$LINK")" = "$EXE" ]; then
        rm -f "$LINK"
        echo "removed: $LINK"
    else
        echo "残しました（このアプリを指していない）: $LINK -> $(readlink "$LINK")"
    fi
fi

DATA="${MEETING_ANALYZER_DATA_DIR:-$HOME/Library/Application Support/MeetingAnalyzer}"
[ -d "$DATA" ] && echo "残しています（会議の記録。不要なら、自分で削除）: $DATA"
echo "エージェントに登録していたら、自分で外す（例: claude mcp remove meeting-analyzer）"
echo "マイク・画面収録の許可は、システム設定で、自分で外す"
