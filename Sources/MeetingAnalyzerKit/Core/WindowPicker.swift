/// 画面の取り込みで撮るウィンドウの選び方。ScreenCaptureKit から分けた、純粋な規則（試験できる形）。
public struct WindowCandidate: Sendable, Equatable {
    public let bundleID: String?
    public let processID: Int32
    public let layer: Int
    public let width: Double
    public let height: Double
    public let isOnScreen: Bool

    public init(bundleID: String?, processID: Int32, layer: Int, width: Double, height: Double, isOnScreen: Bool) {
        self.bundleID = bundleID
        self.processID = processID
        self.layer = layer
        self.width = width
        self.height = height
        self.isOnScreen = isOnScreen
    }
}

public enum WindowPicker {
    /// 選んだアプリの、通常のウィンドウ（レイヤー 0・小さすぎない）。アプリは、bundle ID か、起動中のプロセス ID のどちらかで照合する
    /// （bundle ID が一致しない子プロセスのウィンドウも、同じアプリとして扱う）。
    public static func appWindows(_ windows: [WindowCandidate], bundleID: String, processIDs: Set<Int32>) -> [WindowCandidate] {
        windows.filter { ($0.bundleID == bundleID || processIDs.contains($0.processID)) && $0.layer == 0 && $0.width > 50 && $0.height > 50 }
    }

    /// 撮る候補の位置（`windows` の添字）を、試す順に並べる。画面に出ているものが先（大きい順）、そのあとに、別のデスクトップ・フルスクリーン・最小化のもの（大きい順）。
    /// 先頭が撮れなくても、次を試せるように、全部を返す。
    public static func ranked(_ windows: [WindowCandidate], bundleID: String, processIDs: Set<Int32>) -> [Int] {
        let matching = windows.indices.filter { appWindows([windows[$0]], bundleID: bundleID, processIDs: processIDs).count == 1 }
        let area = { (index: Int) in windows[index].width * windows[index].height }
        let order = { (a: Int, b: Int) in area(a) > area(b) }
        return matching.filter { windows[$0].isOnScreen }.sorted(by: order) + matching.filter { !windows[$0].isOnScreen }.sorted(by: order)
    }
}
