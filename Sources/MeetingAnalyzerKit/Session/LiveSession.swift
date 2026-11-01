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
    /// 話者の推定が失敗した（モデルを使えない・応答しない、など）。以後、「相手」への名前の推定を止め、文字起こしと転送は続ける。セッションにつき 1 回。
    case speakerGuessFailed
    /// 声による話者の分離（会議の終了時）に失敗した。記録に、話者 ID は付かない（理由は、記録の見出しにも書く）。
    case voiceSeparationFailed(String)
    /// 会議が長く、声の分離は、最初の 3 時間だけ（音声を持てる上限）。
    case voiceSeparationTruncated
}

public struct LiveSessionOutcome: Sendable, Equatable {
    public let utterances: Int
    /// 記録（Markdown）。書けなかったときは無し。
    public let transcriptPath: String?
}

/// 会議の時間の設定。既定は実機の値（試験は、時計・間隔を差し替える）。
public struct LiveSessionTiming: Sendable {
    public var clock: @Sendable () -> Date
    /// 未送信の発話を、送る時かを確かめる間隔。
    public var tickInterval: Duration
    /// 終了・一時停止のとき、認識が残りを確定して終わるのを待つ上限。
    public var finalizeTimeout: Duration

    public init(clock: @escaping @Sendable () -> Date = { Date() }, tickInterval: Duration = .milliseconds(250), finalizeTimeout: Duration = .seconds(5)) {
        self.clock = clock
        self.tickInterval = tickInterval
        self.finalizeTimeout = finalizeTimeout
    }
}

/// 画面の取り込みの設定（選んだときだけ渡す。SPEC §3.5）。
public struct LiveSessionScreen: Sendable {
    public var feed: ScreenFeed
    public var store: ScreenshotStore
    /// 撮る間隔。
    public var interval: Duration
    /// 前の保存から、これだけ（秒）あいていなければ、保存しない。
    public var minGap: TimeInterval

    public init(feed: ScreenFeed, store: ScreenshotStore, interval: Duration = .seconds(2), minGap: TimeInterval = 10) {
        self.feed = feed
        self.store = store
        self.interval = interval
        self.minGap = minGap
    }
}

/// 声による話者の分離（SPEC §3.14）。選んだときだけ渡す。実行中は、システム音声を `recorder` にメモリ上だけで持ち、終了の処理で、`separator` で分けて、捨てる。
/// `library`（声紋を使うときだけ）：保存した声紋（会議の開始のときに読んだ写し）。終了の処理で、分けた話者と照合して、自動の条件を満たす人に名前を付ける（SPEC §3.15）。
public struct LiveSessionVoice: Sendable {
    public var recorder: VoiceAudioRecorder
    public var separator: any VoiceSeparating
    public var library: VoiceprintLibrary?

    public init(recorder: VoiceAudioRecorder, separator: any VoiceSeparating, library: VoiceprintLibrary? = nil) {
        self.recorder = recorder
        self.separator = separator
        self.library = library
    }
}

/// 会議の設定：まとめ方・分析のしかた・アクター・時間・画面・声の分離。すべて既定値つき（何も渡さなければ、実機の既定）。
public struct LiveSessionOptions: Sendable {
    public var policy: BatchingPolicy
    public var preset: PresetInfo?
    public var actors: ActorSource?
    public var labeler: SpeakerLabeler?
    public var timing: LiveSessionTiming
    public var screen: LiveSessionScreen?
    public var voice: LiveSessionVoice?

    public init(policy: BatchingPolicy = .standard, preset: PresetInfo? = nil, actors: ActorSource? = nil, labeler: SpeakerLabeler? = nil, timing: LiveSessionTiming = LiveSessionTiming(), screen: LiveSessionScreen? = nil, voice: LiveSessionVoice? = nil) {
        self.policy = policy
        self.preset = preset
        self.actors = actors
        self.labeler = labeler
        self.timing = timing
        self.screen = screen
        self.voice = voice
    }
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
    /// 画面の取り込み（`screen` と `screenshots` を、両方選んでいるときだけ）。
    private let screenRecorder: ScreenRecorder?
    private var echo = EchoDetector()
    private var echoReported = false
    private let labeler: SpeakerLabeler?
    private var labelingFailed = false
    private let voice: LiveSessionVoice?

    private struct Running {
        let stream: LiveInputStream
        let task: Task<Void, Never>
    }

