import Foundation

public enum AppInfo {
    /// `Resources/Info.plist` の版と同じ（テストで一致を確認する）。
    public static let version = "0.1.10"
    public static let name = "meeting-analyzer"
}

/// CLI の失敗。終了コードは SPEC §3.9：1 = 使い方、2 = 入力、3 = 窓口（ハブ）、4 = 文字起こし、5 = エージェントを起動できない。
public enum CLIError: Error, Equatable {
    case usage(String)
    case input(String)
    case hub(code: String, message: String)
    case transcription(String)
    case agent(String)

    public var exitCode: Int32 {
        switch self {
        case .usage: return 1
        case .input: return 2
        case .hub: return 3
        case .transcription: return 4
        case .agent: return 5
        }
    }

    public var code: String {
        switch self {
        case .usage: return "usage"
        case .input: return "input"
        case .hub(let code, _): return code
        case .transcription: return "transcription"
        case .agent: return "agent_unavailable"
        }
    }

    public var message: String {
        switch self {
        case .usage(let text), .input(let text), .transcription(let text), .agent(let text): return text
        case .hub(_, let text): return text
        }
    }
}

public struct ReplayOptions: Equatable {
    public var file: String
    public var speaker: Speaker
    public var title: String
    public var locale: String
    /// 再生が終わってから、窓口を開けておく秒数（エージェントが読めるように）。
    public var hold: Double
    /// 再生を始める前に、エージェントがつながるのを待つ秒数の上限（つながったら、すぐ始める）。
    public var wait: Double
    /// 開始の出来事で渡す、分析のプリセットの ID（SPEC §3.11）。無指定なら、既定。
    public var preset: String?
    /// 使う文字起こし（SPEC §3.12）。無指定なら、Mac 標準。
    public var model: TranscriptionChoice
    /// 使う `ACTOR.md` のパス（SPEC §3.13）。無指定なら、アクターを使わない。
    public var actors: String?
    /// 話者の推定に使う判断モデルの ID（`DecisionModelCatalog`。SPEC §3.13）。無指定なら、推定しない（「相手」のまま）。
    public var judge: String?

    public init(file: String, speaker: Speaker, title: String, locale: String, hold: Double, wait: Double, preset: String? = nil, model: TranscriptionChoice = .apple, actors: String? = nil, judge: String? = nil) {
        self.actors = actors
        self.judge = judge
        self.model = model
        self.file = file
        self.speaker = speaker
        self.title = title
        self.locale = locale
        self.hold = hold
        self.wait = wait
        self.preset = preset
    }
}

/// `models` の操作。ID は、一覧（`LocalModelCatalog`・`DecisionModelCatalog`）にあるものだけ（読み取りの境界で検査済み）。
public enum ModelsCommand: Equatable {
    case list
    case download(id: String)
    case delete(id: String)
}

public enum Command: Equatable {
    /// `ACTOR.md` の書式を検査して、読み取れた内容を出す（SPEC §3.13）。
    case actorsCheck(file: String)
    case gui
    case help
    case version
    case doctor(locale: String)
    /// 選べる分析のプリセットの一覧（SPEC §3.11）。
    case presets
    case transcribe(file: String, locale: String, model: TranscriptionChoice)
    /// ダウンロード式の文字起こしのモデルの、一覧・取得・削除（SPEC §3.12）。
    case models(ModelsCommand)
    case replay(ReplayOptions)
    /// エージェント向けの MCP サーバー（標準入出力）。`channel` なら、Claude Code の Channels の通知も出す。
    case mcp(channel: Bool)
    /// エージェント（Claude Code・pi・omp・opencode）を、このアプリの MCP サーバーつきで起動する。`arguments` は、そのままエージェントへ渡す。
    case launch(agent: LaunchableAgent, arguments: [String])
}

public enum CommandParser {
    public static let defaultLocale = "ja_JP"

