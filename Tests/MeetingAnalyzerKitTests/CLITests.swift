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
        #expect(parse(["transcribe", "a.wav"]) == .success(.transcribe(file: "a.wav", locale: "ja_JP", model: .apple)))
        #expect(parse(["transcribe"]) == .failure(.usage("引数が 1 個必要です")))
        #expect(parse(["transcribe", "a.wav", "b.wav"]) == .failure(.usage("引数が 1 個必要です")))
    }

    @Test("--model：知っているモデルの ID か apple だけ。無指定は apple。知らない ID は、使い方の誤り。models の引数も、一度だけ検査する")
    func modelOptions() {
        #expect(parse(["transcribe", "a.wav", "--model", "qwen3-asr-0.6b"]) == .success(.transcribe(file: "a.wav", locale: "ja_JP", model: .local("qwen3-asr-0.6b"))))
        #expect(parse(["transcribe", "a.wav", "--model", "apple"]) == .success(.transcribe(file: "a.wav", locale: "ja_JP", model: .apple)))
        guard case .failure(.usage(let message)) = parse(["transcribe", "a.wav", "--model", "gpt"]) else { Issue.record("知らないモデルを断らない"); return }
        #expect(message.contains("gpt") && message.contains("whisper-large-v3-turbo"))
        guard case .success(.replay(let options)) = parse(["replay", "a.wav", "--model", "whisper-large-v3-turbo"]) else { Issue.record("parse failed"); return }
        #expect(options.model == .local("whisper-large-v3-turbo"))
        guard case .success(.replay(let plain)) = parse(["replay", "a.wav"]) else { Issue.record("parse failed"); return }
        #expect(plain.model == .apple)
        #expect(parse(["replay", "a.wav", "--model", "x"]) != .success(.replay(plain)))

        #expect(parse(["models"]) == .success(.models(.list)))
        #expect(parse(["models", "download", "qwen3-asr-1.7b"]) == .success(.models(.download(id: "qwen3-asr-1.7b"))))
        #expect(parse(["models", "delete", "qwen3-asr-1.7b"]) == .success(.models(.delete(id: "qwen3-asr-1.7b"))))
        for bad in [["models", "download"], ["models", "download", "nope"], ["models", "apple"], ["models", "download", "apple"], ["models", "list", "x", "y"]] {
            guard case .failure(.usage) = parse(bad) else { Issue.record("\(bad) を断らない"); return }
        }
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

    @Test("エージェントの名前は、以降の引数を、そのまま渡す（オプションも、最初の発言も）")
    func launch() {
        #expect(parse(["claude"]) == .success(.launch(agent: .claude, arguments: [])))
        #expect(parse(["claude", "--resume", "--model", "opus", "会議を始めます"]) == .success(.launch(agent: .claude, arguments: ["--resume", "--model", "opus", "会議を始めます"])))
        for agent in LaunchableAgent.allCases { #expect(parse([agent.rawValue, "-x"]) == .success(.launch(agent: agent, arguments: ["-x"]))) }
    }

    @Test("知らないコマンド・オプション、値の欠落、重複、不正な値は、使い方の誤り")
    func rejections() {
        for bad in [["bogus"], ["doctor", "--nope", "x"], ["doctor", "--locale"], ["doctor", "--locale", "--other"], ["doctor", "--locale", "a", "--locale", "b"], ["replay", "a.wav", "--speaker", "everyone"], ["replay", "a.wav", "--hold", "-1"], ["replay", "a.wav", "--hold", "soon"], ["replay", "a.wav", "--wait", "5000"], ["replay", "a.wav", "--bridge", "http://127.0.0.1:1"], ["doctor", "extra"]] {
            guard case .failure(let error) = parse(bad) else { Issue.record("\(bad) was accepted"); continue }
            #expect(error.exitCode == 1, "\(bad)")
        }
    }

    @Test("終了コードは、使い方 1・入力 2・窓口 3・文字起こし 4・エージェント 5")
    func exitCodes() {
        #expect(CLIError.usage("").exitCode == 1)
        #expect(CLIError.input("").exitCode == 2)
        #expect(CLIError.hub(code: "x", message: "").exitCode == 3)
        #expect(CLIError.transcription("").exitCode == 4)
        #expect(CLIError.agent("").exitCode == 5)
    }
}

/// `models` と `--model` の実行（通信・モデルは、差し替える）。
@Suite("CLIRunner: models と --model")
struct CLIModelsTests {
    private func environment(_ data: URL) -> [String: String] { ["MEETING_ANALYZER_DATA_DIR": data.path] }

    @Test("models：パイプでは、モデルごとに 1 行の JSON（未取得。文字起こし → 話者の推定 → 声の分離の順。kind つき）。置き場所は、データの置き場所の models/")
    func list() async {
        let out = Collected<String>(), err = Collected<String>()
        let data = tempURL("models-cli")
        let code = await CLIRunner(environment: environment(data), out: { out.add($0) }, err: { err.add($0) }).run(.models(.list))
        #expect(code == 0)
        let rows = out.values.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        #expect(rows.map { $0["id"] as? String } == LocalModelCatalog.all.map(\.id) + DecisionModelCatalog.all.map(\.id) + VoiceModelCatalog.all.map(\.id))
        #expect(rows.map { $0["kind"] as? String } == LocalModelCatalog.all.map { _ in "transcription" } + DecisionModelCatalog.all.map { _ in "decision" } + VoiceModelCatalog.all.map { _ in "voice" })
        #expect(rows.allSatisfy { $0["installed"] as? Bool == false && $0["downloadedBytes"] as? Int == 0 })
    }

    @Test("models download：音声区間の検出のモデルと、選んだモデルを、この順に取得する。成功は ok。通信の失敗は、終了コード 4（続きから再開できると伝える）")
    func download() async {
        let calls = Collected<String>(), out = Collected<String>(), err = Collected<String>()
        let data = tempURL("models-cli-dl")
        let download: CLIRunner.ModelDownload = { artifact, store, progress in
            calls.add(artifact.filename + "@" + store.directory.path)
            progress(artifact.bytes, artifact.bytes)
        }
        let code = await CLIRunner(environment: environment(data), out: { out.add($0) }, err: { err.add($0) }, modelDownload: download).run(.models(.download(id: "qwen3-asr-0.6b")))
        #expect(code == 0)
        #expect(calls.values == ["silero-vad-v6.2-F32.gguf@\(data.path)/models", "Qwen3-ASR-0.6B-Q8_0.gguf@\(data.path)/models"])
        #expect((try? JSONSerialization.jsonObject(with: Data((out.values.last ?? "").utf8)) as? [String: Any])?["ok"] as? Bool == true)

        let failingErr = Collected<String>()
        let failing: CLIRunner.ModelDownload = { _, _, _ in throw ModelDownloadError.network("offline") }
        let failedCode = await CLIRunner(environment: environment(data), out: { _ in }, err: { failingErr.add($0) }, modelDownload: failing).run(.models(.download(id: "qwen3-asr-0.6b")))
        #expect(failedCode == 4 && errorCode(failingErr.values.last) == "transcription")
        #expect(failingErr.values.last?.contains("続きから") == true && failingErr.values.last?.contains("offline") == true)
    }

    @Test("transcribe --model：選んだモデルと、データの置き場所のモデルの保管場所を、文字起こしの部品へ渡す")
    func transcribeWithModel() async throws {
        let seen = Collected<String>(), out = Collected<String>()
        let data = tempURL("models-cli-tr")
        let provider: CLIRunner.UpdatesProvider = { _, _, choice, store in
            seen.add("\(choice.id)@\(store.directory.path)")
            return AsyncThrowingStream { $0.yield(TranscriptionUpdate(text: "こんにちは", isFinal: true, start: 0, end: 1)); $0.finish() }
        }
        let code = await CLIRunner(environment: environment(data), out: { out.add($0) }, err: { _ in }, updates: provider).run(.transcribe(file: try audioFile().path, locale: "ja_JP", model: .local("whisper-large-v3-turbo")))
        #expect(code == 0 && seen.values == ["whisper-large-v3-turbo@\(data.path)/models"])
        #expect(out.values.count == 1)
    }

    @Test("選んだモデルが取得されていなければ、終了コード 4 で、取得の方法を示す（Mac 標準へ、黙って切り替えない）")
    func missingModel() async throws {
        let err = Collected<String>()
        let data = tempURL("models-cli-missing")
        let code = await CLIRunner(environment: environment(data), out: { _ in }, err: { err.add($0) }).run(.transcribe(file: try audioFile().path, locale: "ja_JP", model: .local("qwen3-asr-0.6b")))
        #expect(code == 4 && errorCode(err.values.last) == "transcription")
        #expect(err.values.last?.contains("models download") == true)
    }
}

/// ソケットのパスは 103 バイトまで。一時ディレクトリの深い場所は使えないので、短い場所に作る。
private func shortSocketPath() -> String { "/tmp/ma-" + UUID().uuidString.prefix(8).lowercased() + ".sock" }

private func errorCode(_ line: String?) -> String? {
    guard let line, let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
    return object["code"] as? String
}

private func audioFile() throws -> URL {
    let url = tempURL("audio", ext: "aiff")
    try Data([0]).write(to: url)
    return url
}

private func fakeUpdates(_ items: [TranscriptionUpdate], failure: TranscriptionError? = nil) -> CLIRunner.UpdatesProvider {
    { _, _, _, _ in
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

    private func runner(out: Collected<String>, err: Collected<String>, environment: [String: String] = [:], updates: @escaping CLIRunner.UpdatesProvider) -> CLIRunner {
        CLIRunner(environment: environment, out: { out.add($0) }, err: { err.add($0) }, updates: updates)
    }

    @Test("replay は、窓口を開けて、開始・バッチ・終了の出来事を、つながった受け手へ出し、結果を 1 行の JSON で出す")
    func replayDeliversThroughHub() async throws {
        let out = Collected<String>(), err = Collected<String>()
        let data = tempURL("data")
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

        #expect(code == 0, "\(err.values)")
        #expect(kinds.first == "started" && kinds.last == "ended" && kinds.dropFirst().dropLast().allSatisfy { $0 == "captions" } && kinds.count >= 3)
        let info = try #require(ended.flatMap { envelope -> SessionEnd? in if case .ended(let end) = envelope.event { return end } else { return nil } })
        #expect(info.utterances == 1)
        #expect(info.durationSeconds == 3, "再生の長さは、音声の長さ（2.5 秒）。処理時間ではない")
        let last = try #require(out.values.last)
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
        let out = Collected<String>(), err = Collected<String>()
        let options = ReplayOptions(file: try audioFile().path, speaker: .others, title: "m", locale: "ja_JP", hold: 0, wait: 0)
        let code = await runner(out: out, err: err, environment: ["MEETING_ANALYZER_SOCKET": socket], updates: fakeUpdates(sample)).run(.replay(options))
        #expect(code == 3)
        #expect(errorCode(err.values.last) == "hub_unavailable")
        #expect(out.values.isEmpty)
    }

    @Test("読めない音声ファイルは、入力の失敗（終了コード 2）")
    func unreadableAudio() async throws {
        let out = Collected<String>(), err = Collected<String>()
        let options = ReplayOptions(file: "/nonexistent/x.aiff", speaker: .others, title: "m", locale: "ja_JP", hold: 0, wait: 0)
        #expect(await runner(out: out, err: err, updates: fakeUpdates([])).run(.replay(options)) == 2)
        #expect(await runner(out: out, err: err, updates: fakeUpdates([])).run(.transcribe(file: "/nonexistent/x.aiff", locale: "ja_JP", model: .apple)) == 2)
    }

    @Test("文字起こしの失敗は、終了コード 4。記録を書かず、終了の出来事も出さない")
    func transcriptionFailure() async throws {
        let out = Collected<String>(), err = Collected<String>()
        let data = tempURL("data")
        defer { try? FileManager.default.removeItem(at: data) }
        let options = ReplayOptions(file: try audioFile().path, speaker: .others, title: "m", locale: "ja_JP", hold: 0, wait: 0)
        let code = await runner(out: out, err: err, environment: ["MEETING_ANALYZER_DATA_DIR": data.path, "MEETING_ANALYZER_SOCKET": shortSocketPath()], updates: fakeUpdates(sample, failure: .unsupportedLocale("xx_XX"))).run(.replay(options))
        #expect(code == 4)
        #expect(out.values.isEmpty, "失敗した再生を、正常な終了として知らせない")
        #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent("sessions").path))
    }

    @Test("claude は、アプリの窓口を確かめ、MCP の設定（チャンネル）と利用者の引数を付けて、claude に置き換わる")
    func claudeLaunch() async {
        let out = Collected<String>(), err = Collected<String>()
        let calls = Collected<String>()
        let runner = CLIRunner(
            environment: ["MEETING_ANALYZER_SOCKET": "/tmp/ma-none.sock"], out: { out.add($0) }, err: { err.add($0) },
            updates: fakeUpdates([]),
            replaceProcess: { command, arguments in calls.add(([command] + arguments).joined(separator: "\u{1F}")); return 0 },
            executablePath: { "/Apps/MeetingAnalyzer.app/Contents/MacOS/MeetingAnalyzer" }
        )
        let code = await runner.run(.launch(agent: .claude, arguments: ["会議を始めます", "--resume"]))
        let call = calls.values.first?.components(separatedBy: "\u{1F}") ?? []
        #expect(call.first == "claude")
        #expect(Array(call.dropFirst().prefix(2)) == ["会議を始めます", "--resume"], "利用者の引数が先")
        #expect(call.suffix(2) == ["--dangerously-load-development-channels", "server:meeting-analyzer-channel"], "チャンネルの指定は、最後")
        #expect(code == 5, "replaceProcess が戻った（置き換えに失敗した）なら、エージェントを起動できない失敗")
        #expect(errorCode(err.values.last) == "agent_unavailable")
    }

    @Test("MCP の設定は、このアプリの実行ファイルを --channel で呼ぶ。窓口を変えているときは、同じ値を mcp にも渡す")
    func claudeMcpConfig() throws {
        let plain = try #require(JSONSerialization.jsonObject(with: Data(AgentLauncher.mcpConfig(executable: "/x/y", environment: [:]).utf8)) as? [String: Any])
        let server = try #require((plain["mcpServers"] as? [String: Any])?["meeting-analyzer-channel"] as? [String: Any])
        #expect(server["command"] as? String == "/x/y" && server["args"] as? [String] == ["mcp", "--channel"])
        #expect(server["env"] == nil)
        let isolated = try #require(JSONSerialization.jsonObject(with: Data(AgentLauncher.mcpConfig(executable: "/x/y", environment: ["MEETING_ANALYZER_SOCKET": "/tmp/s.sock", "MEETING_ANALYZER_DATA_DIR": ""]).utf8)) as? [String: Any])
        let env = ((isolated["mcpServers"] as? [String: Any])?["meeting-analyzer-channel"] as? [String: Any])?["env"] as? [String: String]
        #expect(env == ["MEETING_ANALYZER_SOCKET": "/tmp/s.sock"], "空の値は渡さない")
    }

    @Test("アプリを起動するのは、窓口を既定の場所にしているときだけ。動いていれば、何もしない")
    func ensureApp() throws {
        let launched = Collected<String>()
        let unreachable = shortSocketPath()
        // 場所を変えている（検証・隔離）：実際のアプリは起動しない。
        #expect(!AgentLauncher.ensureAppRunning(environment: ["MEETING_ANALYZER_SOCKET": unreachable], wait: 0.2, launch: { launched.add("x"); return true }))
        #expect(launched.values.isEmpty)
        // 動いている：起動しない。
        let hub = HubServer(socketPath: unreachable)
        try hub.start()
        defer { hub.stop() }
        #expect(AgentLauncher.ensureAppRunning(environment: ["MEETING_ANALYZER_SOCKET": unreachable], wait: 0.2, launch: { launched.add("y"); return true }))
        #expect(launched.values.isEmpty)
    }

    @Test("transcribe は、確定した結果だけを 1 行ずつ出す")
    func transcribeOutputsFinals() async throws {
        let out = Collected<String>(), err = Collected<String>()
        let code = await runner(out: out, err: err, updates: fakeUpdates(sample)).run(.transcribe(file: try audioFile().path, locale: "ja_JP", model: .apple))
        #expect(code == 0)
        #expect(out.values.count == 1)
        let line = try #require(JSONSerialization.jsonObject(with: Data(out.values[0].utf8)) as? [String: Any])
        #expect(line["text"] as? String == "来週のリリースの件です")
        #expect(line["isFinal"] as? Bool == true)
    }

    @Test("help と version は、そのまま出す")
    func helpAndVersion() async {
        let out = Collected<String>(), err = Collected<String>()
        let r = runner(out: out, err: err, updates: fakeUpdates([]))
        #expect(await r.run(.version) == 0)
        #expect(out.values.last == "meeting-analyzer \(AppInfo.version)")
        #expect(await r.run(.help) == 0)
        #expect(out.values.last?.contains("replay") == true)
    }
}
