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

public enum LiveSessionError: Error, Sendable, Equatable {
    case bridge(BridgeError)
    case capture(CaptureError)
    case transcription(TranscriptionError)
    /// その状態では、できない操作（SPEC §3.2）。
    case invalidState(SessionLifecycle.Phase)
    case failed(String)
}

/// 実行中に起きた、会議を止めない失敗。何を続け、何を止めたかを、利用者に見せるための知らせ。
public enum LiveSessionNotice: Sendable, Equatable {
    /// その発言者の取り込みが、利用者の操作なしに止まった（会議アプリの終了・OS による停止など）。他の流れは続く。
    case captureStopped(Speaker)
    /// その発言者の認識が失敗した。他の流れは続く。
    case transcriptionFailed(Speaker, String)
    /// 字幕の送信に失敗した。そのバッチは、エージェントへ届いていない（記録には残る）。
    case sendFailed(BridgeError)
}

public struct LiveSessionOutcome: Sendable, Equatable {
    public let utterances: Int
    /// 記録（Markdown）。書けなかったときは無し。
    public let transcriptPath: String?
    /// 終了の合図（または、その前の送り切り）が、エージェントへ届かなかったときの理由。
    public let deliveryFailure: BridgeError?
}

/// ライブの会議 1 つ。状態遷移（`SessionLifecycle`）・取り込みの流れ・バッチの送信（`SessionPipeline`）・時間（tick）を組み立てる。
/// すべての操作を、この actor で直列にする。送信の最中に別の更新が割り込んで、バッチの順序が入れ替わらないようにする。
public actor LiveSession {
    public nonisolated let sessionId: UUID
    public nonisolated let meetingId: String
    public nonisolated let startedAt: Date

    private let inputs: LiveInputs
    private let sender: any BridgeSending
    private let store: SessionStore?
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
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private struct Running {
        let stream: LiveInputStream
        let task: Task<Void, Never>
    }

    public init(
        meetingId: String, speakers: [Speaker], inputs: LiveInputs, sender: any BridgeSending, store: SessionStore?,
        policy: BatchingPolicy = .standard, clock: @escaping @Sendable () -> Date = { Date() },
        tickInterval: Duration = .milliseconds(250), finalizeTimeout: Duration = .seconds(5),
        notify: @escaping @Sendable (LiveSessionNotice) -> Void
    ) {
        let startedAt = clock()
        let sessionId = UUID()
        self.sessionId = sessionId
        self.meetingId = meetingId
        self.startedAt = startedAt
        self.speakers = speakers
        self.inputs = inputs
        self.sender = sender
        self.store = store
        self.clock = clock
        self.tickInterval = tickInterval
        self.finalizeTimeout = finalizeTimeout
        self.notify = notify
        self.pipeline = SessionPipeline(sessionId: sessionId, meetingId: meetingId, startedAt: startedAt, sender: sender, store: store, policy: policy)
    }

    public var phase: SessionLifecycle.Phase { lifecycle.phase }

    // MARK: 操作

    /// 開始する。ブリッジの確認 → 取り込みの開始（権限の確認は、ここで OS が出す）。失敗したら、何も始めず、待機のまま。
    public func start() async throws {
        guard lifecycle.phase == .idle else { throw LiveSessionError.invalidState(lifecycle.phase) }
        guard !speakers.isEmpty else { throw LiveSessionError.failed("取り込む音声が選ばれていません") }
        do { try await sender.health() } catch let error as BridgeError { throw LiveSessionError.bridge(error) }
        try await beginSegment()
        try? lifecycle.start()
        startTicker()
    }

    /// 一時停止する。取り込みを止め、認識の残りを確定して取り込み、未送信の発話を送り切る。
    public func pause() async throws {
        guard lifecycle.phase == .running else { throw LiveSessionError.invalidState(lifecycle.phase) }
        stopTicker()
        await endSegment()
        try? lifecycle.pause()
        await exclusive { [pipeline, elapsed = elapsed()] in
            do { try await pipeline.flushPending(at: elapsed) } catch { self.report(error) }
        }
    }

    /// 再開する。取り込みを始められなければ、一時停止のまま。
    public func resume() async throws {
        guard lifecycle.phase == .paused else { throw LiveSessionError.invalidState(lifecycle.phase) }
        try await beginSegment()
        try? lifecycle.resume()
        startTicker()
    }

    /// 終了する。取り込みを止め → 認識の残りを取り込み → 未送信を出し切り → 記録を書き → 最後に終了の合図を 1 回送る（SPEC §3.8）。
    public func end(reason: EndReason) async throws -> LiveSessionOutcome {
        guard lifecycle.phase == .running || lifecycle.phase == .paused else { throw LiveSessionError.invalidState(lifecycle.phase) }
        stopTicker()
        await endSegment()
        try? lifecycle.end(reason)
        let now = clock()
        let elapsed = now.timeIntervalSince(startedAt)
        return await exclusive {
            do {
                let event = try await self.pipeline.finish(reason: reason, endedAt: now, at: elapsed)
                return LiveSessionOutcome(utterances: event.utterances, transcriptPath: event.transcriptPath, deliveryFailure: nil)
            } catch {
                // 送れなかった。記録は書かれている（あれば）。利用者に、届いていないことを伝えるのは、呼び出し側。
                let path = self.store.map { $0.transcriptURL(sessionId: self.sessionId).path }.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
                return LiveSessionOutcome(utterances: self.pipeline.utteranceCount, transcriptPath: path, deliveryFailure: (error as? BridgeError) ?? .unreachable)
            }
        }
    }

    // MARK: 取り込みの流れ

    private func elapsed() -> TimeInterval { clock().timeIntervalSince(startedAt) }

    /// 選んだ流れ（あなた・相手）を開く。どれかが開けなければ、開いたほうも止めて、失敗を返す。
    private func beginSegment() async throws {
        var opened: [Speaker: (LiveInputStream, TimeInterval)] = [:]
        do {
            for speaker in speakers {
                let stream = try await inputs.open(speaker)
                // 音声の秒数の原点は、取り込みが始まった時刻（会議の開始からの経過）。一時停止をはさんでも、時刻が続く。
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
            for try await update in stream.updates { await ingest(update, speaker: speaker, origin: origin) }
            if !stopping { notify(.captureStopped(speaker)) }
        } catch {
            if !stopping && !Task.isCancelled { notify(.transcriptionFailed(speaker, String(describing: error))) }
        }
    }

    private func ingest(_ update: TranscriptionUpdate, speaker: Speaker, origin: TimeInterval) async {
        guard segmentActive else { return }
        let shifted = TranscriptionUpdate(text: update.text, isFinal: update.isFinal, start: update.start + origin, end: update.end + origin)
        await exclusive {
            do { try await self.pipeline.ingest(shifted, speaker: speaker) } catch { self.report(error) }
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
                await self.tick()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() async {
        guard lifecycle.phase == .running else { return }
        await exclusive {
            do { try await self.pipeline.tick(at: self.elapsed()) } catch { self.report(error) }
        }
    }

    // MARK: 直列化と失敗

    /// 送信をまたぐ操作を、1 つずつ行う。actor は、`await` の間に別の操作を入れるので、そのままだと、バッチの送信が重なる。
    private func exclusive<T>(_ body: () async -> T) async -> T {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        let result = await body()
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        return result
    }

    private func report(_ error: Error) {
        if let bridge = error as? BridgeError { notify(.sendFailed(bridge)) } else { notify(.sendFailed(.unreachable)) }
    }

    private static func map(_ error: Error) -> LiveSessionError {
        switch error {
        case let error as LiveSessionError: return error
        case let error as CaptureError: return .capture(error)
        case let error as TranscriptionError: return .transcription(error)
        case let error as BridgeError: return .bridge(error)
        default: return .failed(error.localizedDescription)
        }
    }
}