    public init(title: String, speakers: [Speaker], inputs: LiveInputs, sink: any EventSink, store: SessionStore?, options: LiveSessionOptions = LiveSessionOptions(), notify: @escaping @Sendable (LiveSessionNotice) -> Void) {
        let clock = options.timing.clock
        let startedAt = clock()
        let sessionId = UUID()
        self.sessionId = sessionId
        self.title = title
        self.startedAt = startedAt
        self.speakers = speakers
        self.inputs = inputs
        self.clock = clock
        self.tickInterval = options.timing.tickInterval
        self.finalizeTimeout = options.timing.finalizeTimeout
        self.notify = notify
        self.labeler = options.labeler
        self.voice = options.voice
        self.screenRecorder = options.screen.map { screen in
            ScreenRecorder(feed: screen.feed, store: screen.store, sessionId: sessionId, interval: screen.interval, minGap: screen.minGap, elapsed: { clock().timeIntervalSince(startedAt) }, notify: notify)
        }
        self.pipeline = SessionPipeline(sessionId: sessionId, title: title, startedAt: startedAt, sink: sink, store: store, policy: options.policy, preset: options.preset, actors: options.actors, checkpointInterval: 10)
    }

    public var phase: SessionLifecycle.Phase { lifecycle.phase }

    // MARK: 操作

    /// 開始する。取り込みを始める（権限の確認は、ここで OS が出す）。失敗したら、何も始めず、待機のまま。
    public func start() async throws {
        let before = lifecycle
        try transition { try $0.start() }
        do {
            guard !speakers.isEmpty else { throw LiveSessionError.failed("取り込む音声が選ばれていません") }
            // 画面を選んでいるときは、最初の 1 枚を、ここで撮る（権限の確認は、開始の操作の中で出す。撮れなければ、何も始めない）。
            if let first = try await screenRecorder?.captureFirst() { attach(first) }
            do { try await beginSegment() } catch { await screenRecorder?.discard(); throw error }
        } catch {
            lifecycle = before
            throw error
        }
        pipeline.begin(sources: speakers)
        startTicker()
        await startScreenRecording()
    }

    /// 一時停止する。取り込みを止め、認識の残りを確定して取り込み、未送信の発話を出し切る。
    public func pause() async throws {
        try transition { try $0.pause() }
        stopTicker()
        await screenRecorder?.stopPeriodic()
        await endSegment()
        pipeline.flushPending(at: elapsed())
    }

    /// 再開する。取り込みを始められなければ、一時停止のまま。
    public func resume() async throws {
        let before = lifecycle
        try transition { try $0.resume() }
        do { try await beginSegment() } catch {
            lifecycle = before
            throw error
        }
        startTicker()
        await startScreenRecording()
    }

    /// 終了する。取り込みを止める → 認識の残りを取り込む → 未送信を出し切る → 記録を書く → 最後に終了の出来事を 1 回出す（SPEC §3.8）。
    public func end(reason: EndReason) async throws -> LiveSessionOutcome {
        try transition { try $0.end(reason) }
        stopTicker()
        await screenRecorder?.stopPeriodic()
        await endSegment()
        await separateVoices()
        let now = clock()
        let end = pipeline.finish(reason: reason, endedAt: now, at: now.timeIntervalSince(startedAt))
        // 画像は、記録（`transcript.md`）と同じフォルダに残る（同じ寿命で、アプリが消す。SPEC §3.8）。
        return LiveSessionOutcome(utterances: end.utterances, transcriptPath: end.transcriptPath)
    }

    /// 名付けの画面に見せる、話者（話者 N）ごとの要約（SPEC §3.15）。会議が終わったあとで、声で分けられていれば、1 人以上。
    public func speakerSummaries() -> [SpeakerSummary] { pipeline.speakerSummaries() }

    /// 人間が確定した名前を、話者 N に付ける（SPEC §3.15）。会議が終わったあとだけ。記録を書き直し、`speakers` の出来事を出す。
    public func nameSpeakers(_ names: [Int: String]) -> Result<SpeakersNamed, SpeakerNamingError> { pipeline.nameSpeakers(names) }

    /// 確定した名前（話者 N → 名前。声紋で自動に付いたものを含む）。
    public func speakerNames() -> [Int: String] { pipeline.speakerNames() }

    /// 話者 N の発話の本文（名前のヒントの計算用。長いものから最大 `SpeakerHintMaker.maxTexts` 件）。
    public func speakerTexts(of id: Int) -> [String] { pipeline.speakerTexts(of: id) }

    /// 声紋の候補（話者 N → 候補。類似度の高い順。自動で付かなかった話者だけ）。
    public func speakerCandidates() -> [Int: [VoiceprintCandidate]] { pipeline.speakerCandidates() }

