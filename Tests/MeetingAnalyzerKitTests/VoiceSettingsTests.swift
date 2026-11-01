import Foundation
import Testing
@testable import MeetingAnalyzerKit

@Suite("声の分離の設定：既定はオフ。オンにできるのは、モデルが取得済みのときだけ。覚える。モデルを消したらオフへ（SPEC §3.14）")
@MainActor
struct VoiceSettingsTests {
    private let model = VoiceModelCatalog.all[0]

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
    private func install(_ model: VoiceModel, in root: URL) throws {
        let store = ModelStore(root: root)
        for artifact in model.artifacts {
            try store.prepareParent(of: artifact)
            FileManager.default.createFile(atPath: store.fileURL(artifact).path, contents: nil)
            let handle = try FileHandle(forWritingTo: store.fileURL(artifact))
            try handle.truncate(atOffset: UInt64(artifact.bytes))
            try handle.close()
            store.markVerified(artifact)
        }
    }

    @Test("既定はオフ。取得していないと、オンにできない。取得済みなら、オンにできて、覚えて、再起動後も同じ")
    func enableRequiresTheModel() throws {
        let root = tempURL("voice-settings"), defaults = defaults()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = controller(root, defaults)
        #expect(!first.voiceSeparation)
        first.setVoiceSeparation(true)
        #expect(!first.voiceSeparation, "未取得は、オンにできない")

        try install(model, in: root)
        first.setVoiceSeparation(true)
        #expect(first.voiceSeparation)
        #expect(controller(root, defaults).voiceSeparation, "再起動しても、同じ")
        first.setVoiceSeparation(false)
        #expect(!controller(root, defaults).voiceSeparation)
    }

    @Test("モデルを消すと、オフに戻る。保存したオンでも、モデルが無ければ、起動のときにオフへ戻す（黙って、モデル無しで動かさない）")
    func deletingTurnsItOff() throws {
        let root = tempURL("voice-settings"), defaults = defaults()
        defer { try? FileManager.default.removeItem(at: root) }
        try install(model, in: root)
        let first = controller(root, defaults)
        first.setVoiceSeparation(true)
        #expect(first.voiceSeparation)
        first.deleteVoiceModel(model)
        #expect(!first.voiceSeparation && !first.isInstalled(model))
        #expect(!controller(root, defaults).voiceSeparation)

        // 設定だけがオンで、モデルが無い（別の Mac から移した・手で消した）。
        var preferences = CapturePreferences()
        preferences.voiceSeparation = true
        preferences.save(defaults)
        #expect(!controller(root, defaults).voiceSeparation)
    }

    @Test("設定の保存：壊れた値・無い値は、オフ。ほかの設定を変えない")
    func preferencesRoundTrip() {
        let defaults = defaults()
        #expect(!CapturePreferences.load(defaults).voiceSeparation)
        var saved = CapturePreferences()
        saved.voiceSeparation = true
        saved.microphone = false
        saved.save(defaults)
        let loaded = CapturePreferences.load(defaults)
        #expect(loaded.voiceSeparation && !loaded.microphone && loaded == saved)
    }
}
