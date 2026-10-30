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
        case .modelUnavailable(let name): return .transcription("文字起こしのモデル「\(name)」が、ダウンロードされていません（`meeting-analyzer models download` で取得できます）")
        }
    }
}

/// CLI の実行。標準出力・標準エラーと、文字起こしの部品を差し替えられる（検証とテスト用）。
public struct CLIRunner {
    /// 音声ファイルの文字起こし。`TranscriptionChoice` で、Mac 標準か、ダウンロードしたモデルかを選ぶ（後者は、`ModelStore` のモデルを使う）。
    public typealias UpdatesProvider = @Sendable (URL, Locale, TranscriptionChoice, ModelStore) -> AsyncThrowingStream<TranscriptionUpdate, Error>
    /// モデルのダウンロード（試験で差し替える）。`progress`：（取得済み、全体）のバイト数。
    public typealias ModelDownload = @Sendable (ModelArtifact, ModelStore, @escaping @Sendable (Int64, Int64) -> Void) async throws -> Void

    private let environment: [String: String]
    private let out: @Sendable (String) -> Void
    private let err: @Sendable (String) -> Void
    private let updates: UpdatesProvider
    private let modelDownload: ModelDownload
    private let replaceProcess: @Sendable (String, [String]) -> Int32
    private let setEnvironment: @Sendable ([String: String]) -> Void
    private let executablePath: @Sendable () -> String
    private let presetStore: PresetStore
    private let outStyle: TerminalStyle
    private let errStyle: TerminalStyle
    /// 標準出力・標準エラーが端末なら、人が読む形で出す。そうでなければ（パイプ・ファイル）、JSON（SPEC §3.9）。
    private let outIsTerminal: Bool
    private let errIsTerminal: Bool

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        out: @escaping @Sendable (String) -> Void,
        err: @escaping @Sendable (String) -> Void,
        updates: @escaping UpdatesProvider = { url, locale, choice, store in
            switch choice {
            case .apple: return AppleSpeechTranscriber().updates(forFile: url, locale: locale)
            case .local(let id):
                guard let model = LocalModelCatalog.model(id: id) else { return AsyncThrowingStream { $0.finish(throwing: TranscriptionError.modelUnavailable(id)) } }
                return LocalTranscriber.updates(forFile: url, model: model, store: store)
            }
        },
        modelDownload: @escaping ModelDownload = { artifact, store, progress in try await ModelDownloader(store: store).download(artifact, progress: progress) },
        replaceProcess: @escaping @Sendable (String, [String]) -> Int32 = { AgentLauncher.replaceProcess(command: $0, arguments: $1) },
        executablePath: @escaping @Sendable () -> String = { URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path },
        setEnvironment: @escaping @Sendable ([String: String]) -> Void = { for (name, value) in $0 { setenv(name, value, 1) } },
        presetStore: PresetStore? = nil,
        outIsTerminal: Bool = false,
        errIsTerminal: Bool = false
    ) {
        self.environment = environment
        self.out = out
        self.err = err
        self.updates = updates
        self.modelDownload = modelDownload
        self.replaceProcess = replaceProcess
        self.setEnvironment = setEnvironment
        self.executablePath = executablePath
        self.presetStore = presetStore ?? PresetStore.standard(environment: environment)
        self.outIsTerminal = outIsTerminal
        self.errIsTerminal = errIsTerminal
        self.outStyle = .detect(isTerminal: outIsTerminal, environment: environment)
        self.errStyle = .detect(isTerminal: errIsTerminal, environment: environment)
    }

    /// 終了コードを返す。失敗は、標準エラーへ出す（端末なら、人が読む形。そうでなければ、1 行の JSON `{"ok":false,"code":...,"message":...}`）。
    public func run(_ command: Command) async -> Int32 {
        do {
            switch command {
            case .gui: return 0   // 呼び出し側（App）が処理する
            case .help: out(CLIView.help(outStyle))
            case .version: out("\(AppInfo.name) \(AppInfo.version)")
            case .doctor(let locale): try await doctor(locale)
            case .presets: listPresets()
            case .actorsCheck(let file): try actorsCheck(file)
            case .transcribe(let file, let locale, let model): try await transcribe(file, locale, model)
            case .models(let action): try await models(action)
            case .replay(let options): try await replay(options)
            case .launch(let agent, let arguments): try launch(agent, arguments)
            case .mcp(let channel): await MCPRunner.run(mode: channel ? .channel : .tools, socketPath: RuntimePaths.hubSocket(environment: environment))
            }
            return 0
        } catch let error as CLIError {
            return report(error)
        } catch {
            err(errIsTerminal ? CLIView.failure(.input("\(error)"), errStyle) : Self.json(["ok": false, "code": "internal", "message": "\(error)"]))
            return 1
        }
    }

    /// 失敗を、標準エラーへ出し、終了コードを返す。
    public func report(_ error: CLIError) -> Int32 {
        err(errIsTerminal ? CLIView.failure(error, errStyle) : Self.json(["ok": false, "code": error.code, "message": error.message]))
        return error.exitCode
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func doctor(_ localeId: String) async throws {
        let readiness = await SpeechReadiness.check(locale: Locale(identifier: localeId))
        out(outIsTerminal ? CLIView.doctor(readiness, outStyle) : Self.json(["locale": readiness.locale, "supported": readiness.supported, "installed": readiness.installed]))
    }

    /// ダウンロード式のモデルの、一覧・取得・削除（SPEC §3.12）。一覧は、端末では表、パイプでは 1 行 1 件の JSON。
    private func models(_ action: ModelsCommand) async throws {
        let store = modelStore
        switch action {
        case .list:
            if outIsTerminal { out(CLIView.models(LocalModelCatalog.all, store: store, directory: store.directory.path, outStyle)); return }
            for model in LocalModelCatalog.all {
                out(Self.json(["id": model.id, "name": model.name, "bytes": model.artifact.bytes, "installed": store.isInstalled(model.artifact), "downloadedBytes": store.downloadedBytes(model.artifact)]))
            }
        case .download(let id):
            guard let model = LocalModelCatalog.model(id: id) else { throw CLIError.usage("知らないモデルです: \(id)") }
            let interactive = errIsTerminal
            let report = ProgressLine(enabled: interactive, write: err)
            do {
                // 音声区間の検出のモデル（小さい）も、一緒に取得する。
                try await modelDownload(LocalModelCatalog.voiceActivity, store) { _, _ in }
                try await modelDownload(model.artifact, store) { received, total in report.update(name: model.name, received: received, total: total) }
            } catch let error as ModelDownloadError {
                report.finish()
                throw CLIError.transcription("ダウンロードできませんでした: \(Self.describe(error))（もう一度実行すると、続きから取得します）")
            }
            report.finish()
            out(outIsTerminal ? CLIView.modelDownloaded(model, store.fileURL(model.artifact).path, outStyle) : Self.json(["ok": true, "id": model.id, "path": store.fileURL(model.artifact).path]))
        case .delete(let id):
            guard let model = LocalModelCatalog.model(id: id) else { throw CLIError.usage("知らないモデルです: \(id)") }
            store.delete(model.artifact)
            out(outIsTerminal ? "\(model.name) を削除しました" : Self.json(["ok": true, "id": model.id, "deleted": true]))
        }
    }

    private static func describe(_ error: ModelDownloadError) -> String {
        switch error {
        case .network(let reason): return "通信に失敗しました（\(reason)）"
        case .badStatus(let code): return "サーバーが、想定外の応答（\(code)）を返しました"
        case .sizeMismatch: return "ファイルの大きさが、想定と違います"
        case .checksumMismatch: return "ファイルの検証（SHA-256）に通りません"
        case .cancelled: return "取り消されました"
        case .writeFailed(let reason): return "ディスクに書けません（\(reason)）"
        }
    }

    /// 選べるプリセット。端末では表、パイプでは 1 行 1 件の JSON（読めなかったファイルは、`skipped` つきで続ける）。
    private func listPresets() {
        let (presets, skipped) = presetStore.load()
        if outIsTerminal {
            out(CLIView.presets(presets, skipped: skipped, userDirectory: presetStore.userDirectory.path, outStyle))
            return
        }
        for preset in presets {
            out(Self.json(["id": preset.id, "name": preset.name, "source": preset.source == .user ? "user" : "builtin", "description": preset.summary]))
        }
        for item in skipped { out(Self.json(["skipped": item.file, "reason": item.reason])) }
    }

    private func readableFile(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw CLIError.input("ファイルを読めません: \(path)") }
        return url
    }

    private var modelStore: ModelStore { ModelStore(root: RuntimePaths.dataDirectory(environment: environment)) }

    private func transcribe(_ path: String, _ localeId: String, _ model: TranscriptionChoice) async throws {
        let file = try readableFile(path)
        do {
            for try await update in updates(file, Locale(identifier: localeId), model, modelStore) where update.isFinal {
                out(outIsTerminal ? CLIView.transcript(text: update.text, start: update.start, end: update.end, outStyle) : Self.json(["text": update.text, "isFinal": true, "start": update.start, "end": update.end]))
            }
        } catch let error as TranscriptionError { throw error.cliError }
    }

    /// エージェントを、MCP サーバーつきで起動する。このプロセスを置き換えるので、成功すると戻らない。
    /// Claude Code は、その起動だけに設定を渡す。ほかのエージェントは、設定ファイルへ、`meeting-analyzer` の 1 件を登録する（初回・場所が変わったときだけ）。
    private func launch(_ agent: LaunchableAgent, _ userArguments: [String]) throws {
        let executable = executablePath()
        let ready = AgentLauncher.ensureAppRunning(environment: environment)
        let registration = agent == .claude
            ? nil
            : AgentSetup.ensureRegistered(agent, executable: executable, environment: environment, profile: AgentLauncher.profile(in: userArguments))
        var manualText: String?
        if case .manual = registration { manualText = AgentRegistration.allCases.first { $0.title.hasPrefix(agent.rawValue) }?.text(executable: executable) }
        let pushesToOpencode = agent == .opencode && AgentLauncher.pushesToOpencode(userArguments)
        err(CLIView.launch(agent: agent, appConnected: ready, registration: registration, registrationText: manualText, pushes: agent != .opencode || pushesToOpencode, errStyle) + "\n")
        let arguments = AgentLauncher.arguments(
            agent: agent, userArguments: userArguments, executable: executable, environment: environment,
            skillPath: AgentLauncher.bundledSkillPath(executable: executable),
            extensionPath: AgentLauncher.bundledExtensionPath(executable: executable)
        )
        if pushesToOpencode {
            setEnvironment(AgentLauncher.opencodeEnvironment(
                existing: environment["OPENCODE_CONFIG_CONTENT"], pluginPath: AgentLauncher.bundledOpencodePluginPath(executable: executable), skillPath: AgentLauncher.bundledSkillPath(executable: executable)))
        }
        let code = replaceProcess(agent.command, arguments)
        throw CLIError.agent(code == ENOENT
            ? "\(agent.command) が見つかりません（\(agent.command) を入れて、PATH を通してください）"
            : "\(agent.command) を起動できません（errno \(code)）")
    }

    /// `ACTOR.md` を読んで、書式を検査し、読み取れた内容を出す（SPEC §3.13）。読めなければ、理由と一緒に、入力の誤りとして断る。
    private func actorsCheck(_ path: String) throws {
        let absolute = URL(fileURLWithPath: path).path
        switch ActorFile.load(path: absolute) {
        case .failure(let error): throw CLIError.input(error.message)
        case .success(let list):
            if outIsTerminal { out(CLIView.actors(list, path: absolute, outStyle)); return }
            let actors: [[String: Any]] = list.actors.map { actor in
                var item: [String: Any] = ["name": actor.name, "aliases": actor.aliases, "topics": actor.topics, "self": actor.isSelf]
                if let role = actor.role { item["role"] = role }
                return item
            }
            out(Self.json(["ok": true, "path": absolute, "actors": actors, "warnings": list.warnings]))
        }
    }

    /// 音声ファイルを、セッションとして再生する。実機と同じ流れ（パイプライン → ハブ → 記録）を通し、ハブの窓口を開く。
    /// `--hold` の間、窓口を開けたままにして、エージェント（`meeting-analyzer mcp`）が読めるようにする。
    /// `--actors` があれば、その `ACTOR.md` で、発話に名前を付ける（「本人」は対応づけ、「相手」は、Mac 標準の言語モデルで推定する）。
    private func replay(_ options: ReplayOptions) async throws {
        let file = try readableFile(options.file)
        var preset: PresetInfo?
        if let id = options.preset {
            guard let found = presetStore.all().first(where: { $0.id == id }) else { throw CLIError.input("プリセットが見つかりません: \(id)（meeting-analyzer presets で一覧を見られます）") }
            preset = found.info
        } else {
            preset = presetStore.resolve(id: nil)?.info
        }
        var actorSource: ActorSource?
        var labeler: SpeakerLabeler?
        if let path = options.actors {
            let absolute = URL(fileURLWithPath: path).path
            switch ActorFile.load(path: absolute) {
            case .failure(let error): throw CLIError.input(error.message)
            case .success(let list):
                var guesser: SpeakerGuesser?
                if options.speaker == .others, !list.others.isEmpty {
                    if case .unavailable(let reason) = AppleSpeakerJudge.availability(locale: Locale(identifier: options.locale)) { throw CLIError.input("話者を推定できません: \(reason)") }
                    guesser = SpeakerGuesser(list: list, judge: AppleSpeakerJudge())
                }
                actorSource = ActorSource(list: list, file: absolute)
                labeler = SpeakerLabeler(list: list, guesser: guesser)
            }
        }
        let hub = HubServer(socketPath: RuntimePaths.hubSocket(environment: environment))
        do { try hub.start() } catch let error as HubError { throw error.cliError }
        defer { hub.stop() }
        // エージェントがつながるのを待つ（つながったら、すぐ始める。上限を過ぎたら、待たずに始める）。
        let deadline = Date().addingTimeInterval(options.wait)
        while hub.clientCount == 0 && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }

        let pipeline = SessionPipeline(title: options.title, sink: hub, store: SessionStore(root: RuntimePaths.dataDirectory(environment: environment)), preset: preset, actors: actorSource)
        pipeline.begin(sources: [options.speaker])
        var lastEnd: TimeInterval = 0
        do {
            for try await update in updates(file, Locale(identifier: options.locale), options.model, modelStore) {
                var actor: ActorLabel?
                if let labeler, options.speaker == .you || update.isFinal {
                    do { actor = try await labeler.label(options.speaker, update.text) } catch { throw CLIError.input("話者の推定に失敗しました") }
                }
                pipeline.ingest(update, speaker: options.speaker, actor: actor)
                lastEnd = max(lastEnd, update.end)
            }
        } catch let error as TranscriptionError { throw error.cliError }
        // 再生なので、セッションの長さは、処理にかかった時間でなく、音声の長さにする。
        let event = pipeline.finish(reason: .user, endedAt: pipeline.startedAt.addingTimeInterval(lastEnd), at: lastEnd)
        guard case .ended(let sessionId, _, _, _, _, let duration, let batches, let utterances, let path) = event else { return }
        if outIsTerminal {
            out(CLIView.replaySummary(sessionId: sessionId, utterances: utterances, batches: batches, duration: TimeInterval(duration), path: path, outStyle))
        } else {
            var summary: [String: Any] = ["ok": true, "sessionId": sessionId, "batches": batches, "utterances": utterances, "durationSeconds": duration]
            if let path { summary["transcriptPath"] = path }
            out(Self.json(summary))
        }
        if options.hold > 0 { try? await Task.sleep(for: .seconds(options.hold)) }
    }
}
