import Foundation

public enum ScreenshotStoreError: Error, Sendable, Equatable {
    case writeFailed
}

/// 画面の JPEG の保存先（SPEC §3.5）。**記録のフォルダの中**：`<root>/sessions/<sessionId>/screens/shot-NNNN.jpg`
/// （`transcript.md` が、相対パス `screens/shot-NNNN.jpg` で参照する）。ディレクトリ 0700・ファイル 0600。
/// 枚数の上限は無い（長い会議でも、最後のほうだけにならない）。消すのは、記録と同じ寿命で、フォルダごと（`RecordRetention`）。
public struct ScreenshotStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    func directory(sessionId: UUID) -> URL {
        root.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionId.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("screens", isDirectory: true)
    }

    /// `transcript.md` から見た、`index` 番目（1 から）の画像の相対パス。
    static func relativePath(index: Int) -> String { String(format: "screens/shot-%04d.jpg", index) }

    /// `index` 番目（1 から）の画像を書いて、その絶対パスを返す。
    public func save(_ jpeg: Data, sessionId: UUID, index: Int) -> Result<URL, ScreenshotStoreError> {
        let directory = directory(sessionId: sessionId)
        let file = directory.appendingPathComponent(String(format: "shot-%04d.jpg", index))
        do {
            // 上の階層（`sessions/<id>/`）も、同じ権限で作る。
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.deletingLastPathComponent().path)
            try jpeg.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            return .failure(.writeFailed)
        }
        return .success(file)
    }

    /// そのセッションの画像を、すべて消す（会議が始まらなかったとき）。記録（`transcript.md`）には、触れない。中が空になった記録のフォルダは、消す。
    public func deleteAll(sessionId: UUID) {
        let screens = directory(sessionId: sessionId)
        try? FileManager.default.removeItem(at: screens)
        let session = screens.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: session.path))?.isEmpty == true { try? FileManager.default.removeItem(at: session) }
    }
}
