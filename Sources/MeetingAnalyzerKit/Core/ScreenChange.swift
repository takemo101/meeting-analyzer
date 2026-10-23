import Foundation

/// 画面の取り込み先の選択（SPEC §3.5）。
public enum ScreenSelection: Sendable, Hashable {
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
        case .app(_, let name): return name
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

/// 画面の画像を、いつ保存してよいかの規則（SPEC §3.5）：前の保存から `minGap` 秒たち、かつ、前に保存した画面から変化があるとき。
/// 時計を持たず、`now`（セッションの開始からの秒数）を引数で受ける。保存した枚数も数える（画像の通し番号）。
public struct ScreenshotGate: Sendable, Equatable {
    public let minGap: TimeInterval
    private var lastSignature: ScreenSignature?
    private var lastSavedAt: TimeInterval?
    public private(set) var savedCount = 0

    public init(minGap: TimeInterval) {
        self.minGap = minGap
    }

    /// 間隔の条件を満たしているか（保存したことが無い、または、前の保存から `minGap` 秒以上）。画像の署名を作る前に、確かめる（間隔の中では、計算しない）。
    public func isOpen(at now: TimeInterval) -> Bool {
        lastSavedAt.map { now - $0 >= minGap } ?? true
    }

    /// 前に保存した画面から、変化があるか（保存したことが無ければ、常にあり）。
    public func hasChanged(_ signature: ScreenSignature) -> Bool {
        ScreenChange.hasChanged(from: lastSignature, to: signature)
    }

    /// 次に保存する画像の通し番号（1 から）。
    public var nextIndex: Int { savedCount + 1 }

    public mutating func didSave(_ signature: ScreenSignature, at now: TimeInterval) {
        savedCount += 1
        lastSignature = signature
        lastSavedAt = now
    }
}


/// 保存してよい状態の画面か（SPEC §3.5）：ウィンドウの大きさが変わっている最中（フルスクリーンへの切り替えなど）の画像を、保存しない。
/// 前回と画像の大きさが違うときは、**待つ**（次の確認まで）。待つのは、続けて `maxHolds` 回まで（そのあとは、保存する。大きさが変わり続ける窓でも、
/// いつまでも保存しなくならないように）。
public struct ScreenStability: Sendable, Equatable {
    public static let maxHolds = 2
    private var lastSize: [Int]?
    private var holds = 0

    public init() {}

    /// この画像を、保存してよいか。待つときは false（回数を数える）。
    public mutating func isSettled(width: Int, height: Int) -> Bool {
        let size = [width, height]
        let resized = lastSize.map { $0 != size } ?? false
        lastSize = size
        if resized && holds < Self.maxHolds {
            holds += 1
            return false
        }
        holds = 0
        return true
    }
}
