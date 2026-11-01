import AppKit
import Foundation

/// メニュー・設定ウィンドウの操作を、会議（`LiveSession`）へ結ぶ。会議の状態の所有者は `LiveSession`。ここが持つのは、表示のための状態（操作中か・知らせ・取り込みの設定〔`CapturePreferences` 1 つ〕）と、選択の規則。モデルのダウンロードは `ModelDownloads`、ACTOR.md の選択・出席者は `ActorSelection`、一時停止・再開・終了の直列化は `OperationGate` が持つ。
@MainActor
final class MeetingController {
    enum State: Equatable {
        case idle
        case running
        case paused
        /// 開始・一時停止・再開・終了の最中。操作は受け付けない。
        case working(String)
    }

    private(set) var state: State = .idle { didSet { changed() } }
    /// 失敗・知らせ（メニューの 1 行）。次の開始、または会議の終了で更新する。
    var notice: String? { didSet { changed() } }
    /// 取り込みの設定（SPEC §5）：マイク・システム音声・画面・まとめ方・プリセット・使う文字起こし・ACTOR.md・判断モデルなど。設定ウィンドウ・メニューで選び、覚えておく。**ここが、1 つの持ち主**（読み出しは、下の計算プロパティ）。
    private(set) var preferences = CapturePreferences()
    /// 取り込む音声の選択。
    var selection: AudioSelection { AudioSelection(microphone: preferences.microphone, system: preferences.system) }
    /// エージェントへ渡す、まとめ方（SPEC §3.6）。
    var batchMode: BatchMode { preferences.batchMode }
    /// 画面の取り込み（SPEC §3.5）。
    var screen: ScreenSelection { preferences.screen }
    /// 分析のしかた（プリセット。SPEC §3.11）。
    var presetID: String { preferences.presetID }
    /// 使う文字起こし（Mac 標準か、ダウンロードしたモデル。SPEC §3.12）。
    var transcription: TranscriptionChoice { preferences.transcription }
    /// 使う `ACTOR.md`（SPEC §3.13）。会議の開始のたびに、読み直す。
    var actorFile: String? { preferences.actorFile }
    /// 最近使った `ACTOR.md`（新しい順。メニューで切り替える）。
    var actorFiles: [String] { preferences.actorFiles }
    /// ACTOR.md の選択まわり：今日の出席者・会議が使っている一覧・設定ウィンドウに見せる状態・会議の開始のための labeler（SPEC §3.13）。
    let actorSelection = ActorSelection()
    /// 一時停止・再開・終了の、進行中の操作（同時に 1 つだけ）。
    private let operations = OperationGate()
    /// 名前のヒントに使う判断モデル（System One 型。取得済みのものだけ）。無ければ、ヒントを出さない（SPEC §3.13）。名前は、人間が確定する。
    var decisionModel: DecisionModel? { preferences.decisionModel.flatMap(DecisionModelCatalog.model(id:)) }
    /// 声による話者の分離（SPEC §3.14）。オンで、モデルが取得済みのときだけ、会議で使う。
    var voiceSeparation: Bool { preferences.voiceSeparation }
    /// 話者の人数（SPEC §3.14）。無指定は、自動。
    var voiceSpeakerCount: Int? { preferences.voiceSpeakerCount }
    /// 分離の調整（SPEC §3.16）。無指定は、既定。
    var voiceClusterThreshold: Double? { preferences.voiceClusterThreshold }
    var voiceMinSegmentSeconds: Double? { preferences.voiceMinSegmentSeconds }
    /// 分離器へ渡す調整（人数は、会議の設定、または、分け直しで選んだ値）。
    func voiceTuning(speakerCount: Int?) -> VoiceSeparationTuning {
        VoiceSeparationTuning(speakerCount: speakerCount, clusterThreshold: preferences.voiceClusterThreshold, minSegmentSeconds: preferences.voiceMinSegmentSeconds)
    }
    /// 声の分離のモデル（いまは 1 つ）。
    var voiceModel: VoiceModel? { VoiceModelCatalog.all.first }
    /// 声紋を使う（SPEC §3.15）。オンで、声による話者の分離もオンのときだけ、会議で使う。
    var voiceprintsEnabled: Bool { preferences.voiceprints && preferences.voiceSeparation }
    /// 声紋の保管（`<データの置き場所>/voiceprints.json`）。
    let voiceprintStore: VoiceprintStore
    /// 保存した声紋を読んだ結果（設定ウィンドウの一覧。変えるたびに読み直す）。
    var voiceprintState: VoiceprintLoad = .none
    /// 相手の音声を保存する（SPEC §3.16）。オンで、声による話者の分離もオンのときだけ、会議で使う。
    var saveOthersAudio: Bool { preferences.saveOthersAudio && preferences.voiceSeparation }
    /// 保存した相手の音声の、件数と大きさ（設定ウィンドウに見せる。起動時・会議の開始と終了のとき・6 時間ごと・削除のときに数え直す）。
    var savedAudio = SavedAudioSummary()
    var savedAudioStore: SavedAudioStore { SavedAudioStore(root: dataDirectory) }
    let presetStore: PresetStore
    /// ダウンロードしたモデルの保管場所（`<データの置き場所>/models/`）。
    let modelStore: ModelStore
    /// モデルのダウンロードの状態と操作（設定ウィンドウが読む・操作する）。
    let downloads: ModelDownloads
    private let defaults: UserDefaults

