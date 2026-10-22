import Foundation

/// 文字起こしの更新 → 発話 → バッチ → ブリッジ、そして終了の合図までの流れ（SPEC §3.6・§3.8）。
/// 入力が「ファイルの再生」でも「マイク・システム音声」でも同じ流れを通す。時計は、更新が持つ秒数（セッションの開始からの経過）を使う。
public final class SessionPipeline: @unchecked Sendable {
    public let sessionId: UUID
    public let meetingId: String
    public let startedAt: Date

    private let sender: any BridgeSending
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

    public init(sessionId: UUID = UUID(), meetingId: String, startedAt: Date = Date(), sender: any BridgeSending, store: SessionStore?, policy: BatchingPolicy = .standard) {
        self.sessionId = sessionId
        self.meetingId = meetingId
        self.startedAt = startedAt
        self.sender = sender
        self.store = store
        self.batcher = Batcher(policy: policy)
    }

    public var batchCount: Int { sequence }
    public var utteranceCount: Int { transcript.utteranceCount }

    /// 時間だけが進んだとき（更新が来ない間）の確認。静けさが十分なら、溜まった発話を送る。実際の取り込みでは、定期的に呼ぶ。
    public func tick(at now: TimeInterval) async throws {
        guard !finished else { return }
        while let batch = batcher.takeBatch(at: now) { try await deliver(batch) }
    }

    /// 更新を 1 つ受ける。確定した発話の次の更新は、新しい発話として扱う。送る時になっていれば、ブリッジへ送る。
    public func ingest(_ update: TranscriptionUpdate, speaker: Speaker) async throws {
        guard !finished else { return }
        // 前の更新からこの更新までに、静けさが十分あったなら、前の発話は、この更新を混ぜずに送る。
        try await tick(at: update.end)
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
        while let batch = batcher.takeBatch(at: update.end) { try await deliver(batch) }
    }

    /// 一時停止のとき、未送信の発話を出し切る（送るべき時を待たない）。
    public func flushPending(at now: TimeInterval) async throws {
        guard !finished else { return }
        while batcher.hasPending { try await deliver(batcher.flush(at: now)) }
    }

    /// 会議を終える。未送信の発話を出し切り、記録を書き、最後に終了の合図を送る。
    /// 出し切りに失敗しても、記録は書き、終了の合図も試す。最初の失敗を、最後に投げる（失敗を握り潰さず、記録も失わない）。
    @discardableResult
    public func finish(reason: EndReason, endedAt: Date = Date(), at now: TimeInterval) async throws -> EndEvent {
        precondition(!finished, "finish は 1 回だけ")
        finished = true
        var failure: Error?
        while batcher.hasPending {
            do { try await deliver(batcher.flush(at: now)) } catch { failure = failure ?? error }
        }
        var transcriptPath: String?
        if let store, !transcript.isEmpty {
            let markdown = transcript.markdown(meetingId: meetingId, startedAt: startedAt, endedAt: endedAt)
            if case .success(let url) = store.writeTranscript(markdown, sessionId: sessionId) { transcriptPath = url.path }
        }
        let end = EndEvent.make(
            sessionId: sessionId, meetingId: meetingId, reason: reason, startedAt: startedAt, endedAt: endedAt,
            batches: sequence, utterances: transcript.utteranceCount, transcriptPath: transcriptPath
        )
        do { try await sender.send(end) } catch { failure = failure ?? error }
        if let failure { throw failure }
        return end
    }

    private func deliver(_ utterances: [Utterance]) async throws {
        guard !utterances.isEmpty else { return }
        sequence += 1
        try await sender.send(CaptionBatch.make(sessionId: sessionId, sequence: sequence, meetingId: meetingId, utterances: utterances, sessionStart: startedAt))
    }
}
