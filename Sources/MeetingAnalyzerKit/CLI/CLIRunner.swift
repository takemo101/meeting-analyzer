import Foundation

extension HubError {
    var cliError: CLIError {
        switch self {
        case .alreadyRunning(let path): return .hub(code: "hub_unavailable", message: "エージェントへ渡す窓口が使用中です（実行中の meeting-analyzer がある）: \(path)")
        case .pathTooLong(let path): return .hub(code: "hub_path_too_long", message: "窓口のパスが長すぎます（103 バイトまで）: \(path)")
        case .failed(let reason): return .hub(code: "hub_unavailable", message: reason)
        }
    }
}

extension TranscriptionError {
    var cliError: CLIError {
        switch self {
        case .unsupportedLocale(let id): return .transcription("この Mac では、\(id) のオンデバイス認識を使えません")
        case .unreadableAudio(let path): return .input("音声ファイルを開けません: \(path)")
        case .failed(let text): return .transcription(text)
        }
    }
}

/// CLI の実行。標準出力・標準エラーと、文字起こしの部品を差し替えられる（検証とテスト用）。
public struct CLIRunner {
    public typealias UpdatesProvider = @Sendable (URL, Locale) -> AsyncThrowingStream<TranscriptionUpdate, Error>

    private let environment: [String: String]
    private let out: @Sendable (String) -> Void
    private let err: @Sendable (String) -> Void
    private let updates: UpdatesProvider

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        out: @escaping @Sendable (String) -> Void,
        err: @escaping @Sendable (String) -> Void,
        updates: @escaping UpdatesProvider = { url, locale in AppleSpeechTranscriber().updates(forFile: url, locale: locale) }
    ) {
        self.environment = environment
        self.out = out
        self.err = err
        self.updates = updates
    }

    /// 終了コードを返す。失敗は、標準エラーに 1 行の JSON（`{"ok":false,"code":...,"message":...}`）で出す。
    public func run(_ command: Command) async -> Int32 {
        do {
            switch command {
            case .gui: return 0   // 呼び出し側（App）が処理する
            case .help: out(helpText)
            case .version: out("\(AppInfo.name) \(AppInfo.version)")
            case .doctor(let locale): try await doctor(locale)
            case .transcribe(let file, let locale): try await transcribe(file, locale)
            case .replay(let options): try await replay(options)
            case .mcp(let channel): await MCPRunner.run(mode: channel ? .channel : .tools, socketPath: RuntimePaths.hubSocket(environment: environment))
            }
            return 0
        } catch let error as CLIError {
            err(Self.json(["ok": false, "code": error.code, "message": error.message]))
            return error.exitCode
        } catch {
            err(Self.json(["ok": false, "code": "internal", "message": "\(error)"]))
            return 1
        }
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func doctor(_ localeId: String) async throws {
        let readiness = await SpeechReadiness.check(locale: Locale(identifier: localeId))
        out(Self.json(["locale": readiness.locale, "supported": readiness.supported, "installed": readiness.installed]))
    }

    private func readableFile(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw CLIError.input("ファイルを読めません: \(path)") }
        return url
    }

    private func transcribe(_ path: String, _ localeId: String) async throws {
        let file = try readableFile(path)
        do {
            for try await update in updates(file, Locale(identifier: localeId)) where update.isFinal {
                out(Self.json(["text": update.text, "isFinal": true, "start": update.start, "end": update.end]))
            }
        } catch let error as TranscriptionError { throw error.cliError }
    }

    /// 音声ファイルを、セッションとして再生する。実機と同じ流れ（パイプライン → ハブ → 記録）を通し、ハブの窓口を開く。
    /// `--hold` の間、窓口を開けたままにして、エージェント（`meeting-analyzer mcp`）が読めるようにする。
    private func replay(_ options: ReplayOptions) async throws {
        let file = try readableFile(options.file)
        let hub = HubServer(socketPath: RuntimePaths.hubSocket(environment: environment))
        do { try hub.start() } catch let error as HubError { throw error.cliError }
        defer { hub.stop() }
        // エージェントがつながるのを待つ（つながったら、すぐ始める。上限を過ぎたら、待たずに始める）。
        let deadline = Date().addingTimeInterval(options.wait)
        while hub.clientCount == 0 && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }

        let pipeline = SessionPipeline(title: options.title, sink: hub, store: SessionStore(root: RuntimePaths.dataDirectory(environment: environment)))
        pipeline.begin(sources: [options.speaker])
        var lastEnd: TimeInterval = 0
        do {
            for try await update in updates(file, Locale(identifier: options.locale)) {
                pipeline.ingest(update, speaker: options.speaker)
                lastEnd = max(lastEnd, update.end)
            }
        } catch let error as TranscriptionError { throw error.cliError }
        // 再生なので、セッションの長さは、処理にかかった時間でなく、音声の長さにする。
        let event = pipeline.finish(reason: .user, endedAt: pipeline.startedAt.addingTimeInterval(lastEnd), at: lastEnd)
        guard case .ended(let sessionId, _, _, _, _, let duration, let batches, let utterances, let path) = event else { return }
        var summary: [String: Any] = ["ok": true, "sessionId": sessionId, "batches": batches, "utterances": utterances, "durationSeconds": duration]
        if let path { summary["transcriptPath"] = path }
        out(Self.json(summary))
        if options.hold > 0 { try? await Task.sleep(for: .seconds(options.hold)) }
    }
}
