import Foundation

public enum AppInfo {
    /// `Resources/Info.plist` の版と同じ（テストで一致を確認する）。
    public static let version = "0.1.0"
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
}

public enum Command: Equatable {
    case gui
    case help
    case version
    case doctor(locale: String)
    case transcribe(file: String, locale: String)
    case replay(ReplayOptions)
    /// エージェント向けの MCP サーバー（標準入出力）。`channel` なら、Claude Code の Channels の通知も出す。
    case mcp(channel: Bool)
    /// エージェント（Claude Code・pi・omp・agy・opencode）を、このアプリの MCP サーバーつきで起動する。`arguments` は、そのままエージェントへ渡す。
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
        case "doctor":
            return options(rest, allowed: ["--locale"], positional: 0).map { .doctor(locale: $0.values["--locale"] ?? defaultLocale) }
        case "transcribe":
            return options(rest, allowed: ["--locale"], positional: 1).map { .transcribe(file: $0.positional[0], locale: $0.values["--locale"] ?? defaultLocale) }
        case "replay":
            return options(rest, allowed: ["--speaker", "--title", "--locale", "--hold", "--wait"], positional: 1).flatMap { parsed in
                let speakerText = parsed.values["--speaker"] ?? "others"
                guard let speaker = Speaker(rawValue: speakerText) else { return .failure(.usage("--speaker は you か others です")) }
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
                    locale: parsed.values["--locale"] ?? defaultLocale, hold: seconds["--hold"] ?? 0, wait: seconds["--wait"] ?? 0
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
