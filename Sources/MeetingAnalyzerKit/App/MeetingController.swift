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
    private(set) var selectedApp: CaptureApp?
    var onChange: (() -> Void)?

    private var session: LiveSession?
    private let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    var hasActiveMeeting: Bool { session != nil }

    /// 取り込める会議アプリの候補。起動中の通常のアプリ（権限は要らない）。このアプリ自身は除く。
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

    func select(_ app: CaptureApp) {
        guard state == .idle else { return }
        selectedApp = app
        onChange?()
    }

    // MARK: 操作

    func start() {
        guard state == .idle else { return }
        guard let app = selectedApp else { notice = "会議アプリを選んでください"; return }
        guard ConsentPrompt.confirm(appName: app.name) else { return }
        notice = nil
        state = .working("開始処理中…")
        Task { await begin(app) }
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

    /// 会議を終える。終了の合図を送れなかったときは、利用者にそう伝える（記録は残る）。
    func end(reason: EndReason) async {
        // 開始・一時停止・再開の最中なら、終わるのを待つ（その間に終了を始めると、取り込みの停止が重なる）。
        while case .working = state, session != nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let session else { return }
        state = .working("終了処理中…")
        defer { self.session = nil; state = .idle }
        do {
            let outcome = try await session.end(reason: reason)
            if let failure = outcome.deliveryFailure {
                notice = "終了の合図を送れませんでした"
                var text = FailureText.bridge(failure)
                if let path = outcome.transcriptPath { text += "\n\n記録は保存されています:\n\(path)" }
                Alerts.show(title: "会議を終えましたが、エージェントへ届いていません", text: text)
            } else {
                notice = "会議を終了しました（発話 \(outcome.utterances) 件）"
            }
        } catch {
            notice = "会議を終了できませんでした"
        }
    }

    // MARK: 内部

    private func begin(_ app: CaptureApp) async {
        let endpoint: BridgeEndpoint
        switch makeEndpoint() {
        case .failure(let message): fail(message); return
        case .success(let value): endpoint = value
        }
        let notify: @Sendable (LiveSessionNotice) -> Void = { [weak self] notice in
            Task { @MainActor in self?.notice = FailureText.notice(notice) }
        }
        let session = LiveSession(
            meetingId: Self.meetingName(app: app.name),
            inputs: .device(appBundleIDs: [app.bundleID], locale: Locale(identifier: CommandParser.defaultLocale)),
            sender: BridgeClient(endpoint: endpoint),
            store: SessionStore(root: RuntimePaths.dataDirectory(environment: environment)),
            notify: notify
        )
        do {
            try await session.start()
            self.session = session
            state = .running
        } catch let error as LiveSessionError {
            fail(FailureText.start(error))
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        state = .idle
        notice = "開始できませんでした"
        Alerts.show(title: "会議を始められません", text: message)
    }

    private func makeEndpoint() -> Result<BridgeEndpoint, StartFailure> {
        let directory = RuntimePaths.liveSupportDirectory(environment: environment)
        switch TokenStore.read(directory: directory) {
        case .failure(let error): return .failure(StartFailure(FailureText.token(error, directory: directory.path)))
        case .success(let token):
            switch BridgeEndpoint.parse(url: RuntimePaths.bridgeURL(environment: environment), token: token) {
            case .success(let endpoint): return .success(endpoint)
            case .failure(.notLoopbackHTTP): return .failure(StartFailure("ブリッジの送り先が、http://127.0.0.1 ではありません"))
            case .failure(.shortToken): return .failure(StartFailure("トークンが短すぎる、または空白を含みます。エージェント側を起動し直してください"))
            }
        }
    }

    private struct StartFailure: Error { let message: String; init(_ message: String) { self.message = message } }

    private func fail(_ failure: StartFailure) { fail(failure.message) }

    /// 会議の名前。エージェントが会議を区別できる程度（アプリ名と開始時刻）。
    static func meetingName(app: String, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(app) \(formatter.string(from: now))"
    }
}

/// 失敗を、利用者に見せるダイアログ。
@MainActor
enum Alerts {
    static func show(title: String, text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
