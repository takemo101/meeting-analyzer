import Foundation
import Testing
@testable import MeetingAnalyzerKit

/// 偽の入力。発言者ごとに、更新を流せる。`stop` で、残りの確定を流してから終わる（実際の認識と同じ）。
final class FakeInputs: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [Speaker: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation] = [:]
    private(set) var opened: [Speaker] = []
    private(set) var stopped: [Speaker] = []
    var openError: [Speaker: Error] = [:]
    /// `stop` のときに、流す最後の更新。
    var finalOnStop: [Speaker: TranscriptionUpdate] = [:]

    var inputs: LiveInputs {
        LiveInputs { [self] speaker in
            if let error = openError[speaker] { throw error }
            let (stream, continuation) = AsyncThrowingStream<TranscriptionUpdate, Error>.makeStream()
            lock.withLock { continuations[speaker] = continuation; opened.append(speaker) }
            return LiveInputStream(updates: stream, stop: { [self] in
                lock.withLock { stopped.append(speaker) }
                if let last = finalOnStop[speaker] { continuation.yield(last) }
                continuation.finish()
            })
        }
    }

    func emit(_ speaker: Speaker, _ text: String, final: Bool = false, _ start: Double, _ end: Double) {
        lock.withLock { _ = continuations[speaker]?.yield(TranscriptionUpdate(text: text, isFinal: final, start: start, end: end)) }
    }

    func fail(_ speaker: Speaker, _ error: Error) {
        lock.withLock { continuations[speaker]?.finish(throwing: error) }
    }

    func finish(_ speaker: Speaker) {
        lock.withLock { continuations[speaker]?.finish() }
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

final class Notices: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [LiveSessionNotice] = []
    var all: [LiveSessionNotice] { lock.withLock { items } }
    func add(_ notice: LiveSessionNotice) { lock.withLock { items.append(notice) } }
}

private func root() -> URL { tempURL("live") }

