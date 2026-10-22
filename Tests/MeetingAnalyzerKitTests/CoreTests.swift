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

    @Test("開始時刻の順に並ぶ。同じ時刻なら本人が先")
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
        #expect(text.contains("[00:09] 本人: はい、確認します"))
        #expect(text.contains("[01:05] 相手: テスト環境はいつ使えますか"))
        #expect(text.contains("誤変換"), "認識の自動出力であることを、読み手に伝える")
    }

    @Test("画像は、時刻の順に、発話の間へ入る（相対パス）。同じ時刻なら、発話の前。最後の発話より後の画像は、末尾。発話・画像は、空行で区切る")
    func markdownWithScreenshots() {
        var transcript = make()   // 発話: 00:03 相手 / 00:09 本人 / 01:05 相手
        transcript.recordScreenshot(at: 20, path: "screens/shot-0002.jpg")
        transcript.recordScreenshot(at: 0, path: "screens/shot-0001.jpg")
        transcript.recordScreenshot(at: 65, path: "screens/shot-0003.jpg")
        transcript.recordScreenshot(at: 300, path: "screens/shot-0004.jpg")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let text = transcript.markdown(title: "定例", startedAt: start, endedAt: start.addingTimeInterval(400))
        let blocks = text.split(separator: "\n\n").map { $0.trimmingCharacters(in: .newlines) }
        let body = Array(blocks.drop { !$0.hasPrefix("![") && !$0.hasPrefix("[") })
        #expect(body == [
            "![画面 00:00](screens/shot-0001.jpg)",
            "[00:03] 相手: 来週のリリースの件ですが",
            "[00:09] 本人: はい、確認します",
            "![画面 00:20](screens/shot-0002.jpg)",
            "![画面 01:05](screens/shot-0003.jpg)",
            "[01:05] 相手: テスト環境はいつ使えますか",
            "![画面 05:00](screens/shot-0004.jpg)",
        ])
        #expect(text.contains("- 画像: 4 枚"))
        #expect(transcript.screenshotCount == 4)
    }

    @Test("会議の途中の書き足し（終了が無い）は、「会議の途中」と書き、終了・長さの行を持たない。画像が無ければ、画像の行も無い")
    func markdownInProgress() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let text = make().markdown(title: "定例", startedAt: start, endedAt: nil)
        #expect(text.contains("- 状態: 会議の途中"))
        #expect(!text.contains("- 終了:") && !text.contains("- 長さ:") && !text.contains("- 画像:"))
        #expect(text.contains("[00:09] 本人: はい、確認します"))
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
    @Test("マイクとシステム音声を、それぞれ選ぶ。流れは、本人・相手の順")
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

@Suite("EchoDetector: 相手の声のマイクへの回り込みの疑い")
struct EchoDetectorTests {
    private let sentence = "来週のリリースの件ですがテスト環境はいつ使えますか"

    /// 発話を 1 つ見て、疑うかを返す（`#expect` の中では、変更する呼び出しを書けないので）。
    private func see(_ detector: inout EchoDetector, _ speaker: Speaker, _ key: String, _ text: String, at time: TimeInterval) -> Bool {
        detector.observe(speaker: speaker, key: key, text: text, at: time)
    }

    @Test("本人の発話が、直近の相手の発話とほとんど同じなら、疑う（句読点・空白・一部の欠けがあっても）")
    func detectsLeak() {
        var detector = EchoDetector()
        let first = see(&detector, .others, "o1", sentence, at: 10)
        let full = see(&detector, .you, "y1", "来週のリリースの件ですが、テスト環境は いつ使えますか。", at: 11)
        let partial = see(&detector, .you, "y2", "リリースの件ですがテスト環境はいつ", at: 12)
        #expect(!first)
        #expect(full)
        #expect(partial, "マイクが、一部だけ拾っても")
    }

    @Test("無関係な発話・短い相づち・時間がたった相手の発話は、疑わない")
    func ignoresUnrelated() {
        var detector = EchoDetector()
        _ = see(&detector, .others, "o1", sentence, at: 10)
        let unrelated = see(&detector, .you, "y1", "金曜までに見積もりを出しておきます", at: 11)
        let short = see(&detector, .you, "y2", "はい", at: 11)
        let stale = see(&detector, .you, "y3", sentence, at: 21)
        var empty = EchoDetector()
        let none = see(&empty, .you, "y", sentence, at: 1)
        #expect(!unrelated)
        #expect(!short)
        #expect(!stale, "10 秒より前の相手の発話は、比べない")
        #expect(!none, "相手の発話がまだ無い")
    }

    @Test("相手の同じ発話は、最新の本文で置き換わる（途中の本文が古く残らない）")
    func upsertsOthers() {
        var detector = EchoDetector()
        _ = see(&detector, .others, "o1", "今日は", at: 10)
        _ = see(&detector, .others, "o1", sentence, at: 11)
        let leak = see(&detector, .you, "y1", sentence, at: 12)
        #expect(leak)
    }
}
