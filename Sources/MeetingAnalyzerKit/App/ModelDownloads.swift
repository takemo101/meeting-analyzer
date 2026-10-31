import Foundation

/// モデル（文字起こし・判断モデル）のダウンロードの状態と操作。**同時に 1 つだけ**取得する。
/// 状態が変わったら `onChange` を呼ぶ（メニュー・設定ウィンドウの表示を更新する）。取得できたあとの「そのモデルを選ぶ」は、選択の規則を持つ `MeetingController` が、`onInstalled` で行う。
@MainActor
final class ModelDownloads {
    /// いまのダウンロード：モデルの ID・取得済みと全体のバイト数。
    struct Download: Equatable {
        let id: String
        var received: Int64
        var total: Int64
    }

    private(set) var current: Download? { didSet { onChange() } }
    /// 直近のダウンロードの失敗（モデルの ID と理由）。次のダウンロードの開始で消す。
    private(set) var failure: (id: String, reason: String)? { didSet { onChange() } }
    var onChange: () -> Void = {}

    private let store: ModelStore
    private var downloader: ModelDownloader?

    init(store: ModelStore) {
        self.store = store
    }

    /// 取得を始める。状態を「取得中」にし、`plan` を順に取り、終わったら後始末をして、成功なら `onInstalled`、失敗なら理由を残す（取り消しは、何も残さない）。すでに取得中なら、何もしない。
    func start(id: String, plan: ModelInstallPlan, received: Int64, onInstalled: @escaping @MainActor () -> Void) {
        guard current == nil else { return }
        failure = nil
        current = Download(id: id, received: received, total: plan.total)
        let downloader = ModelDownloader(store: store)
        self.downloader = downloader
        let throttle = ProgressThrottle()
        Task {
            var error: Error?
            do {
                try await plan.run(fetch: { try await downloader.download($0, progress: $1) }) { received, total in
                    guard throttle.shouldReport(received: received, total: total) else { return }
                    Task { @MainActor in self.current = Download(id: id, received: received, total: total) }
                }
            } catch let thrown {
                error = thrown
            }
            current = nil
            self.downloader = nil
            switch error {
            case nil:
                onInstalled()
            case let error as ModelDownloadError:
                if error != .cancelled { failure = (id, FailureText.download(error)) }
            case let error?:
                failure = (id, "\(error)")
            }
        }
    }

    /// 取り消す（取得済みの分は残り、続きから再開できる）。
    func cancel() { downloader?.cancel() }

    /// 途中までのダウンロード（`.part`）を、捨てる（取り消したあとに、続きから取得せず、やめるとき）。取得中・取得済みのモデルには、何もしない。
    func discardPartial(_ model: LocalModel) {
        guard current?.id != model.id, !store.isInstalled(model.artifact) else { return }
        store.discardPartial(model.artifact)
        didDiscard(model.id)
    }

    func discardPartial(_ model: DecisionModel) {
        guard current?.id != model.id, !store.isInstalled(model) else { return }
        store.discardPartial(model)
        didDiscard(model.id)
    }

    private func didDiscard(_ id: String) {
        if failure?.id == id { failure = nil }
        onChange()
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
