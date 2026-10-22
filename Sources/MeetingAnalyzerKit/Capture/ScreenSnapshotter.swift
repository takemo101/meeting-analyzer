import CoreGraphics
import Foundation
import ScreenCaptureKit

/// 画面の撮影（ScreenCaptureKit の 1 枚撮り）。メインの画面、または、選んだアプリのいちばん大きいウィンドウ。画像はメモリ上だけで扱う。
/// 権限（画面収録）が未確認なら、OS の許可の確認が出る（利用者の開始の操作の中だけで、最初の 1 枚を撮る）。
public struct ScreenSnapshotter: Sendable {
    public let selection: ScreenSelection
    /// 撮る画像の、長いほうの辺（これ以上は、撮る時に縮める）。
    private let maxEdge = 1280
    /// 診断ログ（数値だけ。`CaptureDiagnostics`）。ウィンドウ・画面の位置と大きさ、撮れた画像の大きさ。タイトルは、書かない。
    private let log: @Sendable (String) -> Void

    public init(selection: ScreenSelection, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.selection = selection
        self.log = log
    }

    private static func describe(_ rect: CGRect) -> String {
        String(format: "%.1fx%.1f@%.1f,%.1f", rect.width, rect.height, rect.origin.x, rect.origin.y)
    }

    public func snapshot() async throws -> CGImage {
        let content: SCShareableContent
        do {
            // 別のデスクトップ・フルスクリーンにあるウィンドウも、一覧に入れる（画面に出ているものを優先して選ぶ）。
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.permissionDenied(.screenRecording, Self.permissionText(error))
        }
        switch selection {
        case .off:
            throw CaptureError.failed("画面の取り込みが選ばれていません")
        case .display:
            guard let display = content.displays.first else { throw CaptureError.targetNotFound("画面が見つかりません") }
            log("display id=\(display.displayID) frame=\(Self.describe(display.frame)) size=\(display.width)x\(display.height) displays=\(content.displays.count)")
            do {
                let image = try await capture(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []), size: CGSize(width: display.width, height: display.height))
                log("captured display image=\(image.width)x\(image.height)")
                return image
            } catch {
                throw CaptureError.failed("画面を撮れません: \(Self.describe(error))")
            }
        case .app(let bundleID, let name):
            let processIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
            let candidates = content.windows.map {
                WindowCandidate(bundleID: $0.owningApplication?.bundleIdentifier, processID: $0.owningApplication?.processID ?? -1, layer: $0.windowLayer,
                                width: $0.frame.width, height: $0.frame.height, isOnScreen: $0.isOnScreen)
            }
            let ranked = WindowPicker.ranked(candidates, bundleID: bundleID, processIDs: processIDs)
            // そのアプリの、すべてのウィンドウ（id:レイヤー:大きさ@位置:画面に出ているか）。選ばれ方を、あとから確かめるため。
            let own = content.windows.indices.filter { candidates[$0].bundleID == bundleID || processIDs.contains(candidates[$0].processID) }
            let listing = own.prefix(16).map { index -> String in
                let window = content.windows[index]
                return "\(window.windowID):L\(window.windowLayer):\(Self.describe(window.frame)):\(window.isOnScreen ? "on" : "off")"
            }.joined(separator: " ")
            log("app=\(bundleID) windows=\(own.count) [\(listing)] ranked=\(ranked.map { String(content.windows[$0].windowID) }.joined(separator: ","))")
            guard !ranked.isEmpty else {
                throw CaptureError.targetNotFound("「\(name)」の撮れるウィンドウがありません（\(processIDs.isEmpty ? "起動していません" : "起動中")。通常のウィンドウ 0 件。最小化していないか、確認してください）")
            }
            // 先頭（画面に出ている、いちばん大きいもの）が撮れなくても、次の候補を試す（最大 5 件）。
            var lastError: Error?
            for index in ranked.prefix(5) {
                let window = content.windows[index]
                // フルスクリーンのウィンドウは、ウィンドウ単位でなく、**ディスプレイの合成結果から、そのアプリのウィンドウだけ**を切り出す。
                // ウィンドウ単位の撮影は、フルスクリーンの動画で、中身が、枠の 95% ほどの大きさで左下に寄り、上と右に空白が出た（実機の診断ログ）。
                // ディスプレイの合成結果（実際に見えている絵）なら、そのずれがない、と考える。そのアプリのウィンドウだけなので、他のアプリ・通知は写らない。
                if candidates[index].isOnScreen, let application = window.owningApplication,
                   let display = content.displays.first(where: { WindowPicker.fillsDisplay(window: window.frame, display: $0.frame) && $0.frame.intersects(window.frame) }) {
                    let source = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                    log("try display=\(display.displayID) +app=\(bundleID) window=\(window.windowID) sourceRect=\(Self.describe(source)) displayFrame=\(Self.describe(display.frame))")
                    do {
                        let image = try await capture(filter: SCContentFilter(display: display, including: [application], exceptingWindows: []), size: source.size, sourceRect: source)
                        log("captured display+app window=\(window.windowID) image=\(image.width)x\(image.height)")
                        return image
                    } catch {
                        log("failed display+app window=\(window.windowID) \(Self.describe(error))")
                        lastError = error
                    }
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                // 撮る範囲の大きさは、OS が教える `contentRect`（ウィンドウの枠と、見えている内容が違うとき、実際の内容の大きさ）。無ければ、枠の大きさ。
                let rect = filter.contentRect
                let size = rect.width > 0 && rect.height > 0 ? rect.size : window.frame.size
                log("try window=\(window.windowID) frame=\(Self.describe(window.frame)) contentRect=\(Self.describe(rect)) pointPixelScale=\(filter.pointPixelScale) basis=\(Self.describe(CGRect(origin: .zero, size: size)))")
                do {
                    let image = try await capture(filter: filter, size: size)
                    log("captured window=\(window.windowID) image=\(image.width)x\(image.height)")
                    return image
                } catch {
                    log("failed window=\(window.windowID) \(Self.describe(error))")
                    lastError = error
                }
            }
            let visible = ranked.filter { candidates[$0].isOnScreen }.count
            if visible == 0 {
                throw CaptureError.failed("「\(name)」のウィンドウが、いま見えているデスクトップにありません（別のデスクトップのフルスクリーン・最小化・隠れている、など）。見えていないウィンドウは、撮れません。そのウィンドウが見えるデスクトップへ移ると、撮れます（\(lastError.map(Self.describe) ?? "原因不明")）")
            }
            throw CaptureError.failed("「\(name)」のウィンドウを撮れません（候補 \(ranked.count) 件、うち画面に出ているもの \(visible) 件）: \(lastError.map(Self.describe) ?? "原因不明")")
        }
    }

    private func capture(filter: SCContentFilter, size: CGSize, sourceRect: CGRect? = nil) async throws -> CGImage {
        let scale = min(1, Double(maxEdge) / Double(max(size.width, size.height)))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((size.width * scale).rounded()))
        configuration.height = max(1, Int((size.height * scale).rounded()))
        configuration.showsCursor = false
        if let sourceRect { configuration.sourceRect = sourceRect }
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// 原因を切り分けられるよう、OS のエラーの種類と番号も付ける（例：`com.apple.ScreenCaptureKit.SCStreamErrorDomain -3802`）。
    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(error.localizedDescription)（\(nsError.domain) \(nsError.code)）"
    }

    private static func permissionText(_ error: Error) -> String {
        "画面収録が許可されていません。システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオの録音 で、meeting-analyzer をオンにしてください。\n\nすでにオンでも、アプリを入れ直すと、許可が無効になることがあります（一度「−」で削除して、もう一度開始してください）。\n\n詳細: \(error.localizedDescription)"
    }
}
