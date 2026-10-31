import CoreGraphics
import Foundation

/// 画面の取り込み（SPEC §3.5）：撮る → 余白の帯を切る → 安定・変化・間隔の判定 → 縮小した JPEG にして保存、を、会議の間、一定の間隔で行う。
/// `LiveSession` が持つ。actor なので、撮影の待ちの間に別の操作が割り込んでも、判定の状態（間隔・前の画面・失敗の知らせ）は、ここだけが、直列に持つ。
/// 出来事への受け渡し（`SessionPipeline.attachScreenshot`）は、パイプラインを直列に使う `LiveSession` の中で行うので、ここは、保存した画像（`Shot`）を返す・渡すだけ。
actor ScreenRecorder {
    /// 保存した画像 1 枚。`relativePath` は、記録（`transcript.md`）のフォルダからの相対パス。`at` は、会議の開始からの秒。
    struct Shot: Sendable, Equatable {
        let path: String
        let relativePath: String
        let at: TimeInterval
    }

    private enum Mode { case first, periodic }

    private enum Attempt {
        case saved(Shot)
        /// 保存しなかった（間隔の内・同じ画面・ウィンドウが伸び縮みしている最中・会議が実行中でない、など）。
        case skipped
        case snapshotFailed(Error)
        case saveFailed
    }

    private let feed: ScreenFeed
    private let store: ScreenshotStore
    private let sessionId: UUID
    private let interval: Duration
    private let elapsed: @Sendable () -> TimeInterval
    private let notify: @Sendable (LiveSessionNotice) -> Void
    private var gate: ScreenshotGate
    private var stability = ScreenStability()
    private var failureReported = false
    private var running = false
    private var ticker: Task<Void, Never>?

    init(feed: ScreenFeed, store: ScreenshotStore, sessionId: UUID, interval: Duration, minGap: TimeInterval, elapsed: @escaping @Sendable () -> TimeInterval, notify: @escaping @Sendable (LiveSessionNotice) -> Void) {
        self.feed = feed
        self.store = store
        self.sessionId = sessionId
        self.interval = interval
        self.gate = ScreenshotGate(minGap: minGap)
        self.elapsed = elapsed
        self.notify = notify
    }

    /// 開始のときの最初の 1 枚。許可の確認は、開始の操作の中で出す。**権限の失敗・画像を保存できない失敗は、開始の失敗として投げる**（何も始めない）。
    /// ウィンドウが見えていない・撮れないときは、会議を始めて、知らせを 1 回出し、撮れるようになるのを待つ（字幕の転送を止めない）。
    func captureFirst() async throws -> Shot? {
        switch await attempt(.first) {
        case .saved(let shot): return shot
        case .skipped: return nil
        case .snapshotFailed(let error):
            if let capture = error as? CaptureError, case .permissionDenied = capture { throw LiveSessionError.capture(capture) }
            reportOnce(Self.failureText(error))
            return nil
        case .saveFailed:
            throw LiveSessionError.failed("画面の画像を保存できません")
        }
    }

    /// 一定の間隔で撮り始める。保存した画像は、`attach` へ渡す。失敗は、1 回だけ知らせて、続ける（字幕の転送を止めない）。
    func startPeriodic(attach: @escaping @Sendable (Shot) async -> Void) {
        running = true
        ticker?.cancel()
        ticker = repeatEvery(interval) {
            if let shot = await self.captureDuringMeeting() { await attach(shot) }
        }
    }

    func stopPeriodic() {
        running = false
        ticker?.cancel()
        ticker = nil
    }

    /// 会議が始まらなかったとき（開始に失敗）の画像を、消す。
    func discard() {
        store.deleteAll(sessionId: sessionId)
    }

    /// 実行中の 1 回。`running` でなくなっていたら（一時停止・終了の最中に、撮影が終わった）、保存しない。
    private func captureDuringMeeting() async -> Shot? {
        switch await attempt(.periodic) {
        case .saved(let shot): return shot
        case .skipped: return nil
        case .snapshotFailed(let error): reportOnce(Self.failureText(error)); return nil
        case .saveFailed: reportOnce("画像を保存できません"); return nil
        }
    }

    /// 画面を 1 枚撮り、前に保存した画面から変化があれば（かつ、前の保存から間隔があいていれば）、縮小した JPEG にして保存する。
    private func attempt(_ mode: Mode) async -> Attempt {
        let snapshot: CGImage
        do { snapshot = try await feed.snapshot() } catch { return .snapshotFailed(error) }
        if mode == .periodic, !running { return .skipped }
        let now = elapsed()
        // フルスクリーンの動画などで、枠が、見えている内容より大きいとき、片側（上と右など）に空白が残る。その帯を、切り落とす。
        let image = ImageTools.trimmingUnrenderedBands(snapshot)
        guard gate.isOpen(at: now) else { return .skipped }
        // ウィンドウが伸び縮みしている最中の画像は、保存しない（次の確認まで待つ）。
        guard stability.isSettled(width: snapshot.width, height: snapshot.height) else { return .skipped }
        guard let signature = ImageTools.signature(of: image), gate.hasChanged(signature),
              let jpeg = ImageTools.jpegData(of: image) else { return .skipped }
        let index = gate.nextIndex
        switch store.save(jpeg, sessionId: sessionId, index: index) {
        case .success(let url):
            gate.didSave(signature, at: now)
            return .saved(Shot(path: url.path, relativePath: ScreenshotStore.relativePath(index: index), at: now))
        case .failure:
            return .saveFailed
        }
    }

    /// 失敗の知らせは、セッションにつき 1 回（取り消されている最中は、出さない）。
    private func reportOnce(_ text: String) {
        guard !failureReported, !Task.isCancelled else { return }
        failureReported = true
        notify(.screenshotFailed(text))
    }

    private static func failureText(_ error: Error) -> String {
        switch error {
        case CaptureError.permissionDenied: return "画面を撮れません（画面収録の許可を確認してください）"
        case CaptureError.targetNotFound(let reason), CaptureError.failed(let reason): return reason
        default: return "画面を撮れません"
        }
    }
}
