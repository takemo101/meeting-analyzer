import CoreGraphics
import Foundation

/// 発言者 1 人の、取り込み → 認識の流れ。`stop` は取り込みを止める。止めると、`updates` は、残りを確定して終わる。
public struct LiveInputStream: Sendable {
    public let updates: AsyncThrowingStream<TranscriptionUpdate, Error>
    public let stop: @Sendable () async -> Void

    public init(updates: AsyncThrowingStream<TranscriptionUpdate, Error>, stop: @escaping @Sendable () async -> Void) {
        self.updates = updates
        self.stop = stop
    }
}

/// 発言者ごとの流れを開く部品。実機ではマイク・システム音声（`DeviceInputs`）、テストでは偽の流れ。
public struct LiveInputs: Sendable {
    public let open: @Sendable (Speaker) async throws -> LiveInputStream

    public init(open: @escaping @Sendable (Speaker) async throws -> LiveInputStream) {
        self.open = open
    }
}

/// 画面の撮影の差し替え口。実機は `ScreenSnapshotter`、テストは偽の画像。
public struct ScreenFeed: Sendable {
    public let snapshot: @Sendable () async throws -> CGImage

    public init(snapshot: @escaping @Sendable () async throws -> CGImage) {
        self.snapshot = snapshot
    }
}

public enum LiveSessionError: Error, Sendable, Equatable {
    case capture(CaptureError)
    case transcription(TranscriptionError)
    /// その状態では、できない操作（SPEC §3.2）。
    case invalidState(SessionLifecycle.Phase)
    case failed(String)
}

/// 実行中に起きた、セッションを止めない失敗。何を続け、何を止めたかを、利用者に見せるための知らせ。
public enum LiveSessionNotice: Sendable, Equatable {
    /// その発言者の取り込みが、利用者の操作なしに止まった（アプリの終了・OS による停止など）。他の流れは続く。
    case captureStopped(Speaker)
    /// その発言者の認識が失敗した。他の流れは続く。
    case transcriptionFailed(Speaker, String)
    /// 画面を撮れなかった（権限・対象のウィンドウが無い、など）。字幕の転送は続く。
    case screenshotFailed(String)
    /// 「本人」の発話が、直近の「相手」の発話とほとんど同じ。相手の声が、マイクへ回り込んでいる疑い（ヘッドホンの案内）。セッションにつき 1 回。
    case possibleEcho
}

public struct LiveSessionOutcome: Sendable, Equatable {
    public let utterances: Int
    /// 記録（Markdown）。書けなかったときは無し。
    public let transcriptPath: String?
}