    /// 状態が変わったときに呼ぶ処理（メニューバーの絵・設定ウィンドウの表示を更新する）。
    private var observers: [() -> Void] = []

    func observe(_ handler: @escaping () -> Void) { observers.append(handler) }

    func changed() { for handler in observers { handler() } }

    /// いまつながっているエージェント（`meeting-analyzer mcp`）の数。
    private(set) var agentCount = 0

    private var session: LiveSession?
    /// 名付けの対象：直前の会議（声で分けた話者がいるときだけ）。**次の会議を始める・アプリを終了するまで**（SPEC §3.15）。
    var namingSession: LiveSession?
    /// 名付けの画面に見せる、話者ごとの要約と、確定した名前（話者 N → 名前）。
    var namingSpeakers: [SpeakerSummary] = []
    var namedSpeakers: [Int: String] = [:]
    /// 声紋の候補（話者 N → 候補。自動で名前が付かなかった話者だけ）と、声紋の一致で名前が付いた話者。
    var namingCandidates: [Int: [VoiceprintCandidate]] = [:]
    var voiceMatched: Set<Int> = []
    /// 名前のヒント（話者 N → ヒント。確定ではない）。判断モデルを選んでいるときだけ、名付けの画面を開いたときに、画面の中で計算する（会議の最中は、計算しない。SPEC §3.13）。
    var namingHints: [Int: [SpeakerHint]] = [:]
    enum HintState: Equatable {
        case notRequested, computing, ready
        case failed(String)
    }
    var hintState: HintState = .notRequested
    /// 再分離（SPEC §3.16）の状態。
    enum ReseparationState: Equatable {
        case idle, running
        /// 分け直した。話者の数。
        case done(Int)
        case failed(String)
    }
    var reseparation: ReseparationState = .idle
    /// 聞き直し（SPEC §3.16）：保存した音声の、抜粋の区間を再生する。
    let clipPlayer = SpeakerClipPlayer()
    /// 聞き直しで、再生できなかった理由（画面に出す）。
    var playbackFailure: String?
    /// 声の分離器を作る部品（会議の終了時と、分け直しで使う）。試験は、偽物へ差し替える。
    var voiceSeparatorFactory: @Sendable (VoiceModel, ModelStore, VoiceSeparationTuning) -> any VoiceSeparating = { model, store, tuning in
        FluidVoiceSeparator(model: model, store: store, tuning: tuning)
    }
    /// 判断モデルを読み込む部品（重い。別のスレッドで呼ぶ）。試験は、偽物へ差し替える。
    var hintJudgeFactory: @Sendable (DecisionModel, ModelStore, [Actor]) throws -> any SpeakerJudge = { model, store, candidates in
        let judge = try SystemOneJudge(model: model, store: store, candidates: candidates)
        try judge.prepare()
        return judge
    }
    private let environment: [String: String]
    /// このアプリのデータの置き場所（記録・画像・モデル・自分のプリセット）。起動のときに、1 度だけ求める。
    private let dataDirectory: URL
    /// エージェントへ渡す窓口。待ち受けを始められなくても、記録は続けられる（出来事は、保持するだけ）。
    private let hub: HubServer

