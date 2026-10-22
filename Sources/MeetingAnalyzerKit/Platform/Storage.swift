import Foundation

/// ブリッジのトークンの置き場所。live-support のランタイムディレクトリ（既定 `~/.live-support`、`LIVE_SUPPORT_RUNTIME_DIR` で変更）。
public enum RuntimePaths {
    public static func liveSupportDirectory(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let custom = environment["LIVE_SUPPORT_RUNTIME_DIR"], !custom.isEmpty { return URL(fileURLWithPath: custom, isDirectory: true) }
        return home.appendingPathComponent(".live-support", isDirectory: true)
    }

    /// このアプリのデータ（会議の記録）の置き場所。`MEETING_ANALYZER_DATA_DIR` で変更できる（検証用）。
    public static func dataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let custom = environment["MEETING_ANALYZER_DATA_DIR"], !custom.isEmpty { return URL(fileURLWithPath: custom, isDirectory: true) }
        return home.appendingPathComponent("Library/Application Support/MeetingAnalyzer", isDirectory: true)
    }
}

public enum TokenError: Error, Sendable, Equatable {
    case missing
    case unreadable
}

public enum TokenStore {
    /// `<dir>/token` の中身（前後の空白を除く）。トークンはどこへも保存・表示しない。
    public static func read(directory: URL) -> Result<String, TokenError> {
        let file = directory.appendingPathComponent("token")
        guard FileManager.default.fileExists(atPath: file.path) else { return .failure(.missing) }
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else { return .failure(.unreadable) }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? .failure(.unreadable) : .success(token)
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

    /// `<root>/sessions/<sessionId>/transcript.md` を書いて、その絶対パスを返す。
    public func writeTranscript(_ markdown: String, sessionId: UUID) -> Result<URL, SessionStoreError> {
        let directory = root.appendingPathComponent("sessions", isDirectory: true).appendingPathComponent(sessionId.uuidString.lowercased(), isDirectory: true)
        let file = directory.appendingPathComponent("transcript.md")
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
