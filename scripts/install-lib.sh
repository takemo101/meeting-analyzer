# install.sh・uninstall.sh の共通部分（source して使う）。
# 入れ先（INSTALL_DIR。既定 ~/Applications）と、実行中のアプリ本体の探索・終了。

# 入れ先のディレクトリを、実パスにそろえて、DEST_DIR・DEST・EXE を決める（ディレクトリが無ければ、実パスにできないので、そのまま使う）。
# 実行中のプロセスのコマンド行は、シンボリックリンクを解決した実パスなので、それに合わせる（例: /tmp は /private/tmp）。
resolve_install_paths() {
    DEST_DIR="${INSTALL_DIR:-$HOME/Applications}"
    if [ -d "$DEST_DIR" ]; then DEST_DIR="$(cd "$DEST_DIR" && pwd -P)"; fi
    DEST="$DEST_DIR/MeetingAnalyzer.app"
    EXE="$DEST/Contents/MacOS/MeetingAnalyzer"
}

# コマンドの置き場所。INSTALL_DIR を変えているとき（検証用）は、BIN_DIR を渡さない限り、使わない（空を返す）。
resolve_bin_dir() {
    if [ -n "${BIN_DIR:-}" ] || [ -z "${INSTALL_DIR:-}" ]; then echo "${BIN_DIR:-$HOME/.local/bin}"; fi
}

# 引数なしで起動したアプリ本体だけを探す（コマンド行が、実行ファイルのパスと完全に一致するもの）。
# エージェントが起動した `mcp`（引数つき）には、一致しない。
running_pids() {
    ps -axo pid=,command= | awk -v exe="$EXE" '{ pid = $1; $1 = ""; sub(/^ /, ""); if ($0 == exe) print pid }'
}

# 実行中のアプリ本体を、SIGTERM で終了させる（実行中のセッションは、appQuit で終わる）。10 秒たっても終了しなければ、失敗（1）を返す。
stop_running_app() {
    local pids
    pids="$(running_pids)"
    [ -n "$pids" ] || return 0
    echo "実行中のアプリを終了します: $pids"
    # shellcheck disable=SC2086
    kill -TERM $pids
    for _ in $(seq 1 100); do
        [ -z "$(running_pids)" ] && return 0
        sleep 0.1
    done
    return 1
}

# アプリの bundle ID（マイク・画面収録の許可は、この ID に紐づく。コピー先が違っても、同じ ID なら、同じ許可）。検証では、BUNDLE_ID で別の ID を渡す。
BUNDLE_ID="${BUNDLE_ID:-dev.takemo101.meeting-analyzer}"

# マイク・画面収録の許可を、このアプリの分だけ取り消す（`tccutil reset`。管理者権限は不要）。
# 取り消すと、次の「開始」で、OS の許可の確認が、もう一度出る。
reset_permissions() {
    local service
    for service in ScreenCapture Microphone; do
        if tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1; then
            echo "許可を取り消しました: ${service}（${BUNDLE_ID}）"
        else
            echo "取り消せませんでした: ${service}（システム設定で、手で外してください）" >&2
        fi
    done
}
