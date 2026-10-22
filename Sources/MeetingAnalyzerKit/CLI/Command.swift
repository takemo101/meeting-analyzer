import Foundation

public enum AppInfo {
    /// `Resources/Info.plist` の版と同じ（テストで一致を確認する）。
    public static let version = "0.1.0"
    public static let name = "meeting-analyzer"
}

/// CLI の失敗。終了コードは SPEC §3.9：1 = 使い方、2 = 入力、3 = ブリッジ、4 = 文字起こし。
public enum CLIError: Error, Equatable {
    case usage(String)
    case input(String)
    case bridge(code: String, message: String)
    case transcription(String)

    public var exitCode: Int32 {
        switch self {
        case .usage: return 1
        case .input: return 2
        case .bridge: return 3
        case .transcription: return 4
        }
    }

    public var code: String {
        switch self {
        case .usage: return "usage"
        case .input: return "input"
        case .bridge(let code, _): return code
        case .transcription: return "transcription"
        }
    }

    public var message: String {
        switch self {
        case .usage(let text), .input(let text), .transcription(let text): return text
        case .bridge(_, let text): return text
        }
    }
}

public struct ReplayOptions: Equatable {
    public var file: String
    public var bridge: String
    public var speaker: Speaker
    public var meetingId: String
    public var locale: String
    /// トークンのあるディレクトリ。指定が無ければ live-support の既定。
    public var tokenDirectory: String?
}

public enum Command: Equatable {
    case gui
    case help
    case version
    case doctor(locale: String)
    case transcribe(file: String, locale: String)
    case replay(ReplayOptions)
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
            return options(rest, allowed: ["--bridge", "--speaker", "--meeting", "--locale", "--token-dir"], positional: 1).flatMap { parsed in
                guard let bridge = parsed.values["--bridge"] else { return .failure(.usage("--bridge <url> が必要です")) }
                let speakerText = parsed.values["--speaker"] ?? "others"
                guard let speaker = Speaker(rawValue: speakerText) else { return .failure(.usage("--speaker は you か others です")) }
                return .success(.replay(ReplayOptions(
                    file: parsed.positional[0], bridge: bridge, speaker: speaker,
                    meetingId: parsed.values["--meeting"] ?? "replay-" + URL(fileURLWithPath: parsed.positional[0]).deletingPathExtension().lastPathComponent,
                    locale: parsed.values["--locale"] ?? defaultLocale, tokenDirectory: parsed.values["--token-dir"]
                )))
            }
        default:
            return .failure(.usage("知らないコマンドです: \(first)。meeting-analyzer --help を見てください"))
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

public let helpText = """
meeting-analyzer — 会議の音声と画面を分析して、コーディングエージェントへ渡します

使い方
  meeting-analyzer                         メニューバーのアプリを起動する
  meeting-analyzer doctor [--locale L]     この Mac で、その言語のオンデバイス認識が使えるか調べる（既定 ja_JP）
  meeting-analyzer transcribe <音声ファイル> [--locale L]
                                           文字起こしの結果を、1 行 1 件の JSON で標準出力へ出す
  meeting-analyzer replay <音声ファイル> --bridge <URL> [--speaker you|others] [--meeting <名前>]
                          [--locale L] [--token-dir <ディレクトリ>]
                                           音声ファイルを、会議として再生して、ブリッジへ送る。最後に終了の合図を送る
  meeting-analyzer --version | --help

終了コード  0 成功 / 1 使い方 / 2 入力 / 3 ブリッジ / 4 文字起こし
ブリッジ    http://127.0.0.1:<ポート> だけ。トークンは <token-dir>/token（既定 ~/.live-support/token）から読む
"""