    init(environment: [String: String] = ProcessInfo.processInfo.environment, defaults: UserDefaults = .standard) {
        self.environment = environment
        self.defaults = defaults
        dataDirectory = RuntimePaths.dataDirectory(environment: environment)
        presetStore = PresetStore.standard(environment: environment)
        modelStore = ModelStore(root: dataDirectory)
        voiceprintStore = VoiceprintStore(root: dataDirectory)
        downloads = ModelDownloads(store: modelStore)
        hub = HubServer(socketPath: RuntimePaths.hubSocket(environment: environment))
        var saved = CapturePreferences.load(defaults)
        // 保存したプリセットが、もう無ければ（自分のフォルダから消した）、既定に戻す。
        if presetStore.resolve(id: saved.presetID) == nil { saved.presetID = AnalysisPreset.defaultID }
        // 保存したモデルが、取得されていなければ（削除した・別の Mac から移した）、Mac 標準／「ヒントを出さない」に戻す（黙って別のものを使わないよう、設定を直す）。
        if case .local(let id) = saved.transcription, !(LocalModelCatalog.model(id: id).map { modelStore.isInstalled($0.artifact) } ?? false) { saved.transcription = .apple }
        if let id = saved.decisionModel, !(DecisionModelCatalog.model(id: id).map { modelStore.isInstalled($0) } ?? false) { saved.decisionModel = nil }
        if saved.voiceSeparation, !(VoiceModelCatalog.all.first.map { modelStore.isInstalled($0) } ?? false) { saved.voiceSeparation = false }
        if saved.voiceprints, !saved.voiceSeparation { saved.voiceprints = false }
        if saved.saveOthersAudio, !saved.voiceSeparation { saved.saveOthersAudio = false }
        preferences = saved
        voiceprintState = voiceprintStore.load()
        savedAudio = SavedAudioStore(root: dataDirectory).summary()
        retentionDays = RecordRetentionSetting.load(defaults)
        actorSelection.restore(from: saved)
        downloads.onChange = { [weak self] in self?.changed() }
        clipPlayer.onChange = { [weak self] in self?.changed() }
    }

    /// 取り込みの設定を、覚えておく（再起動しても、同じ選択になる）。
    private func persist() {
        preferences.save(defaults)
    }

    /// 「待機中だけ変えられる設定」を変える：待機中でなければ、何もしない。変えたら、保存して、通知する。
    func mutateWhenIdle(_ change: (inout CapturePreferences) -> Void) {
        guard state == .idle else { return }
        change(&preferences)
        persist()
        changed()
    }

    /// 窓口を開く。開けなければ、知らせを出す（セッションは、記録だけで始められる）。
    func startHub() {
        hub.setClientCountHandler { [weak self] count in
            Task { @MainActor in self?.agentCount = count; self?.changed() }
        }
        do { try hub.start() } catch let error as HubError { notice = FailureText.hub(error) } catch { notice = "エージェントへ渡す窓口を開けません" }
        scheduleRecordCleanup()
    }

    func stopHub() {
        hub.stop()
        recordCleanup?.invalidate()
    }

    private var recordCleanup: Timer?

    /// 記録を残す日数（`nil` は、消さない）。設定ウィンドウで選び、アプリの設定に保存する。会議中でも変えられる。
    private(set) var retentionDays: Int?

    func setRetentionDays(_ days: Int?) {
        retentionDays = days
        RecordRetentionSetting.save(days, defaults)
        cleanRecords()
        changed()
    }