    /// 引数を一度だけ検査して、型にする。知らないコマンド・オプション、足りない値、重複は、使い方の誤りとして断る。
    public static func parse(_ arguments: [String]) -> Result<Command, CLIError> {
        guard let first = arguments.first else { return .success(.gui) }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "--help", "-h", "help": return rest.isEmpty ? .success(.help) : .failure(.usage("help に引数はありません"))
        case "--version", "-v": return rest.isEmpty ? .success(.version) : .failure(.usage("--version に引数はありません"))
        case "presets":
            return options(rest, allowed: [], positional: 0).map { _ in .presets }
        case "actors":
            guard rest.count == 2, rest[0] == "check" else { return .failure(.usage("actors の使い方: actors check <ACTOR.md>")) }
            return .success(.actorsCheck(file: rest[1]))
        case "doctor":
            return options(rest, allowed: ["--locale"], positional: 0).map { .doctor(locale: $0.values["--locale"] ?? defaultLocale) }
        case "transcribe":
            return options(rest, allowed: ["--locale", "--model"], positional: 1).flatMap { parsed in
                model(parsed.values["--model"]).map { .transcribe(file: parsed.positional[0], locale: parsed.values["--locale"] ?? defaultLocale, model: $0) }
            }
        case "models":
            switch rest.count {
            case 0: return .success(.models(.list))
            case 2 where rest[0] == "download" || rest[0] == "delete":
                guard LocalModelCatalog.model(id: rest[1]) != nil || DecisionModelCatalog.model(id: rest[1]) != nil else { return .failure(.usage(unknownModel(rest[1], includingApple: false, includingDecision: true))) }
                return .success(.models(rest[0] == "download" ? .download(id: rest[1]) : .delete(id: rest[1])))
            default: return .failure(.usage("models の使い方: models | models download <ID> | models delete <ID>"))
            }
        case "replay":
            return options(rest, allowed: ["--speaker", "--title", "--locale", "--hold", "--wait", "--preset", "--model", "--actors", "--judge"], positional: 1).flatMap { parsed in
                let speakerText = parsed.values["--speaker"] ?? "others"
                guard let speaker = Speaker(rawValue: speakerText) else { return .failure(.usage("--speaker は you か others です")) }
                let chosen: TranscriptionChoice
                switch model(parsed.values["--model"]) {
                case .success(let value): chosen = value
                case .failure(let error): return .failure(error)
                }
                if let judge = parsed.values["--judge"], DecisionModelCatalog.model(id: judge) == nil {
                    return .failure(.usage("知らない判断モデルです: \(judge)（\(DecisionModelCatalog.all.map(\.id).joined(separator: "・"))）"))
                }
                var seconds: [String: Double] = ["--hold": 0, "--wait": 0]
                for name in ["--hold", "--wait"] {
                    if let text = parsed.values[name] {
                        guard let value = Double(text), value >= 0, value <= 3600 else { return .failure(.usage("\(name) は 0〜3600 の秒数です")) }
                        seconds[name] = value
                    }
                }
                return .success(.replay(ReplayOptions(
                    file: parsed.positional[0], speaker: speaker,
                    title: parsed.values["--title"] ?? "replay-" + URL(fileURLWithPath: parsed.positional[0]).deletingPathExtension().lastPathComponent,
                    locale: parsed.values["--locale"] ?? defaultLocale, hold: seconds["--hold"] ?? 0, wait: seconds["--wait"] ?? 0, preset: parsed.values["--preset"], model: chosen, actors: parsed.values["--actors"], judge: parsed.values["--judge"]
                )))
            }
        case _ where LaunchableAgent(rawValue: first) != nil:
            return .success(.launch(agent: LaunchableAgent(rawValue: first)!, arguments: rest))
        case "mcp":
            if rest.isEmpty { return .success(.mcp(channel: false)) }
            if rest == ["--channel"] { return .success(.mcp(channel: true)) }
            return .failure(.usage("mcp に渡せるのは --channel だけです"))
        default:
            return .failure(.usage("知らないコマンドです: \(first)"))
        }
    }

    /// `--model` の値を、一度だけ検査して、選択にする。無指定は、Mac 標準。
    private static func model(_ value: String?) -> Result<TranscriptionChoice, CLIError> {
        guard let value else { return .success(.apple) }
        guard let choice = TranscriptionChoice(id: value) else { return .failure(.usage(unknownModel(value, includingApple: true, includingDecision: false))) }
        return .success(choice)
    }

    private static func unknownModel(_ value: String, includingApple: Bool, includingDecision: Bool) -> String {
        let ids = (includingApple ? ["apple"] : []) + LocalModelCatalog.all.map(\.id) + (includingDecision ? DecisionModelCatalog.all.map(\.id) : [])
        return "知らないモデルです: \(value)（\(ids.joined(separator: "・"))）"
    }

    private struct Parsed {
        var positional: [String] = []
        var values: [String: String] = [:]
    }

    private static func options(_ arguments: [String], allowed: Set<String>, positional count: Int) -> Result<Parsed, CLIError> {
        var parsed = Parsed()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                guard allowed.contains(argument) else { return .failure(.usage("知らないオプションです: \(argument)")) }
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { return .failure(.usage("\(argument) には値が必要です")) }
                guard parsed.values[argument] == nil else { return .failure(.usage("\(argument) が重複しています")) }
                parsed.values[argument] = arguments[index + 1]
                index += 2
            } else {
                parsed.positional.append(argument)
                index += 1
            }
        }
        guard parsed.positional.count == count else {
            return .failure(.usage(count == 0 ? "余分な引数があります" : "引数が \(count) 個必要です"))
        }
        return .success(parsed)
    }
}
