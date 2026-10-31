import AppKit
import Foundation

/// メニューの操作を、会議（`LiveSession`）へ結ぶ。会議の状態の所有者は `LiveSession` で、ここは、表示のための状態（操作中か・知らせ・選んだアプリ）だけを持つ。
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
    private(set) var notice: String? { didSet { changed() } }
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
    /// 今日の出席者（外した人）。会議の途中でも変えられ、判断のたびに、この状態を見る（SPEC §3.13）。
    let attendance = Attendance()
    /// 実行中の会議が、開始のときに読んだ一覧（会議の途中で、ファイルが書き換わっても、メニューは、会議が使っている一覧を見せる）。
    private var activeActors: ActorList?
    /// 話者の推定に使う判断モデル（System One 型。取得済みのものだけ）。無ければ、推定しない（「相手」のまま。SPEC §3.13）。
    var decisionModel: DecisionModel? { preferences.decisionModel.flatMap(DecisionModelCatalog.model(id:)) }
    let presetStore: PresetStore
    /// ダウンロードしたモデルの保管場所（`<データの置き場所>/models/`）。
    let modelStore: ModelStore
    /// いまのダウンロード（同時に 1 つ）。モデルの ID・取得済みと全体のバイト数。
    struct ModelDownload: Equatable {
        let id: String
        var received: Int64
        var total: Int64
    }
    private(set) var download: ModelDownload? { didSet { changed() } }
    /// 直近のダウンロードの失敗（モデルの ID と理由）。次のダウンロードの開始で消す。
    private(set) var downloadFailure: (id: String, reason: String)? { didSet { changed() } }
    private var downloader: ModelDownloader?
    private let defaults: UserDefaults

    /// 状態が変わったときに呼ぶ処理（メニューバーの絵・設定ウィンドウの表示を更新する）。
    private var observers: [() -> Void] = []

    func observe(_ handler: @escaping () -> Void) { observers.append(handler) }

    private func changed() { for handler in observers { handler() } }

    /// いまつながっているエージェント（`meeting-analyzer mcp`）の数。
    private(set) var agentCount = 0

    private var session: LiveSession?
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
        hub = HubServer(socketPath: RuntimePaths.hubSocket(environment: environment))
        var saved = CapturePreferences.load(defaults)
        // 保存したプリセットが、もう無ければ（自分のフォルダから消した）、既定に戻す。
        if presetStore.resolve(id: saved.presetID) == nil { saved.presetID = AnalysisPreset.defaultID }
        // 保存したモデルが、取得されていなければ（削除した・別の Mac から移した）、Mac 標準／「推定しない」に戻す（黙って別のものを使わないよう、設定を直す）。
        if case .local(let id) = saved.transcription, !(LocalModelCatalog.model(id: id).map { modelStore.isInstalled($0.artifact) } ?? false) { saved.transcription = .apple }
        if let id = saved.decisionModel, !(DecisionModelCatalog.model(id: id).map { modelStore.isInstalled($0) } ?? false) { saved.decisionModel = nil }
        preferences = saved
        retentionDays = RecordRetentionSetting.load(defaults)
        attendance.replace(excluded: Set(saved.actorFile.flatMap { saved.absentActors[$0] } ?? []))
    }

    /// 取り込みの設定を、覚えておく（再起動しても、同じ選択になる）。
    private func persist() {
        preferences.save(defaults)
    }

    /// 「待機中だけ変えられる設定」を変える：待機中でなければ、何もしない。変えたら、保存して、通知する。
    private func mutateWhenIdle(_ change: (inout CapturePreferences) -> Void) {
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

    /// 期限（`retentionDays` 日）を過ぎた記録（文字起こしと画像）を、フォルダごと消す。起動時・会議の開始と終了のとき・6 時間ごと（常駐していても、日数が守られるように）。
    func cleanRecords() {
        guard let days = retentionDays else { return }
        let root = dataDirectory
        let active = session?.sessionId
        Task.detached(priority: .utility) { RecordRetention(root: root).deleteExpired(olderThanDays: days, except: active) }
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
        startDownload(id: model.id, name: model.name, plan: ModelInstallPlan(model), received: modelStore.downloadedBytes(model.artifact)) { [self] in
            if state == .idle { setTranscription(.local(model.id)) }
        }
    }

    /// 取得の共通の手順：状態を「取得中」にし、`plan` を順に取り、終わったら後始末をして、成功なら `onInstalled`（そのモデルを選ぶ）、失敗なら理由を残す（取り消しは、何も残さない）。同時に 1 つだけ。
    private func startDownload(id: String, name: String, plan: ModelInstallPlan, received: Int64, onInstalled: @escaping @MainActor () -> Void) {
        guard download == nil else { return }
        downloadFailure = nil
        download = ModelDownload(id: id, received: received, total: plan.total)
        let downloader = ModelDownloader(store: modelStore)
        self.downloader = downloader
        let throttle = ProgressThrottle()
        Task {
            var failure: Error?
            do {
                try await plan.run(fetch: { try await downloader.download($0, progress: $1) }) { received, total in
                    guard throttle.shouldReport(received: received, total: total) else { return }
                    Task { @MainActor in self.download = ModelDownload(id: id, received: received, total: total) }
                }
            } catch {
                failure = error
            }
            download = nil
            self.downloader = nil
            switch failure {
            case nil:
                onInstalled()
                notice = "「\(name)」を取得しました"
            case let error as ModelDownloadError:
                if error != .cancelled { downloadFailure = (id, FailureText.download(error)) }
            case let error?:
                downloadFailure = (id, "\(error)")
            }
        }
    }

    /// 途中までのダウンロード（`.part`）を、捨てる（取り消したあとに、続きから取得せず、やめるとき）。取得中・取得済みのモデルには、何もしない。
    func discardPartialDownload(_ model: LocalModel) {
        guard download?.id != model.id, !isInstalled(model) else { return }
        modelStore.discardPartial(model.artifact)
        if downloadFailure?.id == model.id { downloadFailure = nil }
        changed()
    }

    /// ダウンロードを取り消す（取得済みの分は残り、続きから再開できる）。
    func cancelDownload() { downloader?.cancel() }

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

    // MARK: 話者の推定のモデル（SPEC §3.13）

    func isInstalled(_ model: DecisionModel) -> Bool { modelStore.isInstalled(model) }

    /// 話者の推定に使う判断モデルを選ぶ（`nil`＝推定しない）。取得済みのものだけ選べる。会議の実行中は、変えられない。
    func setDecisionModel(_ model: DecisionModel?) {
        if let model { guard isInstalled(model) else { return } }
        mutateWhenIdle { $0.decisionModel = model?.id }
    }

    /// 判断モデルを、ダウンロードする（利用者が押したときだけ。トークナイザ → 重みの順。途中のファイルがあれば、続きから）。取得できたら、そのモデルを選ぶ。
    func downloadDecisionModel(_ model: DecisionModel) {
        startDownload(id: model.id, name: model.name, plan: ModelInstallPlan(model), received: modelStore.downloadedBytes(model)) { [self] in
            if state == .idle { setDecisionModel(model) }
        }
    }

    /// 途中までのダウンロード（`.part`）を、捨てる。取得中・取得済みのモデルには、何もしない。
    func discardPartialDownload(_ model: DecisionModel) {
        guard download?.id != model.id, !isInstalled(model) else { return }
        modelStore.discardPartial(model)
        if downloadFailure?.id == model.id { downloadFailure = nil }
        changed()
    }

    /// 取得した判断モデルを、削除する。使っているモデルなら、「推定しない」に戻す（会議の実行中は、使っているモデルを消せない）。
    func deleteDecisionModel(_ model: DecisionModel) {
        if decisionModel == model {
            guard state == .idle else { return }
            preferences.decisionModel = nil
            persist()
        }
        modelStore.delete(model)
        changed()
    }

    // MARK: アクター（ACTOR.md。SPEC §3.13）

    /// 設定ウィンドウに見せる、選んだ `ACTOR.md` の状態。
    enum ActorStatus: Equatable {
        case none
        case loaded(count: Int, hasSelf: Bool, warnings: [String])
        case failed(String)
    }

    /// 選んだファイルを、いま読んで検査した結果（読むのは、設定ウィンドウの表示のときだけ。小さいファイル）。
    var actorStatus: ActorStatus {
        guard let actorFile else { return .none }
        switch ActorFile.load(path: actorFile) {
        case .success(let list): return .loaded(count: list.actors.count, hasSelf: list.selfActor != nil, warnings: list.warnings)
        case .failure(let error): return .failed(error.message)
        }
    }

    /// 出席者の選択肢の 1 人分（相手の側の人。本人は、出さない）。
    struct ActorChoice: Equatable {
        let name: String
        let role: String?
        let present: Bool
    }

    /// 出席者の選択肢。会議の実行中は、開始のときに読んだ一覧。待機中は、選んだファイルを、いま読む（読めなければ、空）。
    var actorChoices: [ActorChoice] {
        let list: ActorList?
        if state != .idle, let activeActors {
            list = activeActors
        } else if let actorFile, case .success(let loaded) = ActorFile.load(path: actorFile) {
            list = loaded
        } else {
            list = nil
        }
        return (list?.others ?? []).map { ActorChoice(name: $0.name, role: $0.role, present: attendance.isPresent($0.name)) }
    }

    /// 出席者を、足す・外す。**会議の実行中でも、変えられる**（次の判断から効く。すでに付いた名前は、付け直さない）。選んだ ACTOR.md ごとに、覚える。
    func setPresent(_ name: String, _ present: Bool) {
        guard let actorFile else { return }
        attendance.setPresent(name, present)
        let absent = attendance.excludedNames
        preferences.absentActors[actorFile] = absent.isEmpty ? nil : absent.sorted()
        persist()
        changed()
    }


    /// `ACTOR.md` を選ぶ（ファイルを選ぶパネル）。選んだら、検査して、状態を更新する。
    func chooseActorFile() {
        guard state == .idle else { return }
        let panel = NSOpenPanel()
        panel.title = "アクター定義（ACTOR.md）を選ぶ"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .init(filenameExtension: "md") ?? .plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setActorFile(url.path)
    }

    func setActorFile(_ path: String?) {
        mutateWhenIdle { preferences in
            preferences.actorFile = path
            if let path { preferences.remember(actorFile: path) }
            // 出席者は、選んだ ACTOR.md ごとに覚えている（別のファイルへ切り替えると、そのファイルで外した人に変わる）。
            attendance.replace(excluded: Set(path.flatMap { preferences.absentActors[$0] } ?? []))
        }
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
        Task {
            do { try await session.pause(); state = .paused } catch { state = .running; notice = "一時停止できませんでした" }
        }
    }

    func resume() {
        guard state == .paused, let session else { return }
        state = .working("再開処理中…")
        Task {
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
        // 開始・一時停止・再開の最中なら、終わるのを待つ（その間に終了を始めると、取り込みの停止が重なる）。
        while case .working = state, session != nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let session else { return }
        state = .working("終了処理中…")
        defer { self.session = nil; state = .idle }
        do {
            let outcome = try await session.end(reason: reason)
            defer { cleanRecords() }
            notice = "終了しました（発話 \(outcome.utterances) 件）"
        } catch {
            notice = "会議を終了できませんでした"
        }
    }

    // MARK: 内部

    private func begin(_ selection: AudioSelection) async {
        let screenSelection = screen
        let notify: @Sendable (LiveSessionNotice) -> Void = { [weak self] notice in
            Task { @MainActor in self?.notice = FailureText.notice(notice) }
        }
        let (actors, labeler, actorNotice) = await actorSetup(selection)
        let dataDirectory = dataDirectory
        let session = LiveSession(
            title: Self.sessionTitle(selection: selection),
            speakers: selection.speakers,
            inputs: .device(system: selection.system, locale: Locale(identifier: CommandParser.defaultLocale), transcription: transcription, models: modelStore),
            sink: hub,
            store: SessionStore(root: dataDirectory),
            options: LiveSessionOptions(
                policy: batchMode.policy,
                preset: presetStore.resolve(id: presetID)?.info,
                actors: actors,
                labeler: labeler,
                screen: screenSelection == .off ? nil : LiveSessionScreen(feed: ScreenFeed { try await ScreenSnapshotter(selection: screenSelection).snapshot() }, store: ScreenshotStore(root: dataDirectory))
            ),
            notify: notify
        )
        do {
            try await session.start()
            self.session = session
            state = .running
            if let actorNotice { notice = actorNotice }
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

    /// 会議で使う `ACTOR.md` と、発話へ名前を付ける部品。読めない・推定を使えないときは、付けずに会議を始め、理由を知らせる（失敗を黙って捨てない）。
    /// 判断モデルを選んでいない・取得していない・相手の音声を取り込まない・相手の側の候補がいないときは、**推定しない**（「本人」の対応づけだけ。相手は「相手」のまま）。
    /// モデルの読み込み（初回は、GPU のコンパイルで数秒）は、画面を止めないよう、別のスレッドで行う。
    private func actorSetup(_ selection: AudioSelection) async -> (ActorSource?, SpeakerLabeler?, String?) {
        activeActors = nil
        guard let path = actorFile else { return (nil, nil, nil) }
        switch ActorFile.load(path: path) {
        case .failure(let error):
            return (nil, nil, "ACTOR.md を使えません: \(error.message)")
        case .success(let list):
            activeActors = list
            // 判断モデルは、相手の音声を取り込むときだけ使う。読み込み（初回は数秒）は、画面を止めないよう、別のスレッドで。
            let model = selection.system == .off ? nil : decisionModel
            let store = modelStore, attendance = attendance
            var problem: String?
            let labeler: SpeakerLabeler
            do {
                labeler = try await Task.detached(priority: .userInitiated) { try SpeakerLabeler.make(list: list, model: model, store: store, attendance: attendance) }.value
            } catch {
                // 読み込めなくても、会議は始める（「本人」の対応づけだけ。理由を知らせる）。
                labeler = SpeakerLabeler(list: list, guesser: nil)
                problem = "相手の話者を推定できません" + ((error as? DecisionModelError).map { ": \($0.message)" } ?? "")
            }
            return (ActorSource(list: list, file: path), labeler, problem)
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

/// ダウンロードの進み具合の通知を、間引く（取得のたびに、画面を更新しない）：全体の 1% 以上進んだとき、または、最後。
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent = -1

    func shouldReport(received: Int64, total: Int64) -> Bool {
        guard total > 0 else { return false }
        lock.lock(); defer { lock.unlock() }
        let percent = Int(received * 100 / total)
        guard percent != lastPercent else { return false }
        lastPercent = percent
        return true
    }
}
