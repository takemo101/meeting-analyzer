import Testing
@testable import MeetingAnalyzerKit

private func utterance(_ id: Int, _ text: String, speaker: Speaker = .others, final: Bool = false, start: Double = 0) -> Utterance {
    Utterance(id: id, speaker: speaker, text: text, isFinal: final, startedAt: start)
}

@Suite("Batcher: 発話の区切りごとのまとめ方")
struct BatcherTests {
    @Test("未送信がなければ、いつまでたっても送らない")
    func nothingPending() {
        var batcher = Batcher()
        #expect(!batcher.isDue(at: 1000))
        #expect(batcher.takeBatch(at: 1000) == nil)
    }

    @Test("変化が止まって 1.2 秒たつと送る。それまでは送らない")
    func quietWindow() {
        var batcher = Batcher()
        batcher.observe(utterance(1, "来週のリリース"), at: 0)
        #expect(!batcher.isDue(at: 1.19))
        #expect(batcher.isDue(at: 1.2))
        #expect(batcher.takeBatch(at: 1.2)?.map(\.text) == ["来週のリリース"])
        #expect(!batcher.hasPending)
    }

    @Test("変化があるたびに、静かな時間の数え直しになる")
    func changeRestartsQuietWindow() {
        var batcher = Batcher()
        batcher.observe(utterance(1, "来週"), at: 0)
        batcher.observe(utterance(1, "来週のリリース"), at: 1)
        #expect(!batcher.isDue(at: 2.1))
        #expect(batcher.isDue(at: 2.2))
        #expect(batcher.takeBatch(at: 2.2)?.map(\.text) == ["来週のリリース"], "同じ発話は、最新の本文を 1 件だけ送る")
    }

    @Test("途切れなく変化しても、最も古い未送信から 10 秒で送る")
    func maxHold() {
        var batcher = Batcher()
        var now = 0.0
        batcher.observe(utterance(1, "x"), at: now)
        for i in 1..<20 {
            now = Double(i) * 0.5
            batcher.observe(utterance(1, "x" + String(repeating: ".", count: i)), at: now)
            #expect(!batcher.isDue(at: now), "9.5 秒までは保留")
        }
        #expect(batcher.isDue(at: 10))
    }

    @Test("新しい発話が始まったら、前の発話を送る。ただし直前の送信から 3 秒は空ける")
    func boundary() {
        var batcher = Batcher()
        batcher.observe(utterance(1, "一つ目"), at: 0)
        batcher.observe(utterance(1, "一つ目です"), at: 0.4)
        batcher.observe(utterance(2, "二つ目"), at: 0.8)
        batcher.observe(utterance(2, "二つ目で"), at: 1.8)
        batcher.observe(utterance(2, "二つ目です"), at: 2.8)   // 静かにならず、続いている
        #expect(!batcher.isDue(at: 2.9), "境界はあるが、前の送信（開始）から 3 秒たっていない")
        #expect(batcher.isDue(at: 3.0))
        #expect(batcher.takeBatch(at: 3.0)?.map(\.text) == ["一つ目です", "二つ目です"])

        // 送った直後の境界は、次の送信まで 3 秒待つ。
        batcher.observe(utterance(2, "二つ目です"), at: 3.1)
        batcher.observe(utterance(3, "三つ目"), at: 3.2)
        #expect(!batcher.isDue(at: 4.0))
        #expect(batcher.isDue(at: 6.0))
    }

    @Test("同じ本文・同じ確定状態の更新は、変化として数えない")
    func identicalUpdateIsIgnored() {
        var batcher = Batcher()
        batcher.observe(utterance(1, "こんにちは"), at: 0)
        _ = batcher.takeBatch(at: 2)
        batcher.observe(utterance(1, "こんにちは"), at: 3)
        #expect(!batcher.hasPending)
        batcher.observe(utterance(1, "こんにちは", final: true), at: 4)
        #expect(batcher.hasPending, "確定は変化")
    }

    @Test("1 回に送る数には上限があり、残りは続けて取り出せる")
    func updateCap() {
        var batcher = Batcher(policy: BatchingPolicy(maxUpdates: 2))
        for id in 1...5 { batcher.observe(utterance(id, "発話\(id)"), at: 0) }
        #expect(batcher.flush(at: 5).map(\.text) == ["発話1", "発話2"])
        #expect(batcher.hasPending)
        #expect(batcher.flush(at: 5).map(\.text) == ["発話3", "発話4"])
        #expect(batcher.flush(at: 5).map(\.text) == ["発話5"])
        #expect(!batcher.hasPending)
    }

    @Test("あなたと相手は、番号が同じでも別の発話")
    func speakersAreSeparate() {
        var batcher = Batcher()
        batcher.observe(utterance(1, "私の発言", speaker: .you), at: 0)
        batcher.observe(utterance(1, "相手の発言", speaker: .others), at: 0.1)
        #expect(batcher.flush(at: 5).map(\.text) == ["私の発言", "相手の発言"])
    }
}
