import Foundation

/// 画面の取り込み先の選択（SPEC §3.5）。
public enum ScreenSelection: Sendable, Equatable {
    /// 画面を撮らない（既定）。
    case off
    /// メインの画面。
    case display
    /// 選んだアプリの、いちばん大きいウィンドウ。
    case app(bundleID: String, name: String)

    public var title: String {
        switch self {
        case .off: return "オフ"
        case .display: return "画面全体"
        case .app(_, let name): return "\(name) のウィンドウ"
        }
    }
}

/// 画面の「署名」：画面を、小さな格子に縮めた、明るさの並び。画像の比較を、画像を持たずに行うための要約。
public struct ScreenSignature: Sendable, Equatable {
    public static let columns = 48
    public static let rows = 27

    /// `columns × rows` 個の明るさ（0〜255）。行の順。
    public let cells: [UInt8]

    public init(cells: [UInt8]) {
        precondition(cells.count == Self.columns * Self.rows, "格子の大きさが違う")
        self.cells = cells
    }
}

/// 前に送った画面から、変化があったかの規則（SPEC §3.5）。純粋な規則で、画面にも OS にも依存しない。
public enum ScreenChange {
    /// 明るさの差がこの値以上の格子を、「変わった」と数える（小さな揺れ・圧縮の誤差を除く）。
    public static let cellThreshold = 24
    /// 変わった格子が、この数以上なら、変化とみなす。全体の約 0.2%（動画の一部・ポップアップのような、画面の一部の変化も拾い、時計の秒のような、ごく小さな変化は除く）。
    public static let minimumChangedCells = 3

    /// `previous` が無い（最初）なら、常に変化あり。
    public static func hasChanged(from previous: ScreenSignature?, to current: ScreenSignature) -> Bool {
        guard let previous else { return true }
        var changed = 0
        for index in current.cells.indices where abs(Int(current.cells[index]) - Int(previous.cells[index])) >= cellThreshold {
            changed += 1
            if changed >= minimumChangedCells { return true }
        }
        return false
    }
}
