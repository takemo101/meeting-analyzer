import Foundation

public enum ScreenshotStoreError: Error, Sendable, Equatable {
    case writeFailed
}

/// エージェントが読む、画面の JPEG の保存先（SPEC §3.5）。`<root>/screens/<sessionId>/shot-NNNN.jpg`。ディレクトリ 0700・ファイル 0600。
/// 最新の `keep` 枚だけを残し、セッションの終了で、すべて消す。
public struct ScreenshotStore: Sendable {
    public let root: URL
    public let keep: Int

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

    /// そのセッションの画像を、すべて消す（セッションの終了）。
    public func deleteAll(sessionId: UUID) {
        try? FileManager.default.removeItem(at: directory(sessionId: sessionId))
    }

    private func prune(directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let shots = names.filter { $0.hasPrefix("shot-") }.sorted()
        for name in shots.dropLast(keep) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
    }
}
