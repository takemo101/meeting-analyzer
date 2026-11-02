import AppKit
import SwiftUI
import Testing
@testable import MeetingAnalyzerKit

@MainActor
@Suite("開始の前の設定の画面の更新")
struct StartPanelRefreshTests {
    private func makeController() throws -> MeetingController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "panel-\(UUID().uuidString)")!
        return MeetingController(environment: ["MEETING_ANALYZER_DATA_DIR": root.path, "MEETING_ANALYZER_SOCKET": "/tmp/ma-\(UUID().uuidString.prefix(8)).sock"], defaults: defaults)
    }

    /// 部品が、`controller`（参照）だけを持つと、SwiftUI は、選んだあとも、部品の本文を作り直さず、画面が前のままになる。画像が変わることで、映ったことを確かめる。
    @Test("選んだ内容が、画面に映る（転送のまとめ方）")
    func selectionShowsOnScreen() async throws {
        let controller = try makeController()
        let model = StartPanelModel(controller: controller)
        let host = NSHostingView(rootView: StartPanelView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 540, height: 1800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host

        func snapshot() -> Data? {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep.representation(using: .png, properties: [:])
        }

        let before = try #require(snapshot())
        let other = try #require(BatchMode.allCases.first { $0 != controller.batchMode })
        controller.setBatchMode(other)
        #expect(controller.batchMode == other)

        var changed = false
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if snapshot() != before { changed = true; break }
        }
        #expect(changed, "選んだのに、画面が前のまま")
    }
}
