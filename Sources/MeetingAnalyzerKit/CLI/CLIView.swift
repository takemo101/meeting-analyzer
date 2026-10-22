import Foundation

/// CLI の、人が読む表示。機械が読む表示（JSON）は `CLIRunner.json` で、標準出力・標準エラーが端末でないときに使う（SPEC §3.9）。
enum CLIView {
    // MARK: ヘルプ

    static func help(_ style: TerminalStyle) -> String {
        let command = { (text: String) in style.cyan(text) }
        var lines: [String] = []
        lines.append(style.bold("\(AppInfo.name) \(AppInfo.version)"))
        lines.append("Mac の音声（マイク・システム音声）を、Mac の中で文字にして、コーディングエージェントへ渡します。")
        lines.append("")
        lines += style.section("使い方", [
            "\(AppInfo.name)                      メニューバーのアプリを起動する",
            "\(AppInfo.name) <コマンド> [オプション]",
        ])
        lines.append("")
        lines += style.section("エージェントを起動する", style.table([
            ("claude [引数...]", ["Claude Code を、このアプリつきで起動する（設定ファイルは書き換えない）。", "字幕は、チャンネルで、会話へ自動で届く"]),
            ("pi|omp [引数...]", ["設定へ MCP サーバーを登録して（初回・場所が変わったときだけ）起動する。", "字幕は、拡張で、会話へ自動で届く"]),
            ("opencode [引数...]", ["設定へ MCP サーバーを登録して（同上）起動する。字幕は、プラグインで、会話へ自動で届く", "（この起動だけ、専用のサーバー --standalone で動く）"]),
            ("mcp [--channel]", ["エージェント向けの MCP サーバー（標準入出力）。--channel で、Claude Code の Channels の通知も出す"]),
        ], label: command))
        lines.append("")
        lines += style.section("調べる・試す", style.table([
            ("presets", ["選べる分析のプリセット（解説・提案・サマリーの出し方）を一覧にする。自分のプリセットは、フォルダに置く"]),
            ("doctor [--locale L]", ["その言語のオンデバイス認識が、この Mac で使えるか調べる（既定 ja_JP）"]),
            ("transcribe <音声ファイル> [--locale L]", ["音声ファイルを文字にして出す（端末では読みやすく、パイプでは 1 行 1 件の JSON）"]),
            ("replay <音声ファイル> [オプション]", ["音声ファイルをセッションとして再生し、エージェントへ渡す窓口を開く（検証用）。",
                                                  "--speaker you|others  --title <名前>  --locale L  --preset <ID>",
                                                  "--wait <秒>  再生の前に、エージェントがつながるのを待つ（上限）",
                                                  "--hold <秒>  再生のあと、窓口を開けておく"]),
        ], label: command))
        lines.append("")
        lines += style.section("そのほか", style.table([
            ("--version", ["版を表示する"]),
            ("--help", ["この表示"]),
        ], label: command))
        lines.append("")
        lines += style.section("終了コード", [
            "0 成功   1 使い方   2 入力   3 窓口（ハブ）   4 文字起こし   5 エージェントを起動できない",
        ])
        lines.append("")
        lines += style.section("出力の形", [
            "端末へ出すときは、人が読む形。パイプ・ファイルへ出すときは、JSON（失敗は、標準エラーへ 1 行）。",
            "色は、端末のときだけ。NO_COLOR を設定すると、付けない。",
            "窓口は、<データの置き場所>/hub.sock（Unix ドメインソケット。MEETING_ANALYZER_SOCKET で変更）。",
        ])
        return lines.joined(separator: "\n")
    }

    // MARK: 失敗

    /// 人が読む失敗の表示。1 行目に何が起きたか、2 行目以降に、次にすること。
    static func failure(_ error: CLIError, _ style: TerminalStyle) -> String {
        var lines = [style.failure(error.message)]
        if let hint = error.hint { lines.append("  " + style.dim("→ " + hint)) }
        return lines.joined(separator: "\n")
    }

    // MARK: エージェントの起動

