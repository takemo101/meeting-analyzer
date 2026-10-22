import Foundation
import Testing
@testable import MeetingAnalyzerKit

private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ma-platform-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("RuntimePaths / SessionStore")
struct PlatformTests {
    @Test("置き場所は、環境変数が優先で、なければ既定の場所。ソケットは、データの置き場所の中が既定")
    func paths() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        #expect(RuntimePaths.dataDirectory(environment: [:], home: home).path == "/Users/someone/Library/Application Support/MeetingAnalyzer")
        #expect(RuntimePaths.dataDirectory(environment: ["MEETING_ANALYZER_DATA_DIR": "/tmp/d"], home: home).path == "/tmp/d")
        #expect(RuntimePaths.dataDirectory(environment: ["MEETING_ANALYZER_DATA_DIR": ""], home: home).path == "/Users/someone/Library/Application Support/MeetingAnalyzer", "空は無視する")
        #expect(RuntimePaths.hubSocket(environment: [:], home: home) == "/Users/someone/Library/Application Support/MeetingAnalyzer/hub.sock")
        #expect(RuntimePaths.hubSocket(environment: ["MEETING_ANALYZER_DATA_DIR": "/tmp/d"], home: home) == "/tmp/d/hub.sock")
        #expect(RuntimePaths.hubSocket(environment: ["MEETING_ANALYZER_DATA_DIR": "/tmp/d", "MEETING_ANALYZER_SOCKET": "/tmp/s.sock"], home: home) == "/tmp/s.sock")
    }

    @Test("記録は、セッションごとのディレクトリに、利用者だけが読める権限で書く")
    func writeTranscript() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let file = try SessionStore(root: root).writeTranscript("# 記録\n", sessionId: id).get()
        #expect(file.path == root.appendingPathComponent("sessions/\(id.uuidString.lowercased())/transcript.md").path)
        #expect(try String(contentsOf: file, encoding: .utf8) == "# 記録\n")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int) == 0o700)
    }

    @Test("書けない場所へは、失敗として返す（クラッシュしない）")
    func writeFailure() {
        let result = SessionStore(root: URL(fileURLWithPath: "/dev/null/nope")).writeTranscript("x", sessionId: UUID())
        #expect(throws: SessionStoreError.writeFailed) { try result.get() }
    }
}

@Suite("AppInfo")
struct AppInfoTests {
    @Test("コード上の版は、Info.plist の版と同じ")
    func versionMatchesBundle() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plist)
        let object = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(object["CFBundleShortVersionString"] as? String == AppInfo.version)
        #expect(object["CFBundleVersion"] as? String == AppInfo.version)
    }
}
