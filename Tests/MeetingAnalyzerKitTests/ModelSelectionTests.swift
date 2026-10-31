import Foundation
import Testing
@testable import MeetingAnalyzerKit

@Suite("文字起こしのモデルの選択：取得済みのものだけ。覚える。消したら Mac 標準へ（SPEC §3.12）")
@MainActor
struct ModelSelectionTests {
    private let model = LocalModelCatalog.all[1]   // Qwen3-ASR 0.6B

    private func defaults() -> UserDefaults {
        let name = "ma-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func controller(_ root: URL, _ defaults: UserDefaults) -> MeetingController {
        MeetingController(environment: ["MEETING_ANALYZER_DATA_DIR": root.path, "MEETING_ANALYZER_SOCKET": "/tmp/ma-\(UUID().uuidString.prefix(8)).sock"], defaults: defaults)
    }

    /// 取得済みに見せる（大きさだけ合わせた、中身の無い〔疎な〕ファイルと、検証済みの印）。SHA-256 の計算はしない。
    private func install(_ model: LocalModel, in root: URL) throws {
        let store = ModelStore(root: root)
        try store.prepareDirectory()
        let url = store.fileURL(model.artifact)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(model.artifact.bytes))
        try handle.close()
        store.markVerified(model.artifact)
    }

    @Test("既定は Mac 標準。取得していないモデルは、選べない。取得済みなら選べて、覚えて、再起動後も同じ")
    func selectAndRemember() throws {
        let root = tempURL("model-select"), defaults = defaults()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = controller(root, defaults)
        #expect(first.transcription == .apple)
        first.setTranscription(.local(model.id))
        #expect(first.transcription == .apple, "未取得は選べない")
        first.setTranscription(.local("no-such-model"))
        #expect(first.transcription == .apple)

        try install(model, in: root)
        #expect(first.isInstalled(model))
        first.setTranscription(.local(model.id))
        #expect(first.transcription == .local(model.id))
        #expect(CapturePreferences.load(defaults).transcription == .local(model.id))

        let second = controller(root, defaults)
        #expect(second.transcription == .local(model.id), "再起動しても、同じ選択")
    }

    @Test("保存したモデルが、もう取得されていなければ（消した・移した）、Mac 標準に戻る。壊れた保存値も、Mac 標準")
    func missingOrBrokenFallsBackToApple() throws {
        let root = tempURL("model-missing"), defaults = defaults()
        defer { try? FileManager.default.removeItem(at: root) }
        var saved = CapturePreferences()
        saved.transcription = .local(model.id)
        saved.save(defaults)
        #expect(controller(root, defaults).transcription == .apple, "ファイルが無い")

        defaults.set("gpt-9000", forKey: CapturePreferences.keys.transcription)
        #expect(CapturePreferences.load(defaults).transcription == .apple, "知らない ID")
        defaults.set(42, forKey: CapturePreferences.keys.transcription)
        #expect(CapturePreferences.load(defaults).transcription == .apple, "型が違う")
    }

    @Test("使っているモデルを削除すると、Mac 標準に戻り（保存も）、ファイルが消える。使っていないモデルの削除は、選択を変えない")
    func deleting() throws {
        let root = tempURL("model-delete"), defaults = defaults()
        defer { try? FileManager.default.removeItem(at: root) }
        try install(model, in: root)
        let other = LocalModelCatalog.all[0]
        try install(other, in: root)
        let c = controller(root, defaults)
        c.setTranscription(.local(model.id))
        c.deleteModel(other)
        #expect(c.transcription == .local(model.id) && !c.isInstalled(other))
        c.deleteModel(model)
        #expect(c.transcription == .apple && !c.isInstalled(model))
        #expect(CapturePreferences.load(defaults).transcription == .apple)
        #expect(!FileManager.default.fileExists(atPath: ModelStore(root: root).fileURL(model.artifact).path))
    }

    @Test("途中までのダウンロードを捨てる：途中のファイル（.part）だけが消える。取得済みのモデル・別のモデルの途中のファイルには、触れない")
    func discardingPartial() throws {
        let root = tempURL("model-discard"), defaults = defaults()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelStore(root: root)
        try store.prepareDirectory()
        let other = LocalModelCatalog.all[0]
        try Data(repeating: 1, count: 1000).write(to: store.partURL(model.artifact))
        try Data(repeating: 2, count: 500).write(to: store.partURL(other.artifact))
        let c = controller(root, defaults)
        #expect(store.downloadedBytes(model.artifact) == 1000)
        c.downloads.discardPartial(model)
        #expect(store.downloadedBytes(model.artifact) == 0 && !FileManager.default.fileExists(atPath: store.partURL(model.artifact).path))
        #expect(store.downloadedBytes(other.artifact) == 500, "別のモデルの途中のファイルは、そのまま")

        // 取得済みなら、何もしない（取得済みのファイルは消えない）
        try install(model, in: root)
        c.downloads.discardPartial(model)
        #expect(c.isInstalled(model))
    }
}
