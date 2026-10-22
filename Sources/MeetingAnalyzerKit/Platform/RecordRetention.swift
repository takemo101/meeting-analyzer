import Foundation

/// 記録（`sessions/<sessionId>/`：`transcript.md` と `screens/`）を残す日数の、利用者の設定（SPEC §3.8）。
/// `nil` は、消さない。設定は、アプリの設定（`UserDefaults`）に保存する。
public enum RecordRetentionSetting {
    public static let defaultDays = 7
    /// メニューの選択肢（日数。`nil` は、消さない）。
    public static let choices: [Int?] = [1, 3, 7, 30, 90, nil]
    static let key = "recordRetentionDays"

    /// 保存した設定。無ければ既定（7 日）。0 は「消さない」。選択肢に無い値（壊れた設定）は、既定に戻す。
    public static func load(_ defaults: UserDefaults = .standard) -> Int? {
        guard defaults.object(forKey: key) != nil else { return defaultDays }
        let stored = defaults.integer(forKey: key)
        if stored == 0 { return nil }
        return choices.contains(stored) ? stored : defaultDays
    }

    public static func save(_ days: Int?, _ defaults: UserDefaults = .standard) {
        defaults.set(days ?? 0, forKey: key)
    }

    public static func title(_ days: Int?) -> String {
        days.map { "\($0) 日" } ?? "消さない"
    }
}

/// 期限を過ぎた記録を、フォルダごと消す（SPEC §3.8）。**文字起こしと画像は、同じ寿命**。
/// 対象は、`sessions/` の下の、セッション ID（UUID）の名前のディレクトリと、以前の版が画像だけを置いていた `screens/<UUID>/`。
public struct RecordRetention: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// 最後に書いてから `days` 日以上たった記録を、ディレクトリごと消す。`except`：実行中のセッション（消さない）。消した数を返す。
    /// 「最後に書いた時刻」は、記録のディレクトリと、その中の `screens/` の、新しいほう（記録の書き換え・画像の追加で進む）。
    @discardableResult
    public func deleteExpired(now: Date = Date(), olderThanDays days: Int, except: UUID? = nil) -> Int {
        let limit = TimeInterval(days) * 86_400
        var removed = 0
        for (parent, nested) in [("sessions", true), ("screens", false)] {
            let directory = root.appendingPathComponent(parent, isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names {
                guard let id = UUID(uuidString: name), id != except else { continue }
                let target = directory.appendingPathComponent(name, isDirectory: true)
                guard let written = lastWritten(target, includingScreens: nested), now.timeIntervalSince(written) >= limit else { continue }
                if (try? FileManager.default.removeItem(at: target)) != nil { removed += 1 }
            }
        }
        return removed
    }

    private func lastWritten(_ directory: URL, includingScreens: Bool) -> Date? {
        func modified(_ url: URL) -> Date? { (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }
        let own = modified(directory)
        guard includingScreens, let screens = modified(directory.appendingPathComponent("screens", isDirectory: true)) else { return own }
        return own.map { max($0, screens) } ?? screens
    }
}
