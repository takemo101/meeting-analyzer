import Foundation

/// このアプリの置き場所。
public enum RuntimePaths {
    /// このアプリのデータ（記録）の置き場所。`MEETING_ANALYZER_DATA_DIR` で変更できる（検証用）。
    public static func dataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let custom = environment["MEETING_ANALYZER_DATA_DIR"], !custom.isEmpty { return URL(fileURLWithPath: custom, isDirectory: true) }
        return home.appendingPathComponent("Library/Application Support/MeetingAnalyzer", isDirectory: true)
    }

    /// ハブ（エージェントへ渡す窓口）の Unix ドメインソケット。既定は `<データの置き場所>/hub.sock`。
    /// `MEETING_ANALYZER_SOCKET` で変更できる（検証用。ソケットのパスは 103 バイトまで）。
    public static func hubSocket(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        if let custom = environment["MEETING_ANALYZER_SOCKET"], !custom.isEmpty { return custom }
        return dataDirectory(environment: environment, home: home).appendingPathComponent("hub.sock").path
    }
}

public enum SessionStoreError: Error, Sendable, Equatable {
    case writeFailed
}

/// 会議の記録（文字起こし）を、利用者だけが読める形で書く（ディレクトリ 0700・ファイル 0600）。
public struct SessionStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `<root>/sessions/<sessionId>/transcript.md` の場所。
    public func transcriptURL(sessionId: UUID) -> URL {
        root.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionId.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("transcript.md")
    }

    /// `<root>/sessions/<sessionId>/transcript.md` を書いて、その絶対パスを返す。
    public func writeTranscript(_ markdown: String, sessionId: UUID) -> Result<URL, SessionStoreError> {
        let file = transcriptURL(sessionId: sessionId)
        let directory = file.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(markdown.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return .success(file)
        } catch {
            return .failure(.writeFailed)
        }
    }
}
