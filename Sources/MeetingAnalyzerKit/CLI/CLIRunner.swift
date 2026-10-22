import Foundation

extension BridgeError {
    var cliError: CLIError {
        switch self {
        case .unreachable: return .bridge(code: "bridge_unreachable", message: "ブリッジに接続できません。エージェント側（live-support claude など）が起動しているか確認してください")
        case .unauthorized: return .bridge(code: "bridge_unauthorized", message: "トークンが合いません。エージェントを起動し直すと、トークンが更新されます")
        case .notReady: return .bridge(code: "bridge_not_ready", message: "ブリッジが、まだ受け付けられる状態ではありません（エージェントのセッションが未接続）")
        case .rejected(let status): return .bridge(code: "bridge_rejected", message: "ブリッジが内容を断りました（HTTP \(status)）")
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

/// CLI の実行。標準出力・標準エラーと、文字起こし・送信の部品を差し替えられる（検証とテスト用）。
public struct CLIRunner {
    public typealias UpdatesProvider = @Sendable (URL, Locale) -> AsyncThrowingStream<TranscriptionUpdate, Error>
    public typealias SenderFactory = @Sendable (BridgeEndpoint) -> any BridgeSending

    private let environment: [String: String]
    private let out: @Sendable (String) -> Void
    private let err: @Sendable (String) -> Void
    private let updates: UpdatesProvider
    private let makeSender: SenderFactory

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        out: @escaping @Sendable (String) -> Void,
        err: @escaping @Sendable (String) -> Void,
        updates: @escaping UpdatesProvider = { url, locale in AppleSpeechTranscriber().updates(forFile: url, locale: locale) },
        makeSender: @escaping SenderFactory = { BridgeClient(endpoint: $0) }
    ) {
        self.environment = environment
        self.out = out
        self.err = err
        self.updates = updates
        self.makeSender = makeSender
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

    private func replay(_ options: ReplayOptions) async throws {
        let file = try readableFile(options.file)
        let directory = options.tokenDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? RuntimePaths.liveSupportDirectory(environment: environment)
        let token: String
        switch TokenStore.read(directory: directory) {
        case .success(let value): token = value
        case .failure: throw CLIError.bridge(code: "token_missing", message: "トークンを読めません: \(directory.path)/token（エージェント側を一度起動してください）")
        }
        let endpoint: BridgeEndpoint
        switch BridgeEndpoint.parse(url: options.bridge, token: token) {
        case .success(let value): endpoint = value
        case .failure(.notLoopbackHTTP): throw CLIError.bridge(code: "endpoint_invalid", message: "ブリッジは http://127.0.0.1:<ポート> だけに送れます")
        case .failure(.shortToken): throw CLIError.bridge(code: "token_invalid", message: "トークンが短すぎる、または空白を含みます")
        }
        let sender = makeSender(endpoint)
        do { try await sender.health() } catch let error as BridgeError { throw error.cliError }

        let pipeline = SessionPipeline(meetingId: options.meetingId, sender: sender, store: SessionStore(root: RuntimePaths.dataDirectory(environment: environment)))
        var lastEnd: TimeInterval = 0
        do {
            for try await update in updates(file, Locale(identifier: options.locale)) {
                try await pipeline.ingest(update, speaker: options.speaker)
                lastEnd = max(lastEnd, update.end)
            }
            // 再生なので、会議の長さは、処理にかかった時間でなく、音声の長さにする。
            let end = try await pipeline.finish(reason: .user, endedAt: pipeline.startedAt.addingTimeInterval(lastEnd), at: lastEnd)
            var summary: [String: Any] = ["ok": true, "sessionId": end.sessionId, "batches": end.batches, "utterances": end.utterances, "durationSeconds": end.durationSeconds]
            if let path = end.transcriptPath { summary["transcriptPath"] = path }
            out(Self.json(summary))
        } catch let error as BridgeError { throw error.cliError }
        catch let error as TranscriptionError { throw error.cliError }
    }
}
