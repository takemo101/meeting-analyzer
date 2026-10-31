import Foundation

/// CLI の、人が読む表示。機械が読む表示（JSON）は `CLIOutput` の型で、標準出力・標準エラーが端末でないときに使う（SPEC §3.9）。
enum CLIView {
    // MARK: ヘルプ

    static func help(_ style: TerminalStyle) -> String {
        let command = { (text: String) in style.cyan(text) }
        var lines: [String] = []
        lines.append(style.bold("\(AppInfo.name) \(AppInfo.version)"))
        lines.append("Mac の音声（マイク・システム音声）を、Mac の中で文字にして、コーディングエージェントへ渡します。")
        lines.append("")
        lines += style.section("使い方", [
            "\(AppInfo.name)                      メニューバーのアプリを起動する（端末からは、アプリとして起動して、すぐ戻る）",
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
            ("actors check <ACTOR.md>", ["ACTOR.md（会話に出てくる人の一覧）の書式を検査して、読み取れた内容を出す"]),
            ("doctor [--locale L]", ["その言語のオンデバイス認識が、この Mac で使えるか調べる（既定 ja_JP）"]),
            ("transcribe <音声ファイル> [--locale L] [--model ID]", ["音声ファイルを文字にして出す（端末では読みやすく、パイプでは 1 行 1 件の JSON）。--model で、ダウンロードしたモデルを使う"]),
            ("models [download <ID>|delete <ID>]", ["ダウンロードして使えるモデル（文字起こし・話者の推定）の、一覧・取得（続きから再開できる）・削除"]),
            ("replay <音声ファイル> [オプション]", ["音声ファイルをセッションとして再生し、エージェントへ渡す窓口を開く（検証用）。",
                                                  "--speaker you|others  --title <名前>  --locale L  --preset <ID>  --model <ID>  --actors <ACTOR.md>  --judge <ID>  --attendees <名前,名前>",
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

    // MARK: アクター

    /// `actors check` の、人が読む表示。
    static func actors(_ list: ActorList, path: String, _ style: TerminalStyle) -> String {
        var lines = [style.bold("ACTOR.md") + "  " + style.dim(path), ""]
        for actor in list.actors {
            lines.append(style.bold(actor.name) + (actor.isSelf ? style.dim("  本人（マイク）") : ""))
            if let role = actor.role { lines.append("  役割: \(role)") }
            if !actor.aliases.isEmpty { lines.append("  呼ばれ方: \(actor.aliases.joined(separator: "、"))") }
            if !actor.topics.isEmpty { lines.append("  話題: \(actor.topics.joined(separator: "、"))") }
        }
        lines.append("")
        lines.append("\(list.actors.count) 人" + (list.selfActor == nil ? "（「本人: はい」の人は、いません）" : ""))
        for warning in list.warnings { lines.append(style.dim("注意: " + warning)) }
        return lines.joined(separator: "\n")
    }

    /// `actors try`（本文 1 つ）：区間ごとに、付けた名前（または、付けなかった理由）と、上位の候補の確率。
    static func actorsTry(_ result: CLIOutput.TryResult, unitTitle: String, _ style: TerminalStyle) -> String {
        var lines = [style.bold(unitTitle) + style.dim("  " + result.gate.text)]
        for segment in result.segments {
            let who = segment.actor.map { style.success($0) } ?? style.warning("付けない（\(reason(segment.outcome))）")
            lines.append("  " + who + "  " + style.dim(segment.text))
            let detail = segment.top.map { "\($0.name) \(Int(($0.probability * 100).rounded()))%" } + (segment.filler.map { ["内容を持たない \(Int(($0 * 100).rounded()))%"] } ?? [])
            if !detail.isEmpty { lines.append("    " + style.dim(detail.joined(separator: "・"))) }
        }
        return lines.joined(separator: "\n")
    }

    private static func reason(_ outcome: String) -> String {
        switch outcome {
        case "tooShort": return "短すぎる"
        case "noCandidate": return "候補がいない"
        case "filler": return "内容を持たない発言"
        case "lowConfidence": return "確信度が足りない"
        default: return outcome
        }
    }

    /// `actors try --cases`：判断の単位ごとの、集計（全体と、場合の名前ごと）。
    static func actorsEval(_ report: CLIOutput.EvalReport, unitTitle: String, _ style: TerminalStyle) -> String {
        func row(_ name: String, _ score: CLIOutput.EvalScore) -> (name: String, text: [String]) {
            (name, ["文 \(score.sentences)・付けた \(score.named)（正解 \(score.correct)・間違い \(score.wrong + score.falseName)）・付けなかった \(score.missed + score.rightlyUnnamed)・付けた中の正解 \(Int((score.precision * 100).rounded()))%"])
        }
        var rows = [row("全体", report.total)]
        for (tag, score) in report.byTag.sorted(by: { $0.key < $1.key }) { rows.append(row(tag, score)) }
        let head = style.bold(unitTitle) + style.dim("  発話 \(report.cases) 件・1 件あたり \(report.secondsPerCase) 秒・" + report.gate.text)
        return ([head] + style.table(rows, label: style.cyan).map { "  " + $0 }).joined(separator: "\n")
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

    static func models(_ models: [LocalModel], decision: [DecisionModel], voice: [VoiceModel], store: ModelStore, directory: String, _ style: TerminalStyle) -> String {
        let rows: [(name: String, text: [String])] = models.map { model in
            let state = store.isInstalled(model.artifact) ? style.success("取得済み") : (store.downloadedBytes(model.artifact) > 0 ? style.warning("途中（続きから取得できる）") : style.dim("未取得"))
            return (model.id, [style.bold(model.name) + "  " + style.dim(megabytes(model.artifact.bytes)) + "  " + state, style.dim(model.summary)])
        }
        var lines = [style.bold("文字起こしのモデル（追加でダウンロードして使う。Mac 標準は、ダウンロード不要）")] + style.table(rows, label: style.cyan).map { "  " + $0 }
        let decisionRows: [(name: String, text: [String])] = decision.map { model in
            let state = store.isInstalled(model) ? style.success("取得済み") : (store.downloadedBytes(model.weights) > 0 ? style.warning("途中（続きから取得できる）") : style.dim("未取得"))
            return (model.id, [style.bold(model.name) + "  " + style.dim(megabytes(model.bytes)) + "  " + state, style.dim(model.summary)])
        }
        lines.append("")
        lines.append(style.bold("話者の推定のモデル（System One 型。選ばない・取得していないときは、推定しない）"))
        lines += style.table(decisionRows, label: style.cyan).map { "  " + $0 }
        let voiceRows: [(name: String, text: [String])] = voice.map { model in
            let state = store.isInstalled(model) ? style.success("取得済み") : (store.downloadedBytes(model) > 0 ? style.warning("途中（続きから取得できる）") : style.dim("未取得"))
            return (model.id, [style.bold(model.name) + "  " + style.dim(megabytes(model.bytes)) + "  " + state, style.dim(model.summary)])
        }
        lines.append("")
        lines.append(style.bold("話者の分離のモデル（声の違いで、相手の話者を分ける。SPEC §3.14）"))
        lines += style.table(voiceRows, label: style.cyan).map { "  " + $0 }
        lines.append("")
        lines.append(style.dim("取得：\(AppInfo.name) models download <ID>（Hugging Face から。続きから再開できる）  削除：models delete <ID>"))
        lines.append(style.dim("使う：transcribe・replay に --model <ID>（文字起こし）、replay に --judge <ID>（話者の推定）、または、メニューの「設定…」で選ぶ。置き場所：\(directory)/"))
        return lines.joined(separator: "\n")
    }

    static func modelDownloaded(name: String, path: String, _ style: TerminalStyle) -> String {
        "\(style.success("✔")) \(style.bold(name)) を取得しました（SHA-256 で検証済み）\n  \(style.dim(path))"
    }

    static func megabytes(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : "\(bytes / 1_000_000) MB"
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

/// ダウンロードの進み具合を、端末へ、10% ごとに 1 行出す（端末でなければ、何も出さない）。
final class ProgressLine: @unchecked Sendable {
    private let enabled: Bool
    private let write: @Sendable (String) -> Void
    private let lock = NSLock()
    private var lastStep = -1

    init(enabled: Bool, write: @escaping @Sendable (String) -> Void) {
        self.enabled = enabled
        self.write = write
    }

    func update(name: String, received: Int64, total: Int64) {
        guard enabled, total > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let percent = Int(received * 100 / total)
        guard percent / 10 != lastStep else { return }
        lastStep = percent / 10
        write("\(name): \(percent)%（\(CLIView.megabytes(received)) / \(CLIView.megabytes(total))）")
    }

    func finish() {}
}
