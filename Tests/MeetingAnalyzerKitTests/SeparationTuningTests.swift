import Foundation
import Testing
@testable import MeetingAnalyzerKit

@Suite("分離の調整：設定の保存・範囲・分離器へ渡る（SPEC §3.16）")
@MainActor
struct SeparationTuningTests {
    private func defaults() -> UserDefaults {
        let name = "ma-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func controller(_ root: URL, _ defaults: UserDefaults) -> MeetingController {
        MeetingController(environment: ["MEETING_ANALYZER_DATA_DIR": root.path, "MEETING_ANALYZER_SOCKET": "/tmp/ma-\(UUID().uuidString.prefix(8)).sock"], defaults: defaults)
    }

    @Test("既定は無指定（FluidAudio の既定）。範囲内だけ指定できる（範囲外は変えない）。覚える。「既定に戻す」で無指定へ。壊れた保存値は、無指定へ戻す")
    func rangesAndPersistence() throws {
        let root = tempURL("tuning"), defaults = defaults()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = controller(root, defaults)
        #expect(first.voiceClusterThreshold == nil && first.voiceMinSegmentSeconds == nil)
        #expect(first.voiceTuning(speakerCount: nil) == VoiceSeparationTuning())

        first.setVoiceClusterThreshold(0.45)
        first.setVoiceMinSegmentSeconds(0.5)
        let again = controller(root, defaults)
        #expect(again.voiceClusterThreshold == 0.45 && again.voiceMinSegmentSeconds == 0.5, "再起動しても、同じ")

        first.setVoiceClusterThreshold(0.95)   // 範囲外
        first.setVoiceClusterThreshold(0.1)
        first.setVoiceMinSegmentSeconds(0.0)
        first.setVoiceMinSegmentSeconds(5)
        #expect(first.voiceClusterThreshold == 0.45 && first.voiceMinSegmentSeconds == 0.5, "範囲外は、変えない")

        first.setVoiceClusterThreshold(nil)
        first.setVoiceMinSegmentSeconds(nil)
        #expect(first.voiceClusterThreshold == nil && controller(root, defaults).voiceMinSegmentSeconds == nil)

        defaults.set(5.0, forKey: "capture.voiceClusterThreshold")
        defaults.set(-1.0, forKey: "capture.voiceMinSegmentSeconds")
        let broken = CapturePreferences.load(defaults)
        #expect(broken.voiceClusterThreshold == nil && broken.voiceMinSegmentSeconds == nil, "範囲外の保存値は、無指定へ戻す")
    }

    @Test("調整の値は、人数と一緒に、分離器の設定（`voiceTuning`）に入る")
    func passedToTheSeparator() throws {
        let root = tempURL("tuning-pass"), defaults = defaults()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = controller(root, defaults)
        controller.setVoiceClusterThreshold(0.4)
        controller.setVoiceMinSegmentSeconds(0.6)
        #expect(controller.voiceTuning(speakerCount: 3) == VoiceSeparationTuning(speakerCount: 3, clusterThreshold: 0.4, minSegmentSeconds: 0.6))
        #expect(controller.voiceTuning(speakerCount: nil) == VoiceSeparationTuning(speakerCount: nil, clusterThreshold: 0.4, minSegmentSeconds: 0.6))
    }
}
