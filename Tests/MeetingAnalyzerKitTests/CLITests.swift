import Foundation
import Testing
@testable import MeetingAnalyzerKit

@Suite("CommandParser: 引数は一度だけ検査して型にする")
struct CommandParserTests {
    private func parse(_ arguments: [String]) -> Result<Command, CLIError> { CommandParser.parse(arguments) }

    @Test("引数なしは、メニューバーのアプリを起動する")
    func noArgumentsIsGUI() {
        #expect(parse([]) == .success(.gui))
    }

    @Test("help と version")
    func helpAndVersion() {
        #expect(parse(["--help"]) == .success(.help))
        #expect(parse(["help"]) == .success(.help))
        #expect(parse(["--version"]) == .success(.version))
        #expect(parse(["--version", "x"]) == .failure(.usage("--version に引数はありません")))
    }

    @Test("doctor と transcribe は、言語が既定で ja_JP")
    func doctorAndTranscribe() {
        #expect(parse(["doctor"]) == .success(.doctor(locale: "ja_JP")))
        #expect(parse(["doctor", "--locale", "en_US"]) == .success(.doctor(locale: "en_US")))
        #expect(parse(["transcribe", "a.wav"]) == .success(.transcribe(file: "a.wav", locale: "ja_JP")))
        #expect(parse(["transcribe"]) == .failure(.usage("引数が 1 個必要です")))
        #expect(parse(["transcribe", "a.wav", "b.wav"]) == .failure(.usage("引数が 1 個必要です")))
    }

    @Test("replay は --bridge が必須。発言者の既定は相手、会議名の既定は音声ファイル名から")
    func replay() throws {
        #expect(parse(["replay", "a.wav"]) == .failure(.usage("--bridge <url> が必要です")))
        guard case .success(.replay(let options)) = parse(["replay", "/x/sample.aiff", "--bridge", "http://127.0.0.1:1"]) else { Issue.record("parse failed"); return }
        #expect(options.speaker == .others)
        #expect(options.meetingId == "replay-sample")
        #expect(options.locale == "ja_JP")
        #expect(options.tokenDirectory == nil)
        guard case .success(.replay(let custom)) = parse(["replay", "a.wav", "--bridge", "http://127.0.0.1:1", "--speaker", "you", "--meeting", "定例", "--token-dir", "/t"]) else { Issue.record("parse failed"); return }
        #expect(custom.speaker == .you && custom.meetingId == "定例" && custom.tokenDirectory == "/t")
    }

    @Test("知らないコマンド・オプション、値の欠落、重複、不正な値は、使い方の誤り")
    func rejections() {
        for bad in [["bogus"], ["doctor", "--nope", "x"], ["doctor", "--locale"], ["doctor", "--locale", "--other"], ["doctor", "--locale", "a", "--locale", "b"], ["replay", "a.wav", "--bridge", "u", "--speaker", "everyone"], ["doctor", "extra"]] {
            guard case .failure(let error) = parse(bad) else { Issue.record("\(bad) was accepted"); continue }
            #expect(error.exitCode == 1, "\(bad)")
        }
    }

    @Test("終了コードは、使い方 1・入力 2・ブリッジ 3・文字起こし 4")
    func exitCodes() {
        #expect(CLIError.usage("").exitCode == 1)
        #expect(CLIError.input("").exitCode == 2)
        #expect(CLIError.bridge(code: "x", message: "").exitCode == 3)
        #expect(CLIError.transcription("").exitCode == 4)
    }
}

/// 出力を溜めるだけ。
final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

private func tokenDirectory(_ token: String? = String(repeating: "k", count: 43)) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ma-cli-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    if let token { try Data(token.utf8).write(to: url.appendingPathComponent("token")) }
    return url
}

private func errorCode(_ line: String?) -> String? {
    guard let line, let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
    return object["code"] as? String
}

private func audioFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ma-audio-" + UUID().uuidString + ".aiff")
    try Data([0]).write(to: url)
    return url
}

private func fakeUpdates(_ items: [TranscriptionUpdate], failure: TranscriptionError? = nil) -> CLIRunner.UpdatesProvider {
    { _, _ in
        AsyncThrowingStream { continuation in
            for item in items { continuation.yield(item) }
            continuation.finish(throwing: failure)
        }
    }
}

@Suite("CLIRunner: replay・transcribe・失敗の出し方")
struct CLIRunnerTests {
    private let sample = [
        TranscriptionUpdate(text: "来週の", isFinal: false, start: 0, end: 1),
        TranscriptionUpdate(text: "来週のリリースの件です", isFinal: true, start: 0, end: 2.5),
    ]

    private func runner(out: Output, err: Output, environment: [String: String] = [:], updates: @escaping CLIRunner.UpdatesProvider, sender: RecordingSender) -> CLIRunner {
        CLIRunner(environment: environment, out: { out.add($0) }, err: { err.add($0) }, updates: updates, makeSender: { _ in sender })
    }

