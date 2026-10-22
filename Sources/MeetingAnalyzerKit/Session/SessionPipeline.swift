import Foundation

/// 文字起こしの更新 → 発話 → バッチ → エージェントへの出来事、そして終了の出来事までの流れ（SPEC §3.6・§3.8）。
/// 入力が「ファイルの再生」でも「マイク・システム音声」でも同じ流れを通す。時計は、更新が持つ秒数（セッションの開始からの経過）を使う。
/// すべて同期で、公開は失敗しない。1 度に 1 つの呼び出しだけが入る前提（`LiveSession` の actor が、それを保つ）。
public final class SessionPipeline: @unchecked Sendable {
    public let sessionId: UUID
    public let title: String
    public let startedAt: Date

    private let sink: any EventSink
    private let store: SessionStore?
    private var batcher: Batcher
    private var transcript = Transcript()
    private var streams: [Speaker: Stream] = [:]
    private var sequence = 0
    private var finished = false

    private struct Stream {
        var currentId = 0
        var lastWasFinal = true
        var version = 0
    }

    public init(sessionId: UUID = UUID(), title: String, startedAt: Date = Date(), sink: any EventSink, store: SessionStore?, policy: BatchingPolicy = .standard) {
        self.sessionId = sessionId
        self.title = title
        self.startedAt = startedAt
        self.sink = sink
        self.store = store
        self.batcher = Batcher(policy: policy)
    }

    public var batchCount: Int { sequence }
    public var utteranceCount: Int { transcript.utteranceCount }

    /// セッションの開始を知らせる（取り込む流れ付き）。
    public func begin(sources: [Speaker]) {
        sink.publish(.started(sessionId: sessionId, title: title, startedAt: startedAt, sources: sources))
    }

    /// 時間だけが進んだとき（更新が来ない間）の確認。静けさが十分なら、溜まった発話を送る。実際の取り込みでは、定期的に呼ぶ。
    public func tick(at now: TimeInterval) {
        guard !finished else { return }
        while let batch = batcher.takeBatch(at: now) { deliver(batch) }
    }

    /// 更新を 1 つ受ける。確定した発話の次の更新は、新しい発話として扱う。送る時になっていれば、送る。
    public func ingest(_ update: TranscriptionUpdate, speaker: Speaker) {
        guard !finished else { return }
        // 前の更新からこの更新までに、静けさが十分あったなら、前の発話は、この更新を混ぜずに送る。
        tick(at: update.end)
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var stream = streams[speaker] ?? Stream()
        if stream.lastWasFinal { stream.currentId += 1; stream.version = 0 }
        stream.version += 1
        stream.lastWasFinal = update.isFinal
        streams[speaker] = stream
        let utterance = Utterance(id: stream.currentId, speaker: speaker, text: text, isFinal: update.isFinal, startedAt: update.start, version: stream.version)
        transcript.record(utterance)
        batcher.observe(utterance, at: update.end)
        while let batch = batcher.takeBatch(at: update.end) { deliver(batch) }
    }

    /// 一時停止のとき、未送信の発話を出し切る（送るべき時を待たない）。
    public func flushPending(at now: TimeInterval) {
        guard !finished else { return }
        while batcher.hasPending { deliver(batcher.flush(at: now)) }
    }

    /// セッションを終える。未送信の発話を出し切り、記録を書き、最後に終了の出来事を 1 回だけ出す。
    @discardableResult
    public func finish(reason: EndReason, endedAt: Date = Date(), at now: TimeInterval) -> TranscriptEvent {
        precondition(!finished, "finish は 1 回だけ")
        while batcher.hasPending { deliver(batcher.flush(at: now)) }
        finished = true
        var transcriptPath: String?
        if let store, !transcript.isEmpty {
            let markdown = transcript.markdown(title: title, startedAt: startedAt, endedAt: endedAt)
            if case .success(let url) = store.writeTranscript(markdown, sessionId: sessionId) { transcriptPath = url.path }
        }
        let end = TranscriptEvent.ended(
            sessionId: sessionId, title: title, reason: reason, startedAt: startedAt, endedAt: endedAt,
            batches: sequence, utterances: transcript.utteranceCount, transcriptPath: transcriptPath
        )
        sink.publish(end)
        return end
    }

    private func deliver(_ utterances: [Utterance]) {
        guard !utterances.isEmpty else { return }
        sequence += 1
        sink.publish(.captions(sessionId: sessionId, sequence: sequence, utterances: utterances, sessionStart: startedAt))
    }
}