private func eventually(timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

private struct Rig {
    let fake = FakeInputs()
    let sink = RecordingSink()
    let clock = TestClock()
    let notices = Notices()
    let store = SessionStore(root: root())

    func session(speakers: [Speaker] = [.you, .others], policy: BatchingPolicy = .standard, tick: Duration = .seconds(60)) -> LiveSession {
        let clock = self.clock, notices = self.notices
        return LiveSession(
            title: "テスト会議", speakers: speakers, inputs: fake.inputs, sink: sink, store: store, policy: policy,
            clock: { clock.now }, tickInterval: tick, notify: { notices.add($0) }
        )
    }
}

@Suite("LiveSession: 開始・一時停止・再開・終了")
struct LiveSessionTests {
    @Test("本人と相手の発話が、1 つのセッションとして送られ、終了の合図が最後に 1 回だけ届き、記録が書かれる")
    func endToEnd() async throws {
        let rig = Rig()
        let session = rig.session()
        try await session.start()
        rig.fake.emit(.others, "来週のリリースの件です", final: true, 0, 2)
        rig.fake.emit(.you, "確認します", final: true, 3, 4)
        rig.clock.advance(65)
        let outcome = try await session.end(reason: .user)

        #expect(outcome.utterances == 2)
        #expect(rig.sink.kinds.first == "started" && rig.sink.kinds.last == "ended")
        #expect(rig.sink.ends.count == 1)
        #expect(Set(rig.sink.events.map(\.sessionId)).count == 1, "すべての出来事が、同じセッション")
        let spoken = rig.sink.batches.flatMap(\.updates).map(\.speaker)
        #expect(spoken.contains("相手") && spoken.contains("本人"))
        let ended = try #require(EndedInfo(rig.sink.ends[0]))
        #expect(ended.reason == "user" && ended.durationSeconds == 65)
        let path = try #require(outcome.transcriptPath)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("相手: 来週のリリースの件です") && text.contains("本人: 確認します"))
        #expect(await session.phase == .ended(.user))
    }

    @Test("一時停止：取り込みを止め、止める時に確定した発話まで送り、停止中の更新は処理しない。再開で時刻が続く")
    func pauseResume() async throws {
        let rig = Rig()
        rig.fake.finalOnStop[.others] = TranscriptionUpdate(text: "最初の話題です。", isFinal: true, start: 0, end: 2)
        let session = rig.session()
        try await session.start()
        try await session.pause()

        #expect(await session.phase == .paused)
        #expect(Set(rig.fake.stopped) == [.you, .others])
        #expect(rig.sink.batches.flatMap(\.updates).map(\.text) == ["最初の話題です。"])

        rig.clock.advance(60)
        rig.fake.finalOnStop = [:]
        try await session.resume()
        #expect(await session.phase == .running)
        #expect(rig.fake.opened.count == 4)
        rig.fake.emit(.others, "再開後の話題", final: true, 0, 1)
        rig.clock.advance(5)
        _ = try await session.end(reason: .user)

        let updates = rig.sink.batches.flatMap(\.updates)
        let first = try #require(updates.first { $0.text == "最初の話題です。" })
        let second = try #require(updates.first { $0.text == "再開後の話題" })
        #expect(second.timestamp - first.timestamp == 60_000)
        #expect(first.id != second.id)
    }

    @Test("順序以外の操作は断る。終了したセッションは、開始し直せない")
    func invalidTransitions() async throws {
        let rig = Rig()
        let session = rig.session()
        await #expect(throws: LiveSessionError.invalidState(.idle)) { try await session.end(reason: .user) }
        await #expect(throws: LiveSessionError.invalidState(.idle)) { try await session.pause() }
        try await session.start()
        await #expect(throws: LiveSessionError.invalidState(.running)) { try await session.resume() }
        await #expect(throws: LiveSessionError.invalidState(.running)) { try await session.start() }
        _ = try await session.end(reason: .user)
        await #expect(throws: LiveSessionError.invalidState(.ended(.user))) { try await session.start() }
        await #expect(throws: LiveSessionError.invalidState(.ended(.user))) { try await session.end(reason: .user) }
        #expect(rig.sink.ends.count == 1)
    }

    @Test("選んだ音声だけを開く。マイクだけなら、システム音声は開かない")
    func opensOnlySelectedSpeakers() async throws {
        let rig = Rig()
        let session = rig.session(speakers: [.you])
        try await session.start()
        rig.fake.emit(.you, "自分だけ", final: true, 0, 1)
        _ = try await session.end(reason: .user)
        #expect(rig.fake.opened == [.you])
        #expect(rig.sink.batches.flatMap(\.updates).map(\.speaker) == ["本人"])
    }

    @Test("何も選ばれていなければ、開始できず、何も開かない")
    func emptySelectionCannotStart() async {
        let rig = Rig()
        let session = rig.session(speakers: [])
        await #expect(throws: LiveSessionError.failed("取り込む音声が選ばれていません")) { try await session.start() }
        #expect(rig.fake.opened.isEmpty)
        #expect(await session.phase == .idle)
    }

    @Test("相手の取り込みを始められないとき（権限なし）、開いたマイクも止め、待機のまま。何も送らない")
    func partialOpenIsRolledBack() async {
        let rig = Rig()
        rig.fake.openError[.others] = CaptureError.permissionDenied(.screenRecording, "画面収録")
        let session = rig.session()
        await #expect(throws: LiveSessionError.capture(.permissionDenied(.screenRecording, "画面収録"))) { try await session.start() }
        #expect(rig.fake.stopped == [.you])
        #expect(await session.phase == .idle)
        #expect(rig.sink.events.isEmpty)
    }

    @Test("再開で取り込みを始められないときは、一時停止のまま")
    func failedResumeStaysPaused() async throws {
        let rig = Rig()
        let session = rig.session()
        try await session.start()
        try await session.pause()
        rig.fake.openError[.you] = CaptureError.permissionDenied(.microphone, "マイク")
        await #expect(throws: LiveSessionError.capture(.permissionDenied(.microphone, "マイク"))) { try await session.resume() }
        #expect(await session.phase == .paused)
        rig.fake.openError = [:]
        try await session.resume()
        #expect(await session.phase == .running)
        _ = try await session.end(reason: .user)
    }

    @Test("片方の認識が失敗しても、知らせを出して、もう片方と会議は続く")
    func oneStreamFailureContinues() async throws {
        let rig = Rig()
        let session = rig.session()
        try await session.start()
        rig.fake.fail(.others, TranscriptionError.failed("モデル"))
        #expect(await eventually { rig.notices.all.contains { if case .transcriptionFailed(.others, _) = $0 { return true } else { return false } } })
        rig.fake.emit(.you, "続けます", final: true, 0, 1)
        let outcome = try await session.end(reason: .user)
        #expect(outcome.utterances == 1)
        #expect(await session.phase == .ended(.user))
    }

    @Test("本人の発話が相手の発話とほとんど同じなら、回り込みの疑いを 1 回だけ知らせる。会議は続く")
    func echoIsReportedOnce() async throws {
        let rig = Rig()
        let session = rig.session()
        try await session.start()
        rig.fake.emit(.others, "来週のリリースの件ですがテスト環境はいつ使えますか", 0, 3)
        rig.fake.emit(.you, "来週のリリースの件ですがテスト環境はいつ使えますか", 0.2, 3.2)
        rig.fake.emit(.you, "来週のリリースの件ですがテスト環境はいつ使えますか。", 0.2, 3.5)
        #expect(await eventually { rig.notices.all.contains(.possibleEcho) })
        let outcome = try await session.end(reason: .user)
        #expect(rig.notices.all.filter { $0 == .possibleEcho }.count == 1)
        #expect(outcome.utterances == 2, "疑っても、発話は消さない")
    }

    @Test("無関係な発話では、回り込みを知らせない")
    func noEchoNotice() async throws {
        let rig = Rig()
        let session = rig.session()
        try await session.start()
        rig.fake.emit(.others, "来週のリリースの件ですがテスト環境はいつ使えますか", 0, 3)
        rig.fake.emit(.you, "金曜までに見積もりを出しておきます", 3.5, 6)
        _ = try await session.end(reason: .user)
        #expect(rig.notices.all.isEmpty)
    }

    @Test("取り込みが勝手に止まったら知らせる。利用者が止めたときは知らせない")
    func unexpectedStopIsReported() async throws {
        let rig = Rig()
        let session = rig.session()
        try await session.start()
        rig.fake.finish(.others)
        #expect(await eventually { rig.notices.all.contains(.captureStopped(.others)) })
        _ = try await session.end(reason: .user)
        #expect(rig.notices.all == [.captureStopped(.others)])
    }

    @Test("更新が来なくても、時間が進めば（tick）、静かになった発話が送られる")
    func tickSendsWithoutNewUpdates() async throws {
        let rig = Rig()
        let session = rig.session(policy: BatchingPolicy(quiet: 1.2, maxHold: 10, boundaryGap: 3, maxUpdates: 64), tick: .milliseconds(20))
        try await session.start()
        rig.fake.emit(.others, "静かになる発話", 0, 0)
        rig.clock.advance(2)
        #expect(await eventually { rig.sink.batches.flatMap(\.updates).map(\.text) == ["静かになる発話"] })
        _ = try await session.end(reason: .user)
        #expect(rig.sink.batches.count == 1)
    }

}