/// ライブのセッション 1 つ。状態遷移（`SessionLifecycle`）・取り込みの流れ・バッチの公開（`SessionPipeline`）・時間（tick）を組み立てる。
/// すべての操作を、この actor で直列にする。パイプラインは同期なので、操作の途中に別の更新が割り込まない。
public actor LiveSession {
    public nonisolated let sessionId: UUID
    public nonisolated let title: String
    public nonisolated let startedAt: Date

    private let inputs: LiveInputs
    /// 取り込む流れ（選んだ音声）。空では開始できない。
    private let speakers: [Speaker]
    private let pipeline: SessionPipeline
    private let clock: @Sendable () -> Date
    private let tickInterval: Duration
    private let finalizeTimeout: Duration
    private let notify: @Sendable (LiveSessionNotice) -> Void

    private var lifecycle = SessionLifecycle()
    private var segment: [Speaker: Running] = [:]
    private var segmentActive = false
    private var stopping = false
    private var ticker: Task<Void, Never>?
    private let screen: ScreenFeed?
    private let screenshots: ScreenshotStore?
    private let screenInterval: Duration
    private let screenMinGap: TimeInterval
    private var screenTicker: Task<Void, Never>?
    private var lastScreenSignature: ScreenSignature?
    private var lastScreenshotAt: TimeInterval?
    private var screenshotCount = 0
    private var screenFailureReported = false
    private var echo = EchoDetector()
    private var echoReported = false

    private struct Running {
        let stream: LiveInputStream
        let task: Task<Void, Never>
    }

    public init(
        title: String, speakers: [Speaker], inputs: LiveInputs, sink: any EventSink, store: SessionStore?,
        policy: BatchingPolicy = .standard, clock: @escaping @Sendable () -> Date = { Date() },
        tickInterval: Duration = .milliseconds(250), finalizeTimeout: Duration = .seconds(5),
        screen: ScreenFeed? = nil, screenshots: ScreenshotStore? = nil, screenInterval: Duration = .seconds(2), screenMinGap: TimeInterval = 10, preset: PresetInfo? = nil,
        notify: @escaping @Sendable (LiveSessionNotice) -> Void
    ) {
        let startedAt = clock()
        let sessionId = UUID()
        self.sessionId = sessionId
        self.title = title
        self.startedAt = startedAt
        self.speakers = speakers
        self.inputs = inputs
        self.clock = clock
        self.tickInterval = tickInterval
        self.finalizeTimeout = finalizeTimeout
        self.notify = notify
        self.screen = screen
        self.screenshots = screenshots
        self.screenInterval = screenInterval
        self.screenMinGap = screenMinGap
        self.pipeline = SessionPipeline(sessionId: sessionId, title: title, startedAt: startedAt, sink: sink, store: store, policy: policy, preset: preset)
    }

    public var phase: SessionLifecycle.Phase { lifecycle.phase }

    // MARK: 操作

    /// 開始する。取り込みを始める（権限の確認は、ここで OS が出す）。失敗したら、何も始めず、待機のまま。
    public func start() async throws {
        guard lifecycle.phase == .idle else { throw LiveSessionError.invalidState(lifecycle.phase) }
        guard !speakers.isEmpty else { throw LiveSessionError.failed("取り込む音声が選ばれていません") }
        // 画面を選んでいるときは、最初の 1 枚を、ここで撮る（権限の確認は、開始の操作の中で出す。撮れなければ、何も始めない）。
        try await captureScreen(throwing: true)
        do { try await beginSegment() } catch { discardScreenshots(); throw error }
        try? lifecycle.start()
        pipeline.begin(sources: speakers)
        startTicker()
        startScreenTicker()
    }

    /// 一時停止する。取り込みを止め、認識の残りを確定して取り込み、未送信の発話を出し切る。
    public func pause() async throws {
        guard lifecycle.phase == .running else { throw LiveSessionError.invalidState(lifecycle.phase) }
        stopTicker()
        stopScreenTicker()
        await endSegment()
        try? lifecycle.pause()
        pipeline.flushPending(at: elapsed())
    }

    /// 再開する。取り込みを始められなければ、一時停止のまま。
    public func resume() async throws {
        guard lifecycle.phase == .paused else { throw LiveSessionError.invalidState(lifecycle.phase) }
        try await beginSegment()
        try? lifecycle.resume()
        startTicker()
        startScreenTicker()
    }

    /// 終了する。取り込みを止める → 認識の残りを取り込む → 未送信を出し切る → 記録を書く → 最後に終了の出来事を 1 回出す（SPEC §3.8）。
    public func end(reason: EndReason) async throws -> LiveSessionOutcome {
        guard lifecycle.phase == .running || lifecycle.phase == .paused else { throw LiveSessionError.invalidState(lifecycle.phase) }
        stopTicker()
        stopScreenTicker()
        await endSegment()
        try? lifecycle.end(reason)
        let now = clock()
        let event = pipeline.finish(reason: reason, endedAt: now, at: now.timeIntervalSince(startedAt))
        // 画像は、終了のあとも残す（`ScreenshotStore.retentionDays` 日。過ぎたものは、アプリが消す。SPEC §3.5）。
        guard case .ended(_, _, _, _, _, _, _, let utterances, let path) = event else { return LiveSessionOutcome(utterances: pipeline.utteranceCount, transcriptPath: nil) }
        return LiveSessionOutcome(utterances: utterances, transcriptPath: path)
    }

    // MARK: 取り込みの流れ

    private func elapsed() -> TimeInterval { clock().timeIntervalSince(startedAt) }

    /// 選んだ流れ（本人・相手）を開く。どれかが開けなければ、開いたほうも止めて、失敗を返す。
    private func beginSegment() async throws {
        var opened: [Speaker: (LiveInputStream, TimeInterval)] = [:]
        do {
            for speaker in speakers {
                let stream = try await inputs.open(speaker)
                // 音声の秒数の原点は、取り込みが始まった時刻（セッションの開始からの経過）。一時停止をはさんでも、時刻が続く。
                opened[speaker] = (stream, elapsed())
            }
        } catch {
            for (stream, _) in opened.values { await stream.stop() }
            throw Self.map(error)
        }
        segmentActive = true
        stopping = false
        for (speaker, (stream, origin)) in opened {
            let task = Task { await self.consume(stream, speaker: speaker, origin: origin) }
            segment[speaker] = Running(stream: stream, task: task)
        }
    }

    private func consume(_ stream: LiveInputStream, speaker: Speaker, origin: TimeInterval) async {
        do {
            for try await update in stream.updates { ingest(update, speaker: speaker, origin: origin) }
            if !stopping { notify(.captureStopped(speaker)) }
        } catch {
            if !stopping && !Task.isCancelled { notify(.transcriptionFailed(speaker, String(describing: error))) }
        }
    }

    private func ingest(_ update: TranscriptionUpdate, speaker: Speaker, origin: TimeInterval) {
        guard segmentActive else { return }
        let shifted = TranscriptionUpdate(text: update.text, isFinal: update.isFinal, start: update.start + origin, end: update.end + origin)
        pipeline.ingest(shifted, speaker: speaker)
        if echo.observe(speaker: speaker, key: "\(speaker.rawValue)-\(shifted.start)", text: shifted.text, at: shifted.end), !echoReported {
            echoReported = true
            notify(.possibleEcho)
        }
    }

    /// 取り込みを止め、認識が残りを確定して終わるのを待つ。待ちすぎたら、打ち切る。
    private func endSegment() async {
        guard segmentActive else { return }
        stopping = true
        let running = Array(segment.values)
        for item in running { await item.stream.stop() }
        let timeout = Task { [finalizeTimeout] in
            try? await Task.sleep(for: finalizeTimeout)
            for item in running { item.task.cancel() }
        }
        for item in running { await item.task.value }
        timeout.cancel()
        segment = [:]
        segmentActive = false
        stopping = false
    }

    // MARK: 時間

    private func startTicker() {
        ticker = Task { [tickInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tickInterval)
                if Task.isCancelled { break }
                self.tick()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    // MARK: 画面

    private func startScreenTicker() {
        guard screen != nil else { return }
        screenTicker = Task { [screenInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: screenInterval)
                if Task.isCancelled { break }
                try? await self.captureScreen(throwing: false)
            }
        }
    }

    private func stopScreenTicker() {
        screenTicker?.cancel()
        screenTicker = nil
    }

    /// 会議が始まらなかったとき（開始に失敗）の画像を、消す。
    private func discardScreenshots() {
        screenshots?.deleteAll(sessionId: sessionId)
    }

    /// 画面を 1 枚撮り、前に保存した画面から変化があれば（かつ、前の保存から `screenMinGap` 秒たっていれば）、縮小した JPEG にして保存し、次のバッチへ添える。
    /// `throwing`：開始のときだけ true。撮れなければ、失敗として返す。実行中は、失敗を 1 回だけ知らせて、続ける（字幕の転送を止めない）。
    private func captureScreen(throwing: Bool) async throws {
        guard let screen, let screenshots else { return }
        let image: CGImage
        do {
            image = try await screen.snapshot()
        } catch {
            if throwing { throw Self.map(error) }
            if !screenFailureReported && !Task.isCancelled {
                screenFailureReported = true
                notify(.screenshotFailed(Self.screenFailureText(error)))
            }
            return
        }
        guard throwing || lifecycle.phase == .running else { return }
        let now = elapsed()
        if let last = lastScreenshotAt, now - last < screenMinGap { return }
        guard let signature = ImageTools.signature(of: image), ScreenChange.hasChanged(from: lastScreenSignature, to: signature),
              let jpeg = ImageTools.jpegData(of: image) else { return }
        switch screenshots.save(jpeg, sessionId: sessionId, index: screenshotCount + 1) {
        case .success(let url):
            screenshotCount += 1
            pipeline.attachScreenshot(path: url.path)
            lastScreenSignature = signature
            lastScreenshotAt = now
        case .failure:
            if throwing { throw LiveSessionError.failed("画面の画像を保存できません") }
            if !screenFailureReported { screenFailureReported = true; notify(.screenshotFailed("画像を保存できません")) }
        }
    }

    private static func screenFailureText(_ error: Error) -> String {
        switch error {
        case CaptureError.permissionDenied: return "画面を撮れません（画面収録の許可を確認してください）"
        case CaptureError.targetNotFound(let reason), CaptureError.failed(let reason): return reason
        default: return "画面を撮れません"
        }
    }

    private func tick() {
        guard lifecycle.phase == .running else { return }
        pipeline.tick(at: elapsed())
    }

    private static func map(_ error: Error) -> LiveSessionError {
        switch error {
        case let error as LiveSessionError: return error
        case let error as CaptureError: return .capture(error)
        case let error as TranscriptionError: return .transcription(error)
        default: return .failed(error.localizedDescription)
        }
    }
}
