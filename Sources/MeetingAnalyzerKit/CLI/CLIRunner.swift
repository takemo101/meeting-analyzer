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
        executablePath: @escaping @Sendable () -> String = { BundledResources.currentExecutablePath() },
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
            case .actorsTry(let options): try await actorsTry(options)
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
            err(errIsTerminal ? CLIView.failure(.input("\(error)"), errStyle) : CLIOutput.json(CLIOutput.Failure(code: "internal", message: "\(error)")))
            return 1
        }
    }

    /// 失敗を、標準エラーへ出し、終了コードを返す。
    public func report(_ error: CLIError) -> Int32 {
        err(errIsTerminal ? CLIView.failure(error, errStyle) : CLIOutput.json(CLIOutput.Failure(code: error.code, message: error.message)))
        return error.exitCode
    }

    private func doctor(_ localeId: String) async throws {
        let readiness = await SpeechReadiness.check(locale: Locale(identifier: localeId))
        out(outIsTerminal ? CLIView.doctor(readiness, outStyle) : CLIOutput.json(CLIOutput.Doctor(locale: readiness.locale, supported: readiness.supported, installed: readiness.installed)))
    }

    /// ダウンロード式のモデル（文字起こし・話者の推定）の、一覧・取得・削除（SPEC §3.12・§3.13）。一覧は、端末では表、パイプでは 1 行 1 件の JSON。
    private func models(_ action: ModelsCommand) async throws {
        let store = modelStore
        switch action {
        case .list:
            if outIsTerminal { out(CLIView.models(LocalModelCatalog.all, decision: DecisionModelCatalog.all, store: store, directory: store.directory.path, outStyle)); return }
            for model in LocalModelCatalog.all {
                out(CLIOutput.json(CLIOutput.ModelLine(kind: "transcription", id: model.id, name: model.name, bytes: Int64(model.artifact.bytes), installed: store.isInstalled(model.artifact), downloadedBytes: store.downloadedBytes(model.artifact))))
            }
            for model in DecisionModelCatalog.all {
                out(CLIOutput.json(CLIOutput.ModelLine(kind: "decision", id: model.id, name: model.name, bytes: Int64(model.bytes), installed: store.isInstalled(model), downloadedBytes: store.downloadedBytes(model))))
            }
        case .download(let id):
            let name: String, path: String, plan: ModelInstallPlan
            if let model = LocalModelCatalog.model(id: id) {
                name = model.name; path = store.fileURL(model.artifact).path; plan = ModelInstallPlan(model)
            } else if let model = DecisionModelCatalog.model(id: id) {
                name = model.name; path = store.fileURL(model.weights).path; plan = ModelInstallPlan(model)
            } else {
                throw CLIError.usage("知らないモデルです: \(id)")
            }
            let report = ProgressLine(enabled: errIsTerminal, write: err)
            do {
                try await plan.run(fetch: { [modelDownload] artifact, progress in try await modelDownload(artifact, store, progress) }) { received, total in
                    report.update(name: name, received: received, total: total)
                }
            } catch let error as ModelDownloadError {
                report.finish()
                throw CLIError.transcription("ダウンロードできませんでした: \(error.message)（もう一度実行すると、続きから取得します）")
            }
            report.finish()
            out(outIsTerminal ? CLIView.modelDownloaded(name: name, path: path, outStyle) : CLIOutput.json(CLIOutput.Downloaded(id: id, path: path)))
        case .delete(let id):
            if let model = LocalModelCatalog.model(id: id) {
                store.delete(model.artifact)
                out(outIsTerminal ? "\(model.name) を削除しました" : CLIOutput.json(CLIOutput.Deleted(id: model.id)))
            } else if let model = DecisionModelCatalog.model(id: id) {
                store.delete(model)
                out(outIsTerminal ? "\(model.name) を削除しました" : CLIOutput.json(CLIOutput.Deleted(id: model.id)))
            } else {
                throw CLIError.usage("知らないモデルです: \(id)")
            }
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
            out(CLIOutput.json(CLIOutput.PresetLine(id: preset.id, name: preset.name, source: preset.source == .user ? "user" : "builtin", description: preset.summary)))
        }
        for item in skipped { out(CLIOutput.json(CLIOutput.SkippedPreset(skipped: item.file, reason: item.reason))) }
    }

    private func readableFile(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw CLIError.input("ファイルを読めません: \(path)") }
        return url
    }

    private var dataDirectory: URL { RuntimePaths.dataDirectory(environment: environment) }
    private var modelStore: ModelStore { ModelStore(root: dataDirectory) }

    private func transcribe(_ path: String, _ localeId: String, _ model: TranscriptionChoice) async throws {
        let file = try readableFile(path)
        do {
            for try await update in updates(file, Locale(identifier: localeId), model, modelStore) where update.isFinal {
                out(outIsTerminal ? CLIView.transcript(text: update.text, start: update.start, end: update.end, outStyle) : CLIOutput.json(CLIOutput.Transcript(text: update.text, start: update.start, end: update.end)))
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
            let actors = list.actors.map { CLIOutput.ActorLine(name: $0.name, aliases: $0.aliases, topics: $0.topics, isSelf: $0.isSelf, role: $0.role) }
            out(CLIOutput.json(CLIOutput.ActorsCheck(path: absolute, actors: actors, warnings: list.warnings)))
        }
    }

    /// `ACTOR.md` と判断モデルで、本文 1 つ、または、評価の件（`--cases`）を、判断して見せる（診断。SPEC §3.13）。会議と同じ規則・同じ判断モデル・同じ道（`SpeakerGuesser.segments`）を通す。
    /// 結果は、判断の単位（`--unit`）ごとに出す（`both` なら、同じ入力で、両方を比べられる）。
    private func actorsTry(_ options: ActorsTryOptions) async throws {
        let absolute = URL(fileURLWithPath: options.file).path
        let list: ActorList
        switch ActorFile.load(path: absolute) {
        case .failure(let error): throw CLIError.input(error.message)
        case .success(let loaded): list = loaded
        }
        guard !list.others.isEmpty else { throw CLIError.input("ACTOR.md に、相手の側の人がいません（本人だけでは、判断しません）") }
        let attendance = try replayAttendance(options.attendees, in: list)
        guard let model = DecisionModelCatalog.model(id: options.judge) else { throw CLIError.usage("知らない判断モデルです: \(options.judge)") }
        guard modelStore.isInstalled(model) else {
            throw CLIError.transcription("判断モデル「\(model.name)」が、取得されていません（\(AppInfo.name) models download \(model.id)）")
        }
        let judge: SystemOneJudge
        do {
            judge = try SystemOneJudge(model: model, store: modelStore, candidates: list.others)
            try judge.prepare()
        } catch { throw CLIError.transcription("判断モデルを読み込めません: " + ((error as? DecisionModelError)?.message ?? "\(error)")) }

        let cases: [SpeakerEvalCase]
        if case .cases(let path) = options.input { cases = try evalCases(path, list: list) } else { cases = [] }
        do {
            for unit in options.units {
                let guesser = SpeakerGuesser(list: list, judge: judge, gate: options.gate, attendance: attendance, unit: unit)
                switch options.input {
                case .text(let text): try await printTry(text, unit: unit, guesser: guesser, gate: options.gate)
                case .cases: printEval(try await SpeakerEvaluation.run(cases: cases, guesser: guesser), unit: unit, gate: options.gate)
                }
            }
        } catch let error as DecisionModelError { throw CLIError.transcription("判断に失敗しました: " + error.message) }
    }

    /// 評価の件のファイルを読む（読めない・ACTOR.md の相手の側に無い正解の名前は、断る）。
    private func evalCases(_ path: String, list: ActorList) throws -> [SpeakerEvalCase] {
        let url = try readableFile(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw CLIError.input("ファイルを読めません（UTF-8 の JSON Lines）: \(path)") }
        let cases: [SpeakerEvalCase]
        switch SpeakerEvalCase.parse(jsonLines: text) {
        case .failure(let error): throw CLIError.input(error.message)
        case .success(let parsed): cases = parsed
        }
        let known = Set(list.others.map(\.name))
        if let unknown = cases.flatMap(\.sentences).compactMap(\.actor).first(where: { !known.contains($0) }) { throw CLIError.input(SpeakerEvalError.unknownActor(unknown).message) }
        return cases
    }

    /// 本文 1 つの判断（区間ごとに、付けた名前・理由・上位の候補の確率）。
    private func printTry(_ text: String, unit: JudgmentUnit, guesser: SpeakerGuesser, gate: SpeakerGate) async throws {
        var segments: [CLIOutput.TrySegment] = []
        for segment in try await guesser.segments(text) {
            let decision = try await guesser.decide(segment.text)
            let top = zip(decision.candidates, decision.answer?.probabilities ?? []).sorted { $0.1 > $1.1 }.prefix(3).map { CLIOutput.TryCandidate(name: $0.0.name, probability: CLIOutput.rounded($0.1)) }
            segments.append(CLIOutput.TrySegment(text: segment.text, actor: segment.actor?.name, outcome: decision.outcome.rawValue, filler: decision.answer.map { CLIOutput.rounded($0.filler) }, top: Array(top)))
        }
        let result = CLIOutput.TryResult(unit: unit.rawValue, gate: CLIOutput.Gate(gate), segments: segments)
        out(outIsTerminal ? CLIView.actorsTry(result, unitTitle: unit.title, outStyle) : CLIOutput.json(result))
    }

    private func printEval(_ report: SpeakerEvalReport, unit: JudgmentUnit, gate: SpeakerGate) {
        let result = CLIOutput.EvalReport(report, unit: unit.rawValue, gate: gate)
        out(outIsTerminal ? CLIView.actorsEval(result, unitTitle: unit.title, outStyle) : CLIOutput.json(result))
    }

    /// 音声ファイルを、セッションとして再生する。実機と同じ流れ（パイプライン → ハブ → 記録）を通し、ハブの窓口を開く。
    /// `--hold` の間、窓口を開けたままにして、エージェント（`meeting-analyzer mcp`）が読めるようにする。
    /// `--actors` があれば、その `ACTOR.md` で、発話に名前を付ける（「本人」は対応づけ、「相手」は、`--judge` の判断モデルで推定する）。
    private func replay(_ options: ReplayOptions) async throws {
        let file = try readableFile(options.file)
        let preset = try resolvePreset(options.preset)
        let (actorSource, labeler) = try prepareActors(options)
        let hub = try startHub()
        defer { hub.stop() }
        await waitForAgent(on: hub, upTo: options.wait)

        let pipeline = SessionPipeline(title: options.title, sink: hub, store: SessionStore(root: dataDirectory), preset: preset, actors: actorSource)
        pipeline.begin(sources: [options.speaker])
        let lastEnd = try await play(file, options, labeler: labeler, into: pipeline)
        // 再生なので、セッションの長さは、処理にかかった時間でなく、音声の長さにする。
        let end = pipeline.finish(reason: .user, endedAt: pipeline.startedAt.addingTimeInterval(lastEnd), at: lastEnd)
        printReplaySummary(end)
        if options.hold > 0 { try? await Task.sleep(for: .seconds(options.hold)) }
    }

    /// 開始の出来事で渡すプリセット。指定があれば、その ID（無ければ、断る）。無指定なら、既定。
    private func resolvePreset(_ id: String?) throws -> PresetInfo? {
        guard let id else { return presetStore.resolve(id: nil)?.info }
        guard let found = presetStore.all().first(where: { $0.id == id }) else { throw CLIError.input("プリセットが見つかりません: \(id)（meeting-analyzer presets で一覧を見られます）") }
        return found.info
    }

    /// `--actors` の `ACTOR.md` と、発話へ名前を付ける部品（指定が無ければ、どちらも無し）。読めない・出席者の名前が無い・判断モデルが無い・読み込めないときは、断る。
    private func prepareActors(_ options: ReplayOptions) throws -> (ActorSource?, SpeakerLabeler?) {
        guard let path = options.actors else { return (nil, nil) }
        let absolute = URL(fileURLWithPath: path).path
        let list: ActorList
        switch ActorFile.load(path: absolute) {
        case .failure(let error): throw CLIError.input(error.message)
        case .success(let loaded): list = loaded
        }
        let attendance = try replayAttendance(options.attendees, in: list)
        // 推定は、--judge で選んだ判断モデルがあるときだけ（無ければ、「相手」のまま。SPEC §3.13）。「相手」を再生するときだけ。
        let model = options.speaker == .others ? options.judge.flatMap(DecisionModelCatalog.model(id:)) : nil
        if let model, !list.others.isEmpty, !modelStore.isInstalled(model) {
            throw CLIError.transcription("判断モデル「\(model.name)」が、取得されていません（\(AppInfo.name) models download \(model.id)）")
        }
        do {
            let labeler = try SpeakerLabeler.make(list: list, model: model, store: modelStore, attendance: attendance, unit: options.unit)
            return (ActorSource(list: list, file: absolute), labeler)
        } catch { throw CLIError.transcription("判断モデルを読み込めません: " + ((error as? DecisionModelError)?.message ?? "\(error)")) }
    }

    /// 出席者：指定があれば、その人だけを話者の候補にする（相手の側の名前。無い名前は、断る）。
    private func replayAttendance(_ names: [String]?, in list: ActorList) throws -> Attendance {
        let attendance = Attendance()
        guard let names else { return attendance }
        let known = Set(list.others.map(\.name))
        let unknown = names.filter { !known.contains($0) }
        guard unknown.isEmpty else { throw CLIError.input("--attendees に、ACTOR.md の相手の側に無い名前があります: \(unknown.joined(separator: "・"))（\(list.others.map(\.name).joined(separator: "・"))）") }
        attendance.replace(excluded: known.subtracting(names))
        return attendance
    }

    private func startHub() throws -> HubServer {
        let hub = HubServer(socketPath: RuntimePaths.hubSocket(environment: environment))
        do { try hub.start() } catch let error as HubError { throw error.cliError }
        return hub
    }

    /// エージェントがつながるのを待つ（つながったら、すぐ始める。上限を過ぎたら、待たずに始める）。
    private func waitForAgent(on hub: HubServer, upTo seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while hub.clientCount == 0 && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// 音声ファイルの認識結果を、（名前を付けて）パイプラインへ入れる。返すのは、最後の更新の終わりの秒。
    private func play(_ file: URL, _ options: ReplayOptions, labeler: SpeakerLabeler?, into pipeline: SessionPipeline) async throws -> TimeInterval {
        var lastEnd: TimeInterval = 0
        do {
            for try await update in updates(file, Locale(identifier: options.locale), options.model, modelStore) {
                var parts: [(update: TranscriptionUpdate, actor: ActorLabel?)] = [(update, nil)]
                if let labeler {
                    do { parts = try await labeler.split(update, speaker: options.speaker) } catch { throw CLIError.input("話者の推定に失敗しました") }
                }
                for part in parts { pipeline.ingest(part.update, speaker: options.speaker, actor: part.actor) }
                lastEnd = max(lastEnd, update.end)
            }
        } catch let error as TranscriptionError { throw error.cliError }
        return lastEnd
    }

    private func printReplaySummary(_ end: SessionEnd) {
        if outIsTerminal {
            out(CLIView.replaySummary(sessionId: end.sessionId, utterances: end.utterances, batches: end.batches, duration: TimeInterval(end.durationSeconds), path: end.transcriptPath, outStyle))
        } else {
            out(CLIOutput.json(CLIOutput.ReplaySummary(sessionId: end.sessionId, batches: end.batches, utterances: end.utterances, durationSeconds: end.durationSeconds, transcriptPath: end.transcriptPath)))
        }
    }
}
