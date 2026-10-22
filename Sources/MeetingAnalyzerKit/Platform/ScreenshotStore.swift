import Foundation

public enum ScreenshotStoreError: Error, Sendable, Equatable {
    case writeFailed
}

/// エージェントが読む、画面の JPEG の保存先（SPEC §3.5）。`<root>/screens/<sessionId>/shot-NNNN.jpg`。ディレクトリ 0700・ファイル 0600。
/// 会議中は、最新の `keep` 枚だけを残す。会議が終わったあとも、**`retentionDays` 日間は残し**（エージェントが、あとから開ける）、過ぎたら消す。
public struct ScreenshotStore: Sendable {
    public let root: URL
    public let keep: Int
    /// 会議が終わったあと、画像を残す日数（SPEC §3.5）。
    public static let retentionDays = 7

    public init(root: URL, keep: Int = 30) {
        self.root = root
        self.keep = keep
    }

    func directory(sessionId: UUID) -> URL {
        root.appendingPathComponent("screens", isDirectory: true).appendingPathComponent(sessionId.uuidString.lowercased(), isDirectory: true)
    }

    /// `index` 番目（1 から）の画像を書いて、その絶対パスを返す。古いものを、上限まで減らす。
    public func save(_ jpeg: Data, sessionId: UUID, index: Int) -> Result<URL, ScreenshotStoreError> {
        let directory = directory(sessionId: sessionId)
        let file = directory.appendingPathComponent(String(format: "shot-%04d.jpg", index))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try jpeg.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            return .failure(.writeFailed)
        }
        prune(directory: directory)
        return .success(file)
    }

    /// 最後に画像を書いてから `days` 日以上たったセッションの画像を、ディレクトリごと消す。`except`：実行中のセッション（消さない）。消した数を返す。
    /// 対象は、`screens/` の下の、セッション ID（UUID）の名前のディレクトリだけ。
    @discardableResult
    public func deleteExpired(now: Date = Date(), olderThanDays days: Int = ScreenshotStore.retentionDays, except: UUID? = nil) -> Int {
        let screens = root.appendingPathComponent("screens", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: screens.path) else { return 0 }
        let limit = TimeInterval(days) * 86_400
        var removed = 0
        for name in names {
            guard let id = UUID(uuidString: name), id != except else { continue }
            let directory = screens.appendingPathComponent(name, isDirectory: true)
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: directory.path))?[.modificationDate] as? Date, now.timeIntervalSince(modified) >= limit else { continue }
            if (try? FileManager.default.removeItem(at: directory)) != nil { removed += 1 }
        }
        return removed
    }

    /// そのセッションの画像を、すべて消す（会議が始まらなかったとき）。
    public func deleteAll(sessionId: UUID) {
        try? FileManager.default.removeItem(at: directory(sessionId: sessionId))
    }

    private func prune(directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let shots = names.filter { $0.hasPrefix("shot-") }.sorted()
        for name in shots.dropLast(keep) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
    }
}
