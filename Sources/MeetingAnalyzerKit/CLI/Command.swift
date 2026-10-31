import Foundation

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

/// `replay` のオプション（読み取りの境界 `CommandParser` で、検査して作る）。初期化は、メンバーワイズ（宣言の順）。
public struct ReplayOptions: Equatable {
    public var file: String
    public var speaker: Speaker
    public var title: String
    public var locale: String
    /// 再生が終わってから、窓口を開けておく秒数（エージェントが読めるように）。
    public var hold: Double = 0
    /// 再生を始める前に、エージェントがつながるのを待つ秒数の上限（つながったら、すぐ始める）。
    public var wait: Double = 0
    /// 開始の出来事で渡す、分析のプリセットの ID（SPEC §3.11）。無指定なら、既定。
    public var preset: String?
    /// 使う文字起こし（SPEC §3.12）。無指定なら、Mac 標準。
    public var model: TranscriptionChoice = .apple
    /// 使う `ACTOR.md` のパス（SPEC §3.13）。無指定なら、アクターを使わない。
    public var actors: String?
    /// 話者の推定に使う判断モデルの ID（`DecisionModelCatalog`。SPEC §3.13）。無指定なら、推定しない（「相手」のまま）。
    public var judge: String?
    /// 出席者の名前（相手の側の人。SPEC §3.13）。無指定なら、ACTOR.md の全員。
    public var attendees: [String]?
    /// 話者の判断の単位（SPEC §3.13）。既定は、文ごと。
    public var unit: JudgmentUnit = .default
}

/// `actors try` のオプション：ACTOR.md と判断モデルで、1 つの本文、または、評価の件（`--cases`）を、判断して見せる（SPEC §3.13）。
public struct ActorsTryOptions: Equatable {
    public enum Input: Equatable {
        /// 本文 1 つ。
        case text(String)
        /// 評価の件のファイル（JSON Lines。`SpeakerEvalCase`）。
        case cases(String)
    }

    public var file: String
    /// 判断モデルの ID（`DecisionModelCatalog`）。
    public var judge: String
    /// 試す判断の単位（`both` なら、両方を、同じ入力で比べる）。
    public var units: [JudgmentUnit]
    public var attendees: [String]?
    /// 名前を付けてよいかの条件（`--min-confidence`・`--max-filler`・`--rival`。無指定は、会議と同じ既定）。
    public var gate: SpeakerGate = SpeakerGate()
    public var input: Input
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
    /// `ACTOR.md` と判断モデルで、本文・評価の件を、判断して見せる（診断。SPEC §3.13）。
    case actorsTry(ActorsTryOptions)
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