    @Test("replay は、バッチを送り、最後に終了の合図を送り、結果を 1 行の JSON で出す")
    func replaySuccess() async throws {
        let out = Output(), err = Output(), sender = RecordingSender()
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("ma-data-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: data) }
        let options = ReplayOptions(file: try audioFile().path, bridge: "http://127.0.0.1:43821", speaker: .others, meetingId: "定例", locale: "ja_JP", tokenDirectory: try tokenDirectory().path)
        let code = await runner(out: out, err: err, environment: ["MEETING_ANALYZER_DATA_DIR": data.path], updates: fakeUpdates(sample), sender: sender).run(.replay(options))

        #expect(code == 0, "\(err.lines)")
        #expect(sender.events.last == "end")
        #expect(sender.batches.flatMap(\.updates).last?.transcript == "来週のリリースの件です")
        let last = try #require(out.lines.last)
        let summary = try #require(JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any])
        #expect(summary["ok"] as? Bool == true)
        #expect(summary["utterances"] as? Int == 1)
        #expect(summary["durationSeconds"] as? Int == 3, "再生の長さは、音声の長さ（2.5 秒）。処理時間ではない")
        let path = try #require(summary["transcriptPath"] as? String)
        #expect(path.hasPrefix(data.path))
    }

    @Test("トークンが読めない・送り先が不正・ブリッジが落ちている、は、ブリッジの失敗（終了コード 3）で、何も送らない")
    func bridgeFailures() async throws {
        let file = try audioFile().path
        let cases: [(ReplayOptions, String)] = [
            (ReplayOptions(file: file, bridge: "http://127.0.0.1:1", speaker: .others, meetingId: "m", locale: "ja_JP", tokenDirectory: try tokenDirectory(nil).path), "token_missing"),
            (ReplayOptions(file: file, bridge: "https://example.com", speaker: .others, meetingId: "m", locale: "ja_JP", tokenDirectory: try tokenDirectory().path), "endpoint_invalid"),
            (ReplayOptions(file: file, bridge: "http://127.0.0.1:1", speaker: .others, meetingId: "m", locale: "ja_JP", tokenDirectory: try tokenDirectory("short").path), "token_invalid"),
        ]
        for (options, expected) in cases {
            let out = Output(), err = Output(), sender = RecordingSender()
            let code = await runner(out: out, err: err, updates: fakeUpdates(sample), sender: sender).run(.replay(options))
            #expect(code == 3, "\(expected)")
            #expect(sender.events.isEmpty)
            #expect(errorCode(err.lines.last) == expected)
        }
        for (error, expected) in [(BridgeError.unreachable, "bridge_unreachable"), (.unauthorized, "bridge_unauthorized"), (.notReady, "bridge_not_ready")] {
            let out = Output(), err = Output(), sender = RecordingSender()
            sender.healthError = error
            let options = ReplayOptions(file: file, bridge: "http://127.0.0.1:1", speaker: .others, meetingId: "m", locale: "ja_JP", tokenDirectory: try tokenDirectory().path)
            #expect(await runner(out: out, err: err, updates: fakeUpdates(sample), sender: sender).run(.replay(options)) == 3)
            #expect(errorCode(err.lines.last) == expected)
            #expect(sender.events.isEmpty, "文字起こしを始める前に、確認で止まる")
        }
    }

    @Test("読めない音声ファイルは、入力の失敗（終了コード 2）")
    func unreadableAudio() async throws {
        let out = Output(), err = Output()
        let options = ReplayOptions(file: "/nonexistent/x.aiff", bridge: "http://127.0.0.1:1", speaker: .others, meetingId: "m", locale: "ja_JP", tokenDirectory: try tokenDirectory().path)
        #expect(await runner(out: out, err: err, updates: fakeUpdates([]), sender: RecordingSender()).run(.replay(options)) == 2)
        #expect(await runner(out: out, err: err, updates: fakeUpdates([]), sender: RecordingSender()).run(.transcribe(file: "/nonexistent/x.aiff", locale: "ja_JP")) == 2)
    }

    @Test("文字起こしの失敗は、終了コード 4。途中までの内容に終了の合図を付けて送らない")
    func transcriptionFailure() async throws {
        let out = Output(), err = Output(), sender = RecordingSender()
        let options = ReplayOptions(file: try audioFile().path, bridge: "http://127.0.0.1:1", speaker: .others, meetingId: "m", locale: "ja_JP", tokenDirectory: try tokenDirectory().path)
        let code = await runner(out: out, err: err, updates: fakeUpdates(sample, failure: .unsupportedLocale("xx_XX")), sender: sender).run(.replay(options))
        #expect(code == 4)
        #expect(!sender.events.contains("end"), "失敗した再生を、正常な会議の終了として知らせない")
    }

    @Test("transcribe は、確定した結果だけを 1 行ずつ出す")
    func transcribeOutputsFinals() async throws {
        let out = Output(), err = Output()
        let code = await runner(out: out, err: err, updates: fakeUpdates(sample), sender: RecordingSender()).run(.transcribe(file: try audioFile().path, locale: "ja_JP"))
        #expect(code == 0)
        #expect(out.lines.count == 1)
        let line = try #require(JSONSerialization.jsonObject(with: Data(out.lines[0].utf8)) as? [String: Any])
        #expect(line["text"] as? String == "来週のリリースの件です")
        #expect(line["isFinal"] as? Bool == true)
    }

    @Test("help と version は、そのまま出す")
    func helpAndVersion() async {
        let out = Output(), err = Output()
        let r = runner(out: out, err: err, updates: fakeUpdates([]), sender: RecordingSender())
        #expect(await r.run(.version) == 0)
        #expect(out.lines.last == "meeting-analyzer \(AppInfo.version)")
        #expect(await r.run(.help) == 0)
        #expect(out.lines.last?.contains("replay") == true)
    }
}