    /// 期限（`retentionDays` 日）を過ぎた記録（文字起こし・画像・保存した音声）を、フォルダごと消す。起動時・会議の開始と終了のとき・6 時間ごと（常駐していても、日数が守られるように）。
    /// そのあと、保存した音声の件数と大きさを、数え直す。
    func cleanRecords() {
        let root = dataDirectory
        let active = session?.sessionId
        let days = retentionDays
        Task.detached(priority: .utility) {
            if let days { RecordRetention(root: root).deleteExpired(olderThanDays: days, except: active) }
            let summary = SavedAudioStore(root: root).summary()
            await MainActor.run { self.updateSavedAudio(summary) }
        }
    }

    private func scheduleRecordCleanup() {
        cleanRecords()
        recordCleanup?.invalidate()
        recordCleanup = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.cleanRecords() }
        }
    }

    var hasActiveMeeting: Bool { session != nil }

    /// システム音声に選べるアプリの候補。起動中の通常のアプリ（権限は要らない）。このアプリ自身は除く。
    func candidateApps() -> [CaptureApp] {
        var seen = Set<String>()
        let own = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .compactMap { app -> CaptureApp? in
                guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != own, let name = app.localizedName, seen.insert(id).inserted else { return nil }
                return CaptureApp(bundleID: id, name: name)
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func setMicrophone(_ enabled: Bool) {
        mutateWhenIdle { $0.microphone = enabled }
    }

    func setScreen(_ selection: ScreenSelection) {
        mutateWhenIdle { $0.screen = selection }
    }

    /// 選べるプリセット（同梱と、自分のフォルダのもの）。
    func presets() -> [AnalysisPreset] { presetStore.all() }

    /// 選んでいるプリセットの名前（選んだものが無くなっていれば、既定）。
    var presetName: String { presetStore.resolve(id: presetID)?.name ?? "なし" }

    func setPreset(_ id: String) {
        mutateWhenIdle { $0.presetID = id }
    }

    /// 自分のプリセットを置くフォルダを開く（無ければ、テンプレートつきで作る）。
    func openPresetFolder() {
        guard let folder = presetStore.prepareUserDirectory() else { notice = "プリセットのフォルダを作れません"; return }
        NSWorkspace.shared.open(folder)
    }

    /// このアプリのデータの置き場所（記録 `sessions/`・画像・自分のプリセット `presets/`）を、Finder で開く（無ければ、作る）。
    func openDataFolder() {
        let folder = dataDirectory
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            notice = "フォルダを作れません"
            return
        }
        NSWorkspace.shared.open(folder)
    }

    /// コマンド `meeting-analyzer` の状態（メニューの表示用）。
    var commandState: CommandLineTool.State { CommandLineTool().state }

    /// コマンド `meeting-analyzer` を、入れる・外す。管理者のパスワードが要るときは、OS のダイアログが出る。失敗したら、理由を見せる（取り消しは、黙って何もしない）。
    func toggleCommand() {
        let tool = CommandLineTool()
        let error = tool.state == .installed ? tool.uninstall() : tool.install()
        guard let error else { changed(); return }
        Alerts.show(title: "コマンド「\(CommandLineTool.name)」を変えられませんでした", text: error)
    }

    // MARK: 文字起こしのモデル（SPEC §3.12）

    func isInstalled(_ model: LocalModel) -> Bool { modelStore.isInstalled(model.artifact) }

    /// 使う文字起こしを選ぶ。ダウンロードしたモデルは、取得済みのものだけ選べる。会議の実行中は、変えられない。
    func setTranscription(_ choice: TranscriptionChoice) {
        if case .local(let id) = choice {
            guard let model = LocalModelCatalog.model(id: id), isInstalled(model) else { return }
        }
        mutateWhenIdle { $0.transcription = choice }
    }

    /// モデルを、ダウンロードする（利用者が押したときだけ。音声区間の検出のモデルも、一緒に取得する）。途中のファイルがあれば、続きから。取得できたら、そのモデルを選ぶ。
    func downloadModel(_ model: LocalModel) {
        downloads.start(id: model.id, plan: ModelInstallPlan(model), received: modelStore.downloadedBytes(model.artifact)) { [self] in
            if state == .idle { setTranscription(.local(model.id)) }
            notice = "「\(model.name)」を取得しました"
        }
    }

    /// 取得したモデルを、削除する。使っているモデルなら、Mac 標準に戻す（会議の実行中は、使っているモデルを消せない）。
    func deleteModel(_ model: LocalModel) {
        if transcription == .local(model.id) {
            guard state == .idle else { return }
            preferences.transcription = .apple
            persist()
        }
        modelStore.delete(model.artifact)
        changed()
    }

    // MARK: 名前のヒントのモデル（SPEC §3.13）

    func isInstalled(_ model: DecisionModel) -> Bool { modelStore.isInstalled(model) }

    /// 名前のヒントに使う判断モデルを選ぶ（`nil`＝ヒントを出さない）。取得済みのものだけ選べる。会議の実行中は、変えられない。
    func setDecisionModel(_ model: DecisionModel?) {
        if let model { guard isInstalled(model) else { return } }
        mutateWhenIdle { $0.decisionModel = model?.id }
    }

    /// 判断モデルを、ダウンロードする（利用者が押したときだけ。トークナイザ → 重みの順。途中のファイルがあれば、続きから）。取得できたら、そのモデルを選ぶ。
    func downloadDecisionModel(_ model: DecisionModel) {
        downloads.start(id: model.id, plan: ModelInstallPlan(model), received: modelStore.downloadedBytes(model)) { [self] in
            if state == .idle { setDecisionModel(model) }
            notice = "「\(model.name)」を取得しました"
        }
    }

    /// 取得した判断モデルを、削除する。使っているモデルなら、「ヒントを出さない」に戻す（会議の実行中は、使っているモデルを消せない）。
    func deleteDecisionModel(_ model: DecisionModel) {
        if decisionModel == model {
            guard state == .idle else { return }
            preferences.decisionModel = nil
            persist()
        }
        modelStore.delete(model)
        changed()
    }

    // MARK: 話者の分離のモデル（声。SPEC §3.14）

    func isInstalled(_ model: VoiceModel) -> Bool { modelStore.isInstalled(model) }

    /// 声による話者の分離を、オン・オフする。オンにできるのは、モデルが取得済みのときだけ。会議の実行中は、変えられない。
    func setVoiceSeparation(_ enabled: Bool) {
        if enabled { guard let model = voiceModel, isInstalled(model) else { return } }
        mutateWhenIdle { $0.voiceSeparation = enabled; if !enabled { $0.voiceprints = false; $0.saveOthersAudio = false } }
    }

    /// 話者の人数を指定する（`nil`＝自動。2〜8。範囲外は、何もしない）。会議の実行中は、変えられない。
    func setVoiceSpeakerCount(_ count: Int?) {
        if let count { guard VoiceSeparationTuning.speakerCountRange.contains(count) else { return } }
        mutateWhenIdle { $0.voiceSpeakerCount = count }
    }

    /// 併合のしきい値を指定する（`nil`＝既定。範囲外は、何もしない）。会議の実行中は、変えられない。
    func setVoiceClusterThreshold(_ value: Double?) {
        if let value { guard VoiceSeparationTuning.clusterThresholdRange.contains(value) else { return } }
        mutateWhenIdle { $0.voiceClusterThreshold = value }
    }

    /// 短い区間の下限（秒）を指定する（`nil`＝既定。範囲外は、何もしない）。会議の実行中は、変えられない。
    func setVoiceMinSegmentSeconds(_ value: Double?) {
        if let value { guard VoiceSeparationTuning.minSegmentSecondsRange.contains(value) else { return } }
        mutateWhenIdle { $0.voiceMinSegmentSeconds = value }
    }

    /// 声の分離のモデルを、ダウンロードする（利用者が押したときだけ。小さいファイルから。途中のファイルがあれば、続きから）。取得できたら、オンにする。
    func downloadVoiceModel(_ model: VoiceModel) {
        downloads.start(id: model.id, plan: ModelInstallPlan(model), received: modelStore.downloadedBytes(model)) { [self] in
            if state == .idle { setVoiceSeparation(true) }
            notice = "「\(model.name)」を取得しました"
        }
    }

    /// 取得した声の分離のモデルを、削除する。オンなら、オフに戻す（会議の実行中は、使っているモデルを消せない）。
    func deleteVoiceModel(_ model: VoiceModel) {
        if voiceSeparation {
            guard state == .idle else { return }
            preferences.voiceSeparation = false
            preferences.voiceprints = false
            preferences.saveOthersAudio = false
            persist()
        }
        modelStore.delete(model)
        changed()
    }

    // MARK: アクター（ACTOR.md。SPEC §3.13）

    /// 設定ウィンドウに見せる、選んだ `ACTOR.md` の状態。
    var actorStatus: ActorSelection.Status { actorSelection.status(file: actorFile) }

    /// 出席者の選択肢（相手の側の人）。
    var actorChoices: [ActorSelection.Choice] { actorSelection.choices(file: actorFile, meetingRunning: state != .idle) }

    /// 出席者を、足す・外す。**会議の実行中でも、変えられる**（次の判断から効く）。選んだ ACTOR.md ごとに、覚える。
    func setPresent(_ name: String, _ present: Bool) {
        guard actorSelection.setPresent(name, present, in: &preferences) else { return }
        persist()
        changed()
    }

    /// `ACTOR.md` を選ぶ（待機中だけ。`nil`＝外す）。ファイルを選ぶパネルは、View 側（`ActorFilePicker`）。
    func setActorFile(_ path: String?) {
        mutateWhenIdle { actorSelection.select(path, in: &$0) }
    }

    func setBatchMode(_ mode: BatchMode) {
        mutateWhenIdle { $0.batchMode = mode }
    }

    func setSystem(_ source: SystemSource) {
        mutateWhenIdle { $0.system = source }
    }

    // MARK: 操作

    func start() {
        guard state == .idle else { return }
        guard !selection.isEmpty else { notice = "取り込む音声を選んでください"; return }
        notice = nil
        state = .working("開始処理中…")
        cleanRecords()
        Task { await begin(selection) }
    }

    func pause() {
        guard state == .running, let session else { return }
        state = .working("一時停止中…")
        operations.run { [self] in
            do { try await session.pause(); state = .paused } catch { state = .running; notice = "一時停止できませんでした" }
        }
    }

    func resume() {
        guard state == .paused, let session else { return }
        state = .working("再開処理中…")
        operations.run { [self] in
            do { try await session.resume(); state = .running }
            catch let error as LiveSessionError { state = .paused; notice = FailureText.start(error) }
            catch { state = .paused; notice = "再開できませんでした" }
        }
    }

    func endFromMenu() {
        guard state == .running || state == .paused else { return }
        Task { await end(reason: .user) }
    }

    /// 会議を終える。記録を書き、エージェントへ終了の出来事を出す。
    func end(reason: EndReason) async {
        // 一時停止・再開・終了の最中なら、終わるのを待つ（その間に終了を始めると、取り込みの停止が重なる）。
        await operations.idle()
        guard let session else { return }
        state = .working("終了処理中…")
        await operations.run { [self] in
            defer { self.session = nil; state = .idle }
            do {
                let outcome = try await session.end(reason: reason)
                defer { cleanRecords() }
                notice = "終了しました（発話 \(outcome.utterances) 件）"
                // 声で分けた話者がいれば、または、音声を保存していて分け直せれば、名付けの対象にする（次の会議の開始まで）。声紋で名前が付いた話者は、確定済み。
                let summaries = await session.speakerSummaries()
                let canReseparate = savedAudioStore.exists(sessionId: session.sessionId)
                if !summaries.isEmpty || canReseparate {
                    let matched = await session.speakerNames()
                    namingSession = session
                    namingSpeakers = summaries
                    namedSpeakers = matched
                    voiceMatched = Set(matched.keys)
                    namingCandidates = await session.speakerCandidates()
                    reseparation = .idle
                    touchVoiceprints(Set(matched.values))
                    let matchedNote = matched.isEmpty ? "" : "・声紋で \(matched.count) 人に名前が付きました"
                    let rest = summaries.filter { matched[$0.id] == nil }.count
                    if summaries.isEmpty {
                        notice = "終了しました（発話 \(outcome.utterances) 件。話者は分けられませんでした。メニューの「話者の名付け…」から、分け直せます）"
                    } else {
                        notice = "終了しました（発話 \(outcome.utterances) 件・話者 \(summaries.count) 人\(matchedNote)" + (rest > 0 ? "。メニューの「話者の名付け…」で、名前を付けられます）" : "）")
                    }
                }
            } catch {
                notice = "会議を終了できませんでした"
            }
        }.value
    }

    // MARK: 内部

    private func begin(_ selection: AudioSelection) async {
        let screenSelection = screen
        let notify: @Sendable (LiveSessionNotice) -> Void = { [weak self] notice in
            Task { @MainActor in self?.notice = FailureText.notice(notice) }
        }
        let setup = actorSelection.prepare(file: actorFile)
        let dataDirectory = dataDirectory
        // 声による話者の分離（SPEC §3.14）：オンで、モデルが取得済みで、システム音声を取り込むときだけ。音は、メモリ上だけに持つ。
        var recorder: VoiceAudioRecorder?
        var voice: LiveSessionVoice?
        var voiceNotice: String?
        if voiceSeparation, selection.system != .off, let model = voiceModel, modelStore.isInstalled(model) {
            let held = VoiceAudioRecorder()
            recorder = held
            let loaded = voiceprintLibrary(for: model)
            let library = loaded.library
            voiceNotice = loaded.notice
            voice = LiveSessionVoice(recorder: held, separator: voiceSeparatorFactory(model, modelStore, voiceTuning(speakerCount: voiceSpeakerCount)), library: library, audioStore: saveOthersAudio ? savedAudioStore : nil)
        }
        let session = LiveSession(
            title: Self.sessionTitle(selection: selection),
            speakers: selection.speakers,
            inputs: .device(system: selection.system, locale: Locale(identifier: CommandParser.defaultLocale), transcription: transcription, models: modelStore, recorder: recorder),
            sink: hub,
            store: SessionStore(root: dataDirectory),
            options: LiveSessionOptions(
                policy: batchMode.policy,
                preset: presetStore.resolve(id: presetID)?.info,
                actors: setup.actors,
                screen: screenSelection == .off ? nil : LiveSessionScreen(feed: ScreenFeed { try await ScreenSnapshotter(selection: screenSelection).snapshot() }, store: ScreenshotStore(root: dataDirectory)),
                voice: voice
            ),
            notify: notify
        )
        do {
            try await session.start()
            self.session = session
            clearNaming()
            state = .running
            if let notice = [setup.notice, voiceNotice].compactMap({ $0 }).joined(separator: " ／ ").nilIfEmpty { self.notice = notice }
        } catch let error as LiveSessionError {
            if case .capture(.permissionDenied(let permission, _)) = error {
                fail(FailureText.start(error), settings: permission.settingsURL)
            } else {
                fail(FailureText.start(error))
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// `settings`：権限の失敗のとき、システム設定のそのページを開けるようにする。
    private func fail(_ message: String, settings: URL? = nil) {
        state = .idle
        notice = "開始できませんでした"
        Alerts.show(title: "会議を始められません", text: message, settings: settings)
    }

    /// セッションの名前。エージェントが区別できる程度（取り込む音声と開始時刻）。
    static func sessionTitle(selection: AudioSelection, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(selection.summary) \(formatter.string(from: now))"
    }
}
