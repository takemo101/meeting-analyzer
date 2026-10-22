import Foundation

/// 画面の取り込みの診断ログ（`<データの置き場所>/logs/screen-capture.log`。ディレクトリ 0700・ファイル 0600）。
/// **数値だけ**（ウィンドウ・画面の位置と大きさ、撮れた画像の大きさ、切り落としの結果）。画像・ウィンドウのタイトル・字幕の本文は、書かない（SPEC §3.10）。
/// 前の行と同じ内容は、続けて書かない（変化があったときだけ残る）。大きくなりすぎたら、古い行から捨てる。
public final class CaptureDiagnostics: @unchecked Sendable {
    public static let maxBytes = 200_000

    public let file: URL
    private let lock = NSLock()
    private var lastMessage: String?
    private let clock: @Sendable () -> Date

    public init(root: URL, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.file = root.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("screen-capture.log")
        self.clock = clock
    }

    /// 1 行を足す。書けなくても、取り込みは止めない（診断は、副次）。
    @Sendable
    public func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard message != lastMessage else { return }
        lastMessage = message
        let directory = file.deletingLastPathComponent()
        let line = ISO8601DateFormatter().string(from: clock()) + " " + message.replacingOccurrences(of: "\n", with: " ") + "\n"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: file.path) {
                guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            if let size = try? handle.offset(), size > UInt64(Self.maxBytes) { try? trim() }
        } catch {
            return
        }
    }

    /// 後ろ半分だけを残す（行の途中から始まらないよう、最初の改行のあとから）。
    private func trim() throws {
        let data = try Data(contentsOf: file)
        let keep = data.suffix(Self.maxBytes / 2)
        let start = keep.firstIndex(of: 0x0A).map { keep.index(after: $0) } ?? keep.startIndex
        try Data(keep[start...]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
