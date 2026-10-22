import Foundation
import Testing
@testable import MeetingAnalyzerKit

@Suite("SessionLifecycle: 会議の状態遷移")
struct SessionLifecycleTests {
    @Test("開始 → 一時停止 → 再開 → 終了。終わったら、開始し直せない")
    func normalFlow() throws {
        var lifecycle = SessionLifecycle()
        #expect(lifecycle.phase == .idle)
        #expect(!lifecycle.isProcessing)
        try lifecycle.start()
        #expect(lifecycle.isProcessing)
        try lifecycle.pause()
        #expect(!lifecycle.isProcessing, "一時停止中は処理しない")
        try lifecycle.resume()
        try lifecycle.end(.user)
        #expect(lifecycle.phase == .ended(.user))
        #expect(throws: SessionLifecycle.TransitionError.invalid(from: .ended(.user), action: "start")) { try lifecycle.start() }
    }

    @Test("一時停止中でも終了できる。始まる前の終了は断る")
    func endFromPausedOnly() throws {
        var lifecycle = SessionLifecycle()
        #expect(throws: SessionLifecycle.TransitionError.invalid(from: .idle, action: "end")) { try lifecycle.end(.user) }
        try lifecycle.start()
        try lifecycle.pause()
        try lifecycle.end(.silence)
        #expect(lifecycle.phase == .ended(.silence))
    }

    @Test("決められた順序以外は断る")
    func invalidTransitions() throws {
        var lifecycle = SessionLifecycle()
        #expect(throws: SessionLifecycle.TransitionError.invalid(from: .idle, action: "pause")) { try lifecycle.pause() }
        #expect(throws: SessionLifecycle.TransitionError.invalid(from: .idle, action: "resume")) { try lifecycle.resume() }
        try lifecycle.start()
        #expect(throws: SessionLifecycle.TransitionError.invalid(from: .running, action: "start")) { try lifecycle.start() }
        #expect(throws: SessionLifecycle.TransitionError.invalid(from: .running, action: "resume")) { try lifecycle.resume() }
    }
}

@Suite("Transcript: 会議全体の記録")
struct TranscriptTests {
    private func make() -> Transcript {
        var transcript = Transcript()
        transcript.record(Utterance(id: 1, speaker: .others, text: "来週のリリースの件ですが", isFinal: true, startedAt: 3))
        transcript.record(Utterance(id: 1, speaker: .you, text: "はい、確認します", isFinal: true, startedAt: 9))
        transcript.record(Utterance(id: 2, speaker: .others, text: "テスト環境はいつ使えますか", isFinal: true, startedAt: 65))
        return transcript
    }

    @Test("開始時刻の順に並ぶ。同じ時刻ならあなたが先")
    func ordering() {
        var transcript = make()
        transcript.record(Utterance(id: 9, speaker: .others, text: "同時", isFinal: true, startedAt: 9))
        #expect(transcript.ordered.map(\.text) == ["来週のリリースの件ですが", "はい、確認します", "同時", "テスト環境はいつ使えますか"])
    }

    @Test("同じ発話は、最新の本文で置き換わる（件数は増えない）")
    func upsert() {
        var transcript = make()
        transcript.record(Utterance(id: 1, speaker: .others, text: "来週のリリースの件ですが、", isFinal: true, startedAt: 3, version: 2))
        #expect(transcript.utteranceCount == 3)
        #expect(transcript.ordered.first?.text == "来週のリリースの件ですが、")
    }

    @Test("Markdown は、セッションの情報と、時刻・発言者つきの本文と、認識が不確かという注意を含む")
    func markdown() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let text = make().markdown(title: "定例", startedAt: start, endedAt: start.addingTimeInterval(3725))
        #expect(text.contains("- 名前: 定例"))
        #expect(text.contains("- 長さ: 1:02:05"))
        #expect(text.contains("- 発話数: 3"))
        #expect(text.contains("[00:03] 相手: 来週のリリースの件ですが"))
        #expect(text.contains("[00:09] あなた: はい、確認します"))
        #expect(text.contains("[01:05] 相手: テスト環境はいつ使えますか"))
        #expect(text.contains("誤変換"), "認識の自動出力であることを、読み手に伝える")
    }

    @Test("時間の表示は、1 時間未満が mm:ss、以上が h:mm:ss。負の値は 0")
    func clock() {
        #expect(Transcript.clock(0) == "00:00")
        #expect(Transcript.clock(59.9) == "00:59")
        #expect(Transcript.clock(3600) == "1:00:00")
        #expect(Transcript.clock(-5) == "00:00")
    }
}

@Suite("AudioSelection: 取り込む音声の選択")
struct AudioSelectionTests {
    @Test("マイクとシステム音声を、それぞれ選ぶ。流れは、あなた・相手の順")
    func speakers() {
        #expect(AudioSelection(microphone: true, system: .off).speakers == [.you])
        #expect(AudioSelection(microphone: false, system: .all).speakers == [.others])
        #expect(AudioSelection(microphone: true, system: .app(bundleID: "com.apple.Safari", name: "Safari")).speakers == [.you, .others])
    }

    @Test("何も選ばなければ空で、開始できない。既定はマイクだけ")
    func emptyAndDefault() {
        #expect(AudioSelection(microphone: false, system: .off).isEmpty)
        #expect(AudioSelection().speakers == [.you])
        #expect(!AudioSelection().isEmpty)
    }

    @Test("説明は、選んだ音声を示す")
    func summary() {
        #expect(AudioSelection(microphone: true, system: .all).summary == "マイク＋システム全体")
        #expect(AudioSelection(microphone: false, system: .app(bundleID: "x", name: "Safari")).summary == "Safari")
        #expect(AudioSelection(microphone: false, system: .off).summary == "未選択")
    }
}
