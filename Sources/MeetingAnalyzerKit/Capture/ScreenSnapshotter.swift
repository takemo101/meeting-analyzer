import CoreGraphics
import Foundation
import ScreenCaptureKit

/// 画面の撮影（ScreenCaptureKit の 1 枚撮り）。メインの画面、または、選んだアプリのいちばん大きいウィンドウ。画像はメモリ上だけで扱う。
/// 権限（画面収録）が未確認なら、OS の許可の確認が出る（利用者の開始の操作の中だけで、最初の 1 枚を撮る）。
public struct ScreenSnapshotter: Sendable {
    public let selection: ScreenSelection
    /// 撮る画像の、長いほうの辺（これ以上は、撮る時に縮める）。
    private let maxEdge = 1280

    public init(selection: ScreenSelection) {
        self.selection = selection
    }

    public func snapshot() async throws -> CGImage {
        let content: SCShareableContent
        do {
            // 別のデスクトップ・フルスクリーンにあるウィンドウも、一覧に入れる（画面に出ているものを優先して選ぶ）。
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.permissionDenied(.screenRecording, Self.permissionText(error))
        }
        let filter: SCContentFilter
        let size: CGSize
        switch selection {
        case .off:
            throw CaptureError.failed("画面の取り込みが選ばれていません")
        case .display:
            guard let display = content.displays.first else { throw CaptureError.targetNotFound("画面が見つかりません") }
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            size = CGSize(width: display.width, height: display.height)
        case .app(let bundleID, let name):
            let processIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
            let candidates = content.windows.map {
                WindowCandidate(bundleID: $0.owningApplication?.bundleIdentifier, processID: $0.owningApplication?.processID ?? -1, layer: $0.windowLayer,
                                width: $0.frame.width, height: $0.frame.height, isOnScreen: $0.isOnScreen)
            }
            guard let index = WindowPicker.pick(candidates, bundleID: bundleID, processIDs: processIDs) else {
                let all = WindowPicker.appWindows(candidates, bundleID: bundleID, processIDs: processIDs)
                let running = !processIDs.isEmpty
                throw CaptureError.targetNotFound("「\(name)」の撮れるウィンドウがありません（\(running ? "起動中" : "起動していません")。通常のウィンドウ \(all.count) 件。最小化していないか、確認してください）")
            }
            let window = content.windows[index]
            filter = SCContentFilter(desktopIndependentWindow: window)
            size = window.frame.size
        }
        let scale = min(1, Double(maxEdge) / Double(max(size.width, size.height)))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((size.width * scale).rounded()))
        configuration.height = max(1, Int((size.height * scale).rounded()))
        configuration.showsCursor = false
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw CaptureError.failed("画面を撮れません: \(error.localizedDescription)")
        }
    }

    private static func permissionText(_ error: Error) -> String {
        "画面収録が許可されていません。システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオの録音 で、meeting-analyzer をオンにしてください。\n\nすでにオンでも、アプリを入れ直すと、許可が無効になることがあります（一度「−」で削除して、もう一度開始してください）。\n\n詳細: \(error.localizedDescription)"
    }
}
