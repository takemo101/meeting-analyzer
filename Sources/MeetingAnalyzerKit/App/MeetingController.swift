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

    private(set) var state: State = .idle { didSet { onChange?() } }
    /// 失敗・知らせ（メニューの 1 行）。次の開始、または会議の終了で更新する。
    private(set) var notice: String? { didSet { onChange? () } }
    /// 取り込む音声の選択。開始のたびに選ぶ（保存しない。SPEC §5）。
    private(set) var selection = AudioSelection()
    /// エージェントへ渡す、まとめ方（SPEC §3.6）。開始のたびに選ぶ（保存しない）。
    private(set) var batchMode = BatchMode.utterance
    /// 画面の取り込み（SPEC §3.5）。開始のたびに選ぶ（保存しない）。
    private(set) var screen = ScreenSelection.off
    /// 分析のしかた（プリセット。SPEC §3.11）。開始のたびに選ぶ（保存しない）。
    private(set) var presetID = AnalysisPreset.defaultID
    let presetStore: PresetStore
    var onChange: (() -> Void)?

    /// いまつながっているエージェント（`meeting-analyzer mcp`）の数。
    private(set) var agentCount = 0

    private var session: LiveSession?
    private let environment: [String: String]
    /// エージェントへ渡す窓口。待ち受けを始められなくても、記録は続けられる（出来事は、保持するだけ）。
    private let hub: HubServer

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        presetStore = PresetStore.standard(environment: environment)
        hub = HubServer(socketPath: RuntimePaths.hubSocket(environment: environment))
    }

    /// 窓口を開く。開けなければ、知らせを出す（セッションは、記録だけで始められる）。
    func startHub() {
        hub.setClientCountHandler { [weak self] count in
            Task { @MainActor in self?.agentCount = count; self?.onChange?() }
        }
        do { try hub.start() } catch let error as HubError { notice = FailureText.hub(error) } catch { notice = "エージェントへ渡す窓口を開けません" }
        scheduleScreenshotCleanup()
    }

    func stopHub() {
        hub.stop()
        screenshotCleanup?.invalidate()
    }

    private var screenshotCleanup: Timer?

    /// 終了から `ScreenshotStore.retentionDays` 日たった画面の画像を消す。起動時・会議の開始と終了のとき・6 時間ごと（常駐していても、日数が守られるように）。
    func cleanScreenshots() {
        let root = RuntimePaths.dataDirectory(environment: environment)
        let active = session?.sessionId
        Task.detached(priority: .utility) { ScreenshotStore(root: root).deleteExpired(except: active) }
    }

    private func scheduleScreenshotCleanup() {
        cleanScreenshots()
        screenshotCleanup?.invalidate()
        screenshotCleanup = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.cleanScreenshots() }
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
        guard state == .idle else { return }
        selection.microphone = enabled
        onChange?()
    }

    func setScreen(_ selection: ScreenSelection) {
        guard state == .idle else { return }
        screen = selection
        onChange?()
    }

    /// 選べるプリセット（同梱と、自分のフォルダのもの）。
    func presets() -> [AnalysisPreset] { presetStore.all() }

    /// 選んでいるプリセットの名前（選んだものが無くなっていれば、既定）。
    var presetName: String { presetStore.resolve(id: presetID)?.name ?? "なし" }

    func setPreset(_ id: String) {
        guard state == .idle else { return }
        presetID = id
        onChange?()
    }

    /// 自分のプリセットを置くフォルダを開く（無ければ、テンプレートつきで作る）。
    func openPresetFolder() {
        guard let folder = presetStore.prepareUserDirectory() else { notice = "プリセットのフォルダを作れません"; return }
        NSWorkspace.shared.open(folder)
    }

    func setBatchMode(_ mode: BatchMode) {
        guard state == .idle else { return }
        batchMode = mode
        onChange?()
    }

    func setSystem(_ source: SystemSource) {
        guard state == .idle else { return }
        selection.system = source
        onChange?()
    }

    // MARK: 操作

    /// エージェントへの登録の文を、クリップボードへ入れる（エージェントの設定は、自動では書き換えない）。
    func copyRegistration(_ registration: AgentRegistration) {
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(registration.text(executable: executable), forType: .string)
        notice = "コピーしました: \(registration.title)。ターミナルで実行してください"
    }

    func start() {
        guard state == .idle else { return }
        guard !selection.isEmpty else { notice = "取り込む音声を選んでください"; return }
        notice = nil
        state = .working("開始処理中…")
        cleanScreenshots()
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
            defer { cleanScreenshots() }
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
        let session = LiveSession(
            title: Self.sessionTitle(selection: selection),
            speakers: selection.speakers,
            inputs: .device(system: selection.system, locale: Locale(identifier: CommandParser.defaultLocale)),
            sink: hub,
            store: SessionStore(root: RuntimePaths.dataDirectory(environment: environment)),
            policy: batchMode.policy,
            screen: screenSelection == .off ? nil : ScreenFeed { try await ScreenSnapshotter(selection: screenSelection).snapshot() },
            screenshots: screenSelection == .off ? nil : ScreenshotStore(root: RuntimePaths.dataDirectory(environment: environment)),
            preset: presetStore.resolve(id: presetID)?.info,
            notify: notify
        )
        do {
            try await session.start()
            self.session = session
            state = .running
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