    /// 話者 N の声の特徴（「この声を覚える」のため。メモリ上だけ）。
    public func voiceEmbedding(of id: Int) -> [Float]? { pipeline.voiceEmbedding(of: id) }

    /// 状態の遷移を、**操作の最初に**行う（許されない遷移は `invalidState`）。操作の途中の待ちで、別の操作が割り込んでも、同じ遷移を 2 度は通らない。
    /// 開始・再開は、そのあとの取り込みが失敗したら、呼び出し側が、遷移の前の状態へ戻す。
    private func transition(_ change: (inout SessionLifecycle) throws -> Void) throws {
        do { try change(&lifecycle) } catch SessionLifecycle.TransitionError.invalid(let from, _) { throw LiveSessionError.invalidState(from) }
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
                let origin = elapsed()
                opened[speaker] = (stream, origin)
                // 声の分離：この塊の最初の音の、会議の時刻（認識の時刻の原点と同じ）。音は、取り込みの口（`DeviceInputs`）が、`recorder` へ足す。
                if speaker == .others { voice?.recorder.setOrigin(origin) }
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

    /// 声による話者の分離（SPEC §3.14）。取り込みを止めたあと・記録を書く前に、1 回だけ。持っていた音声で、分離して、確定した「相手」の発話に話者 ID を付ける。**音声は、成否にかかわらず捨てる**。
    /// 失敗しても、会議の終了は続ける（ID なしで、記録を書く。失敗を、記録と知らせに出す）。
    private func separateVoices() async {
        guard let voice else { return }
        defer { voice.recorder.reset() }
        if voice.recorder.isTruncated { notify(.voiceSeparationTruncated) }
        guard let captured = voice.recorder.snapshot() else { return }
        let separator = voice.separator
        do {
            let separation = try await Task.detached(priority: .userInitiated) { try await separator.separate(captured.samples) }.value
            pipeline.applyVoices(captured.timeline.sessionSegments(from: separation.segments), embeddings: separation.embeddings)
            if let library = voice.library { pipeline.matchVoiceprints(library) }
        } catch {
            let message = (error as? VoiceSeparationError)?.message ?? String(describing: error)
            pipeline.noteVoiceFailure(message)
            notify(.voiceSeparationFailed(message))
        }
    }

    private func consume(_ stream: LiveInputStream, speaker: Speaker, origin: TimeInterval) async {
        do {
            for try await update in stream.updates {
                for part in await labeled(update, speaker: speaker) { ingest(part.update, speaker: speaker, origin: origin, actor: part.actor) }
            }
            if !stopping { notify(.captureStopped(speaker)) }
        } catch {
            if !stopping && !Task.isCancelled { notify(.transcriptionFailed(speaker, String(describing: error))) }
        }
    }

    /// 更新を、話者ごとの区間に分け、アクターを付ける（SPEC §3.13）。「相手」は、確定した更新だけ（暫定の文は、分けず、名前も付けない）。推定の待ちの間、同じ流れの次の更新は、順に待つ。
    /// 区間は、別の発話（別の `id`）になり、元の時刻を文字数で按分した時刻を持つ。失敗したら、1 回だけ知らせ、以後は分けず・付けない（会議は続ける。この更新は、そのまま流す）。
    private func labeled(_ update: TranscriptionUpdate, speaker: Speaker) async -> [(update: TranscriptionUpdate, actor: ActorLabel?)] {
        guard let labeler, !labelingFailed else { return [(update, nil)] }
        do {
            return try await labeler.split(update, speaker: speaker)
        } catch {
            if Task.isCancelled || error is CancellationError { return [(update, nil)] }
            labelingFailed = true
            notify(.speakerGuessFailed)
            return [(update, nil)]
        }
    }

    private func ingest(_ update: TranscriptionUpdate, speaker: Speaker, origin: TimeInterval, actor: ActorLabel?) {
        guard segmentActive else { return }
        let shifted = TranscriptionUpdate(text: update.text, isFinal: update.isFinal, start: update.start + origin, end: update.end + origin)
        pipeline.ingest(shifted, speaker: speaker, actor: actor)
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
        ticker = repeatEvery(tickInterval) { await self.tick() }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    // MARK: 画面

    /// 実行中の定期の撮影を始める。保存した画像は、この actor の中で、次のバッチへ添える（パイプラインを、直列に使うため）。
    private func startScreenRecording() async {
        await screenRecorder?.startPeriodic { [self] shot in await self.attach(shot) }
    }

    private func attach(_ shot: ScreenRecorder.Shot) {
        pipeline.attachScreenshot(path: shot.path, relativePath: shot.relativePath, at: shot.at)
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
