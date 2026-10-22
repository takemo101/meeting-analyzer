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

    @Test("replay の既定：発言者は相手、名前は音声ファイル名から、窓口を開けておく秒数は 0")
    func replay() throws {
        guard case .success(.replay(let options)) = parse(["replay", "/x/sample.aiff"]) else { Issue.record("parse failed"); return }
        #expect(options.speaker == .others)
        #expect(options.title == "replay-sample")
        #expect(options.locale == "ja_JP")
        #expect(options.hold == 0 && options.wait == 0)
        guard case .success(.replay(let custom)) = parse(["replay", "a.wav", "--speaker", "you", "--title", "定例", "--hold", "2.5", "--wait", "4"]) else { Issue.record("parse failed"); return }
        #expect(custom.speaker == .you && custom.title == "定例" && custom.hold == 2.5 && custom.wait == 4)
    }

    @Test("mcp は、引数なしでツールだけ。--channel で Channels の通知つき")
    func mcp() {
        #expect(parse(["mcp"]) == .success(.mcp(channel: false)))
        #expect(parse(["mcp", "--channel"]) == .success(.mcp(channel: true)))
        #expect(parse(["mcp", "--other"]) == .failure(.usage("mcp に渡せるのは --channel だけです")))
    }

    @Test("知らないコマンド・オプション、値の欠落、重複、不正な値は、使い方の誤り")
    func rejections() {
        for bad in [["bogus"], ["doctor", "--nope", "x"], ["doctor", "--locale"], ["doctor", "--locale", "--other"], ["doctor", "--locale", "a", "--locale", "b"], ["replay", "a.wav", "--speaker", "everyone"], ["replay", "a.wav", "--hold", "-1"], ["replay", "a.wav", "--hold", "soon"], ["replay", "a.wav", "--wait", "5000"], ["replay", "a.wav", "--bridge", "http://127.0.0.1:1"], ["doctor", "extra"]] {
            guard case .failure(let error) = parse(bad) else { Issue.record("\(bad) was accepted"); continue }
            #expect(error.exitCode == 1, "\(bad)")
        }
    }

    @Test("終了コードは、使い方 1・入力 2・窓口 3・文字起こし 4")
    func exitCodes() {
        #expect(CLIError.usage("").exitCode == 1)
        #expect(CLIError.input("").exitCode == 2)
        #expect(CLIError.hub(code: "x", message: "").exitCode == 3)
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

/// ソケットのパスは 103 バイトまで。一時ディレクトリの深い場所は使えないので、短い場所に作る。
private func shortSocketPath() -> String { "/tmp/ma-" + UUID().uuidString.prefix(8).lowercased() + ".sock" }

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

    private func runner(out: Output, err: Output, environment: [String: String] = [:], updates: @escaping CLIRunner.UpdatesProvider) -> CLIRunner {
        CLIRunner(environment: environment, out: { out.add($0) }, err: { err.add($0) }, updates: updates)
    }

    @Test("replay は、窓口を開けて、開始・バッチ・終了の出来事を、つながった受け手へ出し、結果を 1 行の JSON で出す")
    func replayDeliversThroughHub() async throws {
        let out = Output(), err = Output()
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("ma-data-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: data) }
        let socket = shortSocketPath()
        let environment = ["MEETING_ANALYZER_DATA_DIR": data.path, "MEETING_ANALYZER_SOCKET": socket]
        let options = ReplayOptions(file: try audioFile().path, speaker: .others, title: "定例", locale: "ja_JP", hold: 3, wait: 0)
        let run = Task { await runner(out: out, err: err, environment: environment, updates: fakeUpdates(sample)).run(.replay(options)) }

        // 窓口が開いている間に、受け手としてつながる（実際の `meeting-analyzer mcp` と同じ部品）。
        var kinds: [String] = []
        var ended: HubEnvelope?
        let deadline = Date().addingTimeInterval(8)
        loop: for await event in HubClient(socketPath: socket, retryInterval: 0.05).events() {
            guard case .message(.event(let envelope)) = event else { if Date() > deadline { break loop }; continue }
            kinds.append(envelope.event.kind)
            if envelope.event.kind == "ended" { ended = envelope; break loop }
            if Date() > deadline { break loop }
        }
        let code = await run.value

        #expect(code == 0, "\(err.lines)")
        #expect(kinds.first == "started" && kinds.last == "ended" && kinds.dropFirst().dropLast().allSatisfy { $0 == "captions" } && kinds.count >= 3)
        let info = try #require(ended.flatMap { EndedInfo($0.event) })
        #expect(info.utterances == 1)
        #expect(info.durationSeconds == 3, "再生の長さは、音声の長さ（2.5 秒）。処理時間ではない")
        let last = try #require(out.lines.last)
        let summary = try #require(JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any])
        #expect(summary["ok"] as? Bool == true && summary["utterances"] as? Int == 1)
        let path = try #require(summary["transcriptPath"] as? String)
        #expect(path.hasPrefix(data.path))
        #expect(!FileManager.default.fileExists(atPath: socket), "終わったら、窓口は閉じる")
    }

    @Test("窓口が使用中（実行中のアプリがある）なら、終了コード 3 で、何も始めない")
    func hubBusy() async throws {
        let socket = shortSocketPath()
        let other = HubServer(socketPath: socket)
        try other.start()
        defer { other.stop() }
        let out = Output(), err = Output()
        let options = ReplayOptions(file: try audioFile().path, speaker: .others, title: "m", locale: "ja_JP", hold: 0, wait: 0)
        let code = await runner(out: out, err: err, environment: ["MEETING_ANALYZER_SOCKET": socket], updates: fakeUpdates(sample)).run(.replay(options))
        #expect(code == 3)
        #expect(errorCode(err.lines.last) == "hub_unavailable")
        #expect(out.lines.isEmpty)
    }

    @Test("読めない音声ファイルは、入力の失敗（終了コード 2）")
    func unreadableAudio() async throws {
        let out = Output(), err = Output()
        let options = ReplayOptions(file: "/nonexistent/x.aiff", speaker: .others, title: "m", locale: "ja_JP", hold: 0, wait: 0)
        #expect(await runner(out: out, err: err, updates: fakeUpdates([])).run(.replay(options)) == 2)
        #expect(await runner(out: out, err: err, updates: fakeUpdates([])).run(.transcribe(file: "/nonexistent/x.aiff", locale: "ja_JP")) == 2)
    }

    @Test("文字起こしの失敗は、終了コード 4。記録を書かず、終了の出来事も出さない")
    func transcriptionFailure() async throws {
        let out = Output(), err = Output()
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("ma-data-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: data) }
        let options = ReplayOptions(file: try audioFile().path, speaker: .others, title: "m", locale: "ja_JP", hold: 0, wait: 0)
        let code = await runner(out: out, err: err, environment: ["MEETING_ANALYZER_DATA_DIR": data.path, "MEETING_ANALYZER_SOCKET": shortSocketPath()], updates: fakeUpdates(sample, failure: .unsupportedLocale("xx_XX"))).run(.replay(options))
        #expect(code == 4)
        #expect(out.lines.isEmpty, "失敗した再生を、正常な終了として知らせない")
        #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent("sessions").path))
    }

    @Test("transcribe は、確定した結果だけを 1 行ずつ出す")
    func transcribeOutputsFinals() async throws {
        let out = Output(), err = Output()
        let code = await runner(out: out, err: err, updates: fakeUpdates(sample)).run(.transcribe(file: try audioFile().path, locale: "ja_JP"))
        #expect(code == 0)
        #expect(out.lines.count == 1)
        let line = try #require(JSONSerialization.jsonObject(with: Data(out.lines[0].utf8)) as? [String: Any])
        #expect(line["text"] as? String == "来週のリリースの件です")
        #expect(line["isFinal"] as? Bool == true)
    }

    @Test("help と version は、そのまま出す")
    func helpAndVersion() async {
        let out = Output(), err = Output()
        let r = runner(out: out, err: err, updates: fakeUpdates([]))
        #expect(await r.run(.version) == 0)
        #expect(out.lines.last == "meeting-analyzer \(AppInfo.version)")
        #expect(await r.run(.help) == 0)
        #expect(out.lines.last?.contains("replay") == true)
    }
}
