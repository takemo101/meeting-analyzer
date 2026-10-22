#!/bin/bash
# build/MeetingAnalyzer.app を、開発用に、ユーザーのアプリケーションフォルダ（既定 ~/Applications。管理者権限は不要）へ入れる。
# 置き場所を変えるときは INSTALL_DIR を渡す（例: INSTALL_DIR=/Applications ./scripts/install.sh）。
# 同じ場所で実行中のアプリは、SIGTERM で終了させてから置き換える（実行中のセッションは、appQuit で終わる）。
# 入れたあと、アプリを起動する（起動したくないときは NO_OPEN=1）。
# コマンド `meeting-analyzer`（例: meeting-analyzer claude）を、BIN_DIR（既定 ~/.local/bin）へ、シンボリックリンクで置く。
# INSTALL_DIR を変えているとき（検証用）は、BIN_DIR を渡さない限り、置かない。
# エージェントが起動した `mcp`（同じ実行ファイルの別プロセス）には、触れない。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=build/MeetingAnalyzer.app
[ -d "$SRC" ] || { echo "install.sh: $SRC がありません（先に just build）" >&2; exit 1; }

# shellcheck source=scripts/install-lib.sh
. scripts/install-lib.sh
mkdir -p "${INSTALL_DIR:-$HOME/Applications}"
resolve_install_paths

stop_running_app || { echo "install.sh: 10 秒たっても終了しません（置き換えません）" >&2; exit 1; }

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
BIN="$(resolve_bin_dir)"
if [ -n "$BIN" ]; then
    mkdir -p "$BIN"
    ln -sfn "$EXE" "$BIN/meeting-analyzer"
    echo "コマンド:  $BIN/meeting-analyzer（Claude Code を起動: meeting-analyzer claude）"
    case ":$PATH:" in *":$BIN:"*) ;; *) echo "注: $BIN が PATH にありません。シェルの設定に足してください" >&2 ;; esac
fi
echo "手で登録するなら（Claude Code の例）: claude mcp add meeting-analyzer -- \"$EXE\" mcp"
echo "注: ad-hoc 署名のため、入れ直すたびに、マイク・画面収録の許可が外れることがある"
