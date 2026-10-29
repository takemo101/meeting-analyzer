import Testing
@testable import MeetingAnalyzerKit

@Suite("UtteranceSegmenter: 発話の区切り（ダウンロードしたモデルは、発話ごとに文字にする）")
struct UtteranceSegmenterTests {
    private func speech(_ n: Int) -> [Float] { Array(repeating: 0.9, count: n) }
    private func silence(_ n: Int) -> [Float] { Array(repeating: 0.05, count: n) }

    private func run(_ blocks: [[Float]], parameters: UtteranceSegmenter.Parameters = .init(), flush: Bool = true) -> [UtteranceSegmenter.Segment] {
        var segmenter = UtteranceSegmenter(parameters: parameters)
        var result = blocks.flatMap { segmenter.push($0) }
        if flush { result += segmenter.flush() }
        return result
    }

    @Test("1 つの発話：始まり・終わりに余白（6 フレーム）が付く。範囲は、半開区間")
    func singleUtterance() {
        // 無音 10 → 声 40（10〜49）→ 無音 30（50 以降）
        let segments = run([silence(10), speech(40), silence(30)])
        #expect(segments == [.init(startFrame: 4, endFrame: 56)])   // 10-6 … 49+1+6
    }

    @Test("文の途中の短い間（終わりの判定の長さ未満）では、切らない。長い間では、2 つの発話に分ける")
    func pauses() {
        let short = run([speech(20), silence(21), speech(20), silence(30)])
        #expect(short.count == 1, "21 フレーム（約 0.67 秒）の間は、続きとみなす")
        let long = run([speech(20), silence(22), speech(20), silence(30)])
        #expect(long.count == 2, "22 フレーム（約 0.7 秒）で、終わる")
        #expect(long[0].endFrame <= long[1].startFrame + 12, "2 つの発話の余白は、ほぼ重ならない")
    }

    @Test("短すぎる音（8 フレーム未満）は、発話として捨てる。ちょうど 8 フレームは残す")
    func tooShort() {
        #expect(run([speech(7), silence(40)]).isEmpty)
        #expect(run([speech(8), silence(40)]).count == 1)
    }

    @Test("語の途中の確率の揺れ（始まりの値と、終わりの値の間）では、発話は終わらない（ヒステリシス）")
    func hysteresis() {
        let dips = [Float](repeating: 0.4, count: 30)   // 0.35 以上 0.5 未満：声が続いているとみなす
        let segments = run([speech(10), dips, speech(10), silence(40)])
        #expect(segments.count == 1)
        // 始まりの値に届かない揺れだけでは、発話は始まらない
        #expect(run([dips, silence(40)]).isEmpty)
    }

    @Test("長すぎる発話は、上限（937 フレーム）で区切り、続きを新しい発話にする。続きの前には、余白を足さない")
    func maxLength() {
        let segments = run([speech(1000), silence(40)])
        #expect(segments.count == 2)
        #expect(segments[0] == .init(startFrame: 0, endFrame: 937))
        #expect(segments[1].startFrame == 937, "続きは、前の発話の終わりから（重ならない）")
        #expect(segments[1].endFrame == 1000 + 6)
    }

    @Test("入力が、発話の途中で終わったら、flush で、そこまでを返す。flush しなければ、返さない")
    func flushTrailing() {
        #expect(run([silence(5), speech(30)]) == [.init(startFrame: 0, endFrame: 5 + 30 + 6)])
        #expect(run([silence(5), speech(30)], flush: false).isEmpty)
        #expect(run([silence(50)]).isEmpty, "声が無ければ、何も返さない")
    }

    @Test("何度に分けて渡しても（1 フレームずつでも）、結果は同じ")
    func chunkInvariance() {
        let all = speech(15) + silence(30) + speech(25) + silence(5) + speech(10) + silence(40) + speech(1200) + silence(30)
        let whole = run([all])
        let single = run(all.map { [$0] })
        let odd = run(stride(from: 0, to: all.count, by: 37).map { Array(all[$0..<min(all.count, $0 + 37)]) })
        #expect(whole == single && whole == odd)
        #expect(whole.count >= 3)
    }
}