    /// 起動の前に出す、状態の表（標準エラー）。エージェントが画面を引き継ぐ前の、数行だけ。
    static func launch(agent: LaunchableAgent, appConnected: Bool, registration: RegistrationOutcome?, registrationText: String?, pushes: Bool = true, _ style: TerminalStyle) -> String {
        var rows: [(name: String, text: [String])] = []
        rows.append(("アプリ", [appConnected
            ? style.success("接続しました")
            : style.warning("接続できません。\(agent.command) は起動しますが、アプリを起動するまで、文字起こしは届きません")]))
        if let registration {
            switch registration {
            case .alreadyRegistered:
                rows.append(("MCP 登録", [style.success("登録済み")]))
            case .registered(let path, let backedUp):
                rows.append(("MCP 登録", [style.success("登録しました") + " " + style.dim(path)] + (backedUp ? [style.dim("  元のファイルは *.meeting-analyzer.bak に控えました")] : [])))
            case .updated(let path, let backedUp):
                rows.append(("MCP 登録", [style.success("このアプリの場所へ更新しました") + " " + style.dim(path)] + (backedUp ? [style.dim("  元のファイルは *.meeting-analyzer.bak に控えました")] : [])))
            case .manual(let path, let reason):
                rows.append(("MCP 登録", [style.warning("自動で登録できませんでした（\(reason)）"), style.dim("  \(path) に、手で足してください:")] + (registrationText?.components(separatedBy: "\n").map { "    " + $0 } ?? [])))
            }
        }
        switch agent {
        case .claude: rows.append(("字幕", [style.success("チャンネルで、会話へ自動で届きます")]))
        case .pi, .omp: rows.append(("字幕", [style.success("拡張で、会話へ自動で届きます"), style.dim("  MCP の get_events でも読めます")]))
        case .opencode where pushes:
            rows.append(("字幕", [style.success("プラグインで、会話へ自動で届きます"), style.dim("  この起動は、専用のサーバー（--standalone）で動きます。MCP の get_events でも読めます")]))
        case .opencode:
            rows.append(("字幕", [style.warning("自動では届きません"), style.dim("  「meeting-analyzer の get_events で、会話の内容を見て」のように頼んでください")]))
        }
        let table = style.table(rows, label: style.dim)
        return ([style.bold("\(AppInfo.name) \(AppInfo.version)") + style.dim(" → ") + style.cyan(agent.command)] + table.map { "  " + $0 }).joined(separator: "\n")
    }

    // MARK: 調べる・試す

    static func presets(_ presets: [AnalysisPreset], skipped: [PresetStore.Skipped], userDirectory: String, _ style: TerminalStyle) -> String {
        var rows: [(name: String, text: [String])] = presets.map { preset in
            (preset.id, [style.bold(preset.name) + (preset.source == .user ? style.dim("（自分）") : "") + (preset.id == AnalysisPreset.defaultID ? style.dim("  既定") : "")] + (preset.summary.isEmpty ? [] : [style.dim(preset.summary)]))
        }
        if presets.isEmpty { rows = [("", [style.warning("プリセットがありません")])] }
        var lines = [style.bold("分析のプリセット")] + style.table(rows, label: style.cyan).map { "  " + $0 }
        for item in skipped { lines.append("  " + style.warning("\(item.file)：\(item.reason)")) }
        lines.append("")
        lines.append(style.dim("自分のプリセット：\(userDirectory)/ に、`<ID>.md` で置く（メニューの「プリセットのフォルダを開く」でも開ける）"))
        return lines.joined(separator: "\n")
    }

    static func doctor(_ readiness: SpeechReadiness, _ style: TerminalStyle) -> String {
        let status: String
        let hint: String?
        if readiness.supported && readiness.installed {
            status = style.success("使えます"); hint = nil
        } else if readiness.supported {
            status = style.warning("この Mac で対応していますが、言語モデルが未取得です"); hint = "最初の「開始」のとき、OS が取得します（ネットワークが要ります）"
        } else {
            status = style.failure("この Mac では、使えません"); hint = "言語を変えるか（--locale）、macOS 26 以降の対応を確認してください"
        }
        var lines = [style.bold("オンデバイス認識") + " " + style.cyan(readiness.locale), "  " + status]
        if let hint { lines.append("  " + style.dim("→ " + hint)) }
        return lines.joined(separator: "\n")
    }

    static func transcript(text: String, start: TimeInterval, end: TimeInterval, _ style: TerminalStyle) -> String {
        style.dim("\(clock(start)) → \(clock(end))") + "  " + text
    }

    static func replaySummary(sessionId: String, utterances: Int, batches: Int, duration: TimeInterval, path: String?, _ style: TerminalStyle) -> String {
        var rows: [(name: String, text: [String])] = [
            ("セッション", [sessionId]),
            ("発話", ["\(utterances) 件（\(batches) バッチ）"]),
            ("長さ", [clock(duration)]),
        ]
        if let path { rows.append(("記録", [path])) }
        return ([style.success("再生が終わりました")] + style.table(rows, label: style.dim).map { "  " + $0 }).joined(separator: "\n")
    }

    /// 秒を `mm:ss.s` にする。
    static func clock(_ seconds: TimeInterval) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        return String(format: "%02d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}

extension CLIError {
    /// 次にすること（人が読む表示だけ）。
    var hint: String? {
        switch self {
        case .usage: return "\(AppInfo.name) --help で、使い方を見られます"
        case .input: return nil
        case .hub(let code, _): return code == "hub_unavailable" ? "メニューバーのアプリが、窓口を使っている可能性があります。終了してから、もう一度実行してください" : nil
        case .transcription: return "\(AppInfo.name) doctor で、この Mac のオンデバイス認識の状態を確かめられます"
        case .agent: return nil
        }
    }
}