    /// オプションの名前（検査する場所・許す一覧で、同じ文字列を重ねて書かない）。
    private enum Option {
        static let speaker = "--speaker", title = "--title", locale = "--locale", hold = "--hold", wait = "--wait"
        static let preset = "--preset", model = "--model", actors = "--actors", judge = "--judge", attendees = "--attendees"
        static let unit = "--unit", cases = "--cases"
        static let minConfidence = "--min-confidence", maxFiller = "--max-filler", rival = "--rival"
        static let replay: Set = [speaker, title, locale, hold, wait, preset, model, actors, judge, attendees, unit]
        static let actorsTry: Set = [judge, attendees, unit, cases, minConfidence, maxFiller, rival]
    }

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
            if rest.first == "try" { return actorsTryOptions(Array(rest.dropFirst())).map { .actorsTry($0) } }
            guard rest.count == 2, rest[0] == "check" else { return .failure(.usage("actors の使い方: actors check <ACTOR.md> | actors try <ACTOR.md> --judge <ID> [--unit sentence|utterance|both] [--attendees 名前,名前] [--min-confidence 0〜1] [--max-filler 0〜1] [--rival 0〜1] (<本文> | --cases <ファイル>)")) }
            return .success(.actorsCheck(file: rest[1]))
        case "doctor":
            return options(rest, allowed: [Option.locale], positional: 0).map { .doctor(locale: $0.values[Option.locale] ?? defaultLocale) }
        case "transcribe":
            return options(rest, allowed: [Option.locale, Option.model], positional: 1).flatMap { parsed in
                model(parsed.values[Option.model]).map { .transcribe(file: parsed.positional[0], locale: parsed.values[Option.locale] ?? defaultLocale, model: $0) }
            }
        case "models":
            switch rest.count {
            case 0: return .success(.models(.list))
            case 2 where rest[0] == "download" || rest[0] == "delete":
                guard LocalModelCatalog.model(id: rest[1]) != nil || DecisionModelCatalog.model(id: rest[1]) != nil || VoiceModelCatalog.model(id: rest[1]) != nil else { return .failure(.usage(unknownModel(rest[1], includingApple: false, includingDecision: true))) }
                return .success(.models(rest[0] == "download" ? .download(id: rest[1]) : .delete(id: rest[1])))
            default: return .failure(.usage("models の使い方: models | models download <ID> | models delete <ID>"))
            }
        case "replay":
            return options(rest, allowed: Option.replay, positional: 1).flatMap(replayOptions).map { .replay($0) }
        case "mcp":
            if rest.isEmpty { return .success(.mcp(channel: false)) }
            if rest == ["--channel"] { return .success(.mcp(channel: true)) }
            return .failure(.usage("mcp に渡せるのは --channel だけです"))
        default:
            if let agent = LaunchableAgent(rawValue: first) { return .success(.launch(agent: agent, arguments: rest)) }
            return .failure(.usage("知らないコマンドです: \(first)"))
        }
    }

    /// `replay` の値を、一度だけ検査して、型にする（検査の順：話者 → モデル → 判断モデル → 出席者 → 秒数）。
    private static func replayOptions(_ parsed: Parsed) -> Result<ReplayOptions, CLIError> {
        let values = parsed.values
        guard let speaker = Speaker(rawValue: values[Option.speaker] ?? "others") else { return .failure(.usage("--speaker は you か others です")) }
        return model(values[Option.model]).flatMap { chosen in
            let unit: JudgmentUnit
            switch units(values[Option.unit], allowBoth: false) {
            case .success(let value): unit = value[0]
            case .failure(let error): return .failure(error)
            }
            if let judge = values[Option.judge], DecisionModelCatalog.model(id: judge) == nil {
                return .failure(.usage("知らない判断モデルです: \(judge)（\(DecisionModelCatalog.all.map(\.id).joined(separator: "・"))）"))
            }
            if values[Option.attendees] != nil, values[Option.actors] == nil { return .failure(.usage("--attendees は、--actors と一緒に使います")) }
            return seconds(Option.hold, values).flatMap { hold in
                seconds(Option.wait, values).map { wait in
                    let file = parsed.positional[0]
                    return ReplayOptions(
                        file: file, speaker: speaker, title: values[Option.title] ?? "replay-" + URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent,
                        locale: values[Option.locale] ?? defaultLocale, hold: hold, wait: wait, preset: values[Option.preset], model: chosen,
                        actors: values[Option.actors], judge: values[Option.judge], attendees: values[Option.attendees].map(names), unit: unit
                    )
                }
            }
        }
    }

    /// `actors try` の値を、一度だけ検査して、型にする。
    private static func actorsTryOptions(_ arguments: [String]) -> Result<ActorsTryOptions, CLIError> {
        let withCases = arguments.contains(Option.cases)
        return options(arguments, allowed: Option.actorsTry, positional: withCases ? 1 : 2).flatMap { parsed in
            let values = parsed.values
            guard let judge = values[Option.judge] else { return .failure(.usage("--judge が必要です（\(DecisionModelCatalog.all.map(\.id).joined(separator: "・"))）")) }
            guard DecisionModelCatalog.model(id: judge) != nil else { return .failure(.usage("知らない判断モデルです: \(judge)（\(DecisionModelCatalog.all.map(\.id).joined(separator: "・"))）")) }
            return units(values[Option.unit], allowBoth: true).flatMap { units in
                gate(values).map { gate in
                    ActorsTryOptions(
                        file: parsed.positional[0], judge: judge, units: units, attendees: values[Option.attendees].map(names), gate: gate,
                        input: values[Option.cases].map { .cases($0) } ?? .text(parsed.positional[1])
                    )
                }
            }
        }
    }

    /// 名前を付けてよいかの条件（0〜1。無指定は、`SpeakerGate` の既定）。
    private static func gate(_ values: [String: String]) -> Result<SpeakerGate, CLIError> {
        var gate = SpeakerGate()
        for (name, keyPath) in [(Option.minConfidence, \SpeakerGate.minimumConfidence), (Option.maxFiller, \SpeakerGate.maximumFiller), (Option.rival, \SpeakerGate.rivalConfidence)] {
            guard let text = values[name] else { continue }
            guard let value = Double(text), value >= 0, value <= 1 else { return .failure(.usage("\(name) は 0〜1 の確率です")) }
            gate[keyPath: keyPath] = value
        }
        return .success(gate)
    }

    /// `--unit` の値（`sentence`・`utterance`。`allowBoth` なら `both`＝両方）。無指定は、既定（文ごと）。
    private static func units(_ value: String?, allowBoth: Bool) -> Result<[JudgmentUnit], CLIError> {
        guard let value else { return .success([.default]) }
        if allowBoth, value == "both" { return .success(JudgmentUnit.allCases) }
        guard let unit = JudgmentUnit(rawValue: value) else { return .failure(.usage("--unit は \((JudgmentUnit.allCases.map(\.rawValue) + (allowBoth ? ["both"] : [])).joined(separator: "・")) のどれかです")) }
        return .success([unit])
    }

    /// 秒数のオプション（0〜3600）。無指定は 0。
    private static func seconds(_ name: String, _ values: [String: String]) -> Result<Double, CLIError> {
        guard let text = values[name] else { return .success(0) }
        guard let value = Double(text), value >= 0, value <= 3600 else { return .failure(.usage("\(name) は 0〜3600 の秒数です")) }
        return .success(value)
    }

    /// 「、」または「,」で区切った名前（前後の空白を除き、空は捨てる）。
    private static func names(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "、" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `--model` の値を、一度だけ検査して、選択にする。無指定は、Mac 標準。
    private static func model(_ value: String?) -> Result<TranscriptionChoice, CLIError> {
        guard let value else { return .success(.apple) }
        guard let choice = TranscriptionChoice(id: value) else { return .failure(.usage(unknownModel(value, includingApple: true, includingDecision: false))) }
        return .success(choice)
    }

    private static func unknownModel(_ value: String, includingApple: Bool, includingDecision: Bool) -> String {
        let ids = (includingApple ? ["apple"] : []) + LocalModelCatalog.all.map(\.id) + (includingDecision ? DecisionModelCatalog.all.map(\.id) + VoiceModelCatalog.all.map(\.id) : [])
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
