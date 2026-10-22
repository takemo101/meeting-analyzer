import CoreGraphics
import Foundation
import Testing
@testable import MeetingAnalyzerKit

@Suite("記録の書き足し：会議の途中と、終了（SPEC §3.8）")
struct RecordCheckpointTests {
    private func update(_ text: String, _ start: Double, _ end: Double) -> TranscriptionUpdate {
        TranscriptionUpdate(text: text, isFinal: true, start: start, end: end)
    }

    @Test("変わっていれば、一定の秒数ごとに記録を書き直す（途中でも読める）。間隔の内では書かない。終了で、整えた記録（終了・長さ・画像）に書き直す")
    func checkpointsThenFinalizes() throws {
        let root = tempURL("record")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root), sink = RecordingSink()
        let pipeline = SessionPipeline(title: "定例", startedAt: Date(timeIntervalSince1970: 1_800_000_000), sink: sink, store: store, checkpointInterval: 10)
        let file = store.transcriptURL(sessionId: pipeline.sessionId)
        func read() -> String? { try? String(contentsOf: file, encoding: .utf8) }

        pipeline.begin(sources: [.you])
        pipeline.tick(at: 1)
        #expect(read() == nil, "発話が無ければ、書かない")

        pipeline.ingest(update("一つ目の話題です", 0, 1), speaker: .you)
        pipeline.tick(at: 2)
        let first = try #require(read())
        #expect(first.contains("- 状態: 会議の途中") && first.contains("一つ目の話題です"))
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)

        pipeline.ingest(update("二つ目の話題です", 3, 4), speaker: .you)
        pipeline.tick(at: 5)
        #expect(read() == first, "前に書いてから 10 秒たつまでは、書き直さない")
        pipeline.tick(at: 12)
        #expect(read()?.contains("二つ目の話題です") == true, "10 秒たったら、書き直す")

        pipeline.attachScreenshot(path: "/abs/screens/shot-0001.jpg", relativePath: "screens/shot-0001.jpg", at: 13)
        pipeline.tick(at: 14)
        #expect(read()?.contains("shot-0001") == false, "画像だけが変わったときも、間隔の内では書かない")

        let end = pipeline.finish(reason: .user, endedAt: Date(timeIntervalSince1970: 1_800_000_020), at: 20)
        let final = try #require(read())
        #expect(!final.contains("会議の途中") && final.contains("- 長さ: 00:20") && final.contains("![画面 00:13](screens/shot-0001.jpg)"))
        guard case .ended(_, _, _, _, _, _, _, _, let path) = end else { Issue.record("ended ではない"); return }
        #expect(path == file.path)
    }

    @Test("一時停止（出し切り）では、間隔を待たずに書く。何も話されなければ、書かない")
    func pauseForcesWrite() throws {
        let root = tempURL("record-pause")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        let pipeline = SessionPipeline(title: "t", sink: RecordingSink(), store: store, checkpointInterval: 1000)
        pipeline.begin(sources: [.you])
        pipeline.ingest(update("話しました", 0, 1), speaker: .you)
        pipeline.tick(at: 2)   // 初回は、すぐ書く
        pipeline.ingest(update("続きです", 3, 4), speaker: .you)
        pipeline.flushPending(at: 5)
        #expect((try? String(contentsOf: store.transcriptURL(sessionId: pipeline.sessionId), encoding: .utf8))?.contains("続きです") == true)

        let silent = SessionPipeline(title: "t", sink: RecordingSink(), store: store, checkpointInterval: 0)
        silent.begin(sources: [.you])
        silent.tick(at: 5)
        silent.flushPending(at: 6)
        #expect(!FileManager.default.fileExists(atPath: store.transcriptURL(sessionId: silent.sessionId).path))
    }
}

@Suite("LiveSession: 画像つきの記録")
struct LiveSessionRecordTests {
    @Test("撮った画像は、記録のフォルダの screens/ に残り、transcript.md が、時刻の順に、相対パスで参照する（実在するファイルを指す）。会議中も、記録が書き足される")
    func recordReferencesShots() async throws {
        let root = tempURL("record-live")
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = FakeScreen(), sink = RecordingSink(), fake = FakeInputs()
        let live = LiveSession(
            title: "定例", speakers: [.others], inputs: fake.inputs, sink: sink, store: SessionStore(root: root),
            tickInterval: .milliseconds(20), screen: screen.feed, screenshots: ScreenshotStore(root: root),
            screenInterval: .milliseconds(15), screenMinGap: 0, notify: { _ in }
        )
        let file = SessionStore(root: root).transcriptURL(sessionId: live.sessionId)

        try await live.start()
        fake.emit(.others, "最初の話題です", final: true, 0, 1)
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: file.path) { try await Task.sleep(for: .milliseconds(10)) }
        #expect((try? String(contentsOf: file, encoding: .utf8))?.contains("- 状態: 会議の途中") == true, "会議中に、書き足された")

        screen.show(makeImage(patch: (x: 1000, y: 200, w: 600, h: 400, gray: 30)))
        let screens = file.deletingLastPathComponent().appendingPathComponent("screens")
        for _ in 0..<300 where ((try? FileManager.default.contentsOfDirectory(atPath: screens.path))?.count ?? 0) < 2 { try await Task.sleep(for: .milliseconds(10)) }
        fake.emit(.others, "次の話題です", final: true, 2, 3)
        _ = try await live.end(reason: .user)

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("会議の途中") && text.contains("- 画像: 2 枚"))
        for name in ["shot-0001.jpg", "shot-0002.jpg"] {
            #expect(text.contains("](screens/\(name))"), "\(name) を参照する")
            #expect(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent("screens/\(name)").path))
        }
        #expect(!text.contains(root.path), "絶対パスは、入れない（フォルダごと移せる）")
    }
}
