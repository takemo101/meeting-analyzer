import Foundation
import Testing
@testable import MeetingAnalyzerKit

/// ソケットのパスは 103 バイトまで。一時ディレクトリの深い場所は使えないので、短い場所に作る。
func shortSocketDirectory() -> String { "/tmp/ma-" + UUID().uuidString.prefix(8).lowercased() }

private func started(_ id: String = "s1") -> TranscriptEvent { .started(sessionId: id, title: "t", startedAt: "2026-10-22T00:00:00Z", sources: ["you"]) }
private func captions(_ sequence: Int, session id: String = "s1", _ text: String = "こんにちは") -> TranscriptEvent {
    .captions(sessionId: id, sequence: sequence, updates: [CaptionUpdate(id: "you-1", version: 1, speaker: "本人", source: "you", text: text, timestamp: 1_800_000_000_000, isFinal: true)])
}
private func ended(_ id: String = "s1") -> TranscriptEvent {
    .ended(sessionId: id, title: "t", reason: "user", startedAt: "2026-10-22T00:00:00Z", endedAt: "2026-10-22T00:01:00Z", durationSeconds: 60, batches: 1, utterances: 1, transcriptPath: "/x/transcript.md")
}

/// 受け手として流れを読み、溜める。
final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HubClientEvent] = []
    private var task: Task<Void, Never>?

    init(_ client: HubClient) {
        task = Task { [self] in
            for await event in client.events() { lock.withLock { storage.append(event) } }
        }
    }

    var events: [HubClientEvent] { lock.withLock { storage } }
    var messages: [HubMessage] { events.compactMap { if case .message(let m) = $0 { return m } else { return nil } } }
    var envelopes: [HubEnvelope] { messages.compactMap { if case .event(let e) = $0 { return e } else { return nil } } }
    func close() { task?.cancel() }
}

func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Suite("出来事の JSON の形（エージェントが読む）")
struct TranscriptEventTests {
    private func object(_ event: TranscriptEvent) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
    }

    @Test("字幕のバッチは、kind・セッション・連番・発話の更新を持つ")
    func captionsShape() throws {
        let json = try object(captions(3, session: "abc", "来週のリリース"))
        #expect(json["kind"] as? String == "captions" && json["sessionId"] as? String == "abc" && json["sequence"] as? Int == 3)
        let update = try #require((json["updates"] as? [[String: Any]])?.first)
        #expect(update["id"] as? String == "you-1" && update["version"] as? Int == 1)
        #expect(update["speaker"] as? String == "本人" && update["source"] as? String == "you")
        #expect(update["text"] as? String == "来週のリリース" && update["isFinal"] as? Bool == true)
        #expect(update["timestamp"] as? Double == 1_800_000_000_000)
    }

    @Test("終了は、理由・長さ・件数・記録のパスを持つ。パスが無ければ、キー自体を出さない")
    func endedShape() throws {
        let json = try object(ended())
        #expect(json["kind"] as? String == "ended" && json["reason"] as? String == "user" && json["durationSeconds"] as? Int == 60)
        #expect(json["transcriptPath"] as? String == "/x/transcript.md")
        let none = try object(.ended(sessionId: "s", title: "t", reason: "appQuit", startedAt: "a", endedAt: "b", durationSeconds: 0, batches: 0, utterances: 0, transcriptPath: nil))
        #expect(none["transcriptPath"] == nil)
    }

    @Test("3 種類とも、JSON を経て元に戻る。知らない kind は断る")
    func roundTrip() throws {
        for event in [started(), captions(1), ended()] where true {
            #expect(try JSONDecoder().decode(TranscriptEvent.self, from: JSONEncoder().encode(event)) == event)
        }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TranscriptEvent.self, from: Data(#"{"kind":"other","sessionId":"s"}"#.utf8)) }
        #expect(HubWire.decode(Data("not json".utf8)) == nil)
    }
}

@Suite("HubServer / HubClient: エージェントへ渡す窓口（実際の Unix ドメインソケット）")
struct HubTests {
    private func makeServer(logLimit: Int = 2000) throws -> (HubServer, String) {
        let directory = shortSocketDirectory()
        let server = HubServer(socketPath: directory + "/hub.sock", logLimit: logLimit)
        try server.start()
        return (server, directory)
    }

    @Test("後から接続した受け手は、hello → これまでの出来事 → sync → 新しい出来事 の順で受け取る")
    func backlogThenLive() async throws {
        let (server, directory) = try makeServer()
        defer { server.stop(); try? FileManager.default.removeItem(atPath: directory) }
        server.publish(started())
        server.publish(captions(1))

        let inbox = Inbox(HubClient(socketPath: server.socketPath, retryInterval: 0.05))
        defer { inbox.close() }
        #expect(await waitUntil { inbox.messages.contains(.sync) })
        server.publish(captions(2))
        #expect(await waitUntil { inbox.envelopes.count == 3 })

        let messages = inbox.messages
        #expect(messages.first == .hello(hubId: server.hubId))
        #expect(messages.firstIndex(of: .sync) == 3, "hello、出来事 2 件、そして sync")
        #expect(inbox.envelopes.map(\.id) == [1, 2, 3], "通し番号は、接続の前後で続く")
        #expect(inbox.envelopes.map(\.event.kind) == ["started", "captions", "captions"])
    }

    @Test("新しいセッションが始まると、前のセッションの出来事は、あとから接続する受け手へ渡さない")
    func newSessionDropsOldLog() async throws {
        let (server, directory) = try makeServer()
        defer { server.stop(); try? FileManager.default.removeItem(atPath: directory) }
        server.publish(started("old")); server.publish(captions(1, session: "old")); server.publish(ended("old"))
        server.publish(started("new"))

        let inbox = Inbox(HubClient(socketPath: server.socketPath, retryInterval: 0.05))
        defer { inbox.close() }
        #expect(await waitUntil { inbox.messages.contains(.sync) })
        #expect(inbox.envelopes.map(\.event.sessionId) == ["new"])
        #expect(inbox.envelopes.first?.id == 4, "通し番号は、ハブの起動中、減らない")
    }

    @Test("保持する出来事は、上限まで（古いものから捨てる）")
    func logLimit() async throws {
        let (server, directory) = try makeServer(logLimit: 3)
        defer { server.stop(); try? FileManager.default.removeItem(atPath: directory) }
        server.publish(started())
        for sequence in 1...5 { server.publish(captions(sequence)) }
        let inbox = Inbox(HubClient(socketPath: server.socketPath, retryInterval: 0.05))
        defer { inbox.close() }
        #expect(await waitUntil { inbox.messages.contains(.sync) })
        #expect(inbox.envelopes.map(\.id) == [4, 5, 6])
    }

    @Test("複数の受け手に同じ出来事が届く。つながっている数が変わると知らせ、切れたら減る")
    func fanOutAndClientCount() async throws {
        let (server, directory) = try makeServer()
        defer { server.stop(); try? FileManager.default.removeItem(atPath: directory) }
        let counts = CountLog()
        server.setClientCountHandler { counts.add($0) }

        let first = Inbox(HubClient(socketPath: server.socketPath, retryInterval: 0.05))
        let second = Inbox(HubClient(socketPath: server.socketPath, retryInterval: 0.05))
        #expect(await waitUntil { server.clientCount == 2 })
        server.publish(started()); server.publish(captions(1))
        #expect(await waitUntil { first.envelopes.count == 2 && second.envelopes.count == 2 })

        first.close()
        #expect(await waitUntil { server.clientCount == 1 })
        second.close()
        #expect(await waitUntil { server.clientCount == 0 })
        #expect(counts.values.contains(2) && counts.values.last == 0)
    }

    @Test("つないですぐ切る受け手がいても、ハブ（アプリ）は落ちず、ほかの受け手へ届け続ける")
    func abruptDisconnects() async throws {
        let (server, directory) = try makeServer()
        defer { server.stop(); try? FileManager.default.removeItem(atPath: directory) }
        server.publish(started())
        for sequence in 1...60 {
            #expect(HubServer.canConnect(path: server.socketPath))
            server.publish(captions(sequence))
        }
        let inbox = Inbox(HubClient(socketPath: server.socketPath, retryInterval: 0.05))
        defer { inbox.close() }
        #expect(await waitUntil { inbox.messages.contains(.sync) })
        server.publish(captions(61))
        #expect(await waitUntil { inbox.envelopes.last?.id == 62 })
        #expect(await waitUntil { server.clientCount == 1 }, "切れた受け手は、数えない")
    }

    @Test("つないだまま何も届かない受け手が切れたときも、数えなくなる（書き込みの失敗を待たずに、切断を見つける）")
    func idleDisconnectIsDetected() async throws {
        let (server, directory) = try makeServer()
        defer { server.stop(); try? FileManager.default.removeItem(atPath: directory) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = HubServer.address(path: server.socketPath)
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        #expect(connected == 0)
        #expect(await waitUntil { server.clientCount == 1 })
        // 何も公開しない（書き込みが起きない）まま、受け手が切れる。
        close(fd)
        #expect(await waitUntil { server.clientCount == 0 })
    }

    @Test("ソケットは本人だけ（ファイル 0600・ディレクトリ 0700）。止めると、ファイルを消す")
    func permissionsAndCleanup() throws {
        let (server, directory) = try makeServer()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let socket = try FileManager.default.attributesOfItem(atPath: server.socketPath)
        #expect((socket[.posixPermissions] as? Int) == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: directory)[.posixPermissions] as? Int) == 0o700)
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: server.socketPath))
    }

    @Test("別のハブが生きていれば断り、残骸のファイルだけなら置き換える。長すぎるパスは断る")
    func startConflicts() throws {
        let (live, directory) = try makeServer()
        defer { live.stop(); try? FileManager.default.removeItem(atPath: directory) }
        #expect(throws: HubError.alreadyRunning(live.socketPath)) { try HubServer(socketPath: live.socketPath).start() }
        live.stop()

        FileManager.default.createFile(atPath: live.socketPath, contents: Data())
        let replacement = HubServer(socketPath: live.socketPath)
        try replacement.start()
        replacement.stop()

        let long = "/tmp/" + String(repeating: "a", count: 120) + "/hub.sock"
        #expect(throws: HubError.pathTooLong(long)) { try HubServer(socketPath: long).start() }
    }

    @Test("受け手は、ハブが後から起動しても、つながる。ハブが起動し直すと、識別子が変わる")
    func clientReconnects() async throws {
        let directory = shortSocketDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/hub.sock"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let inbox = Inbox(HubClient(socketPath: path, retryInterval: 0.05))
        defer { inbox.close() }
        #expect(await waitUntil { inbox.events.contains(.disconnected) }, "ハブが無い間は、切れていると知らせる")

        let first = HubServer(socketPath: path)
        try first.start()
        #expect(await waitUntil { inbox.messages.contains(.hello(hubId: first.hubId)) })
        first.stop()
        #expect(await waitUntil { inbox.events.suffix(1) == [.disconnected] })

        let second = HubServer(socketPath: path)
        try second.start()
        defer { second.stop() }
        #expect(await waitUntil { inbox.messages.contains(.hello(hubId: second.hubId)) })
        #expect(first.hubId != second.hubId)
    }
}

final class CountLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []
    func add(_ value: Int) { lock.withLock { storage.append(value) } }
    var values: [Int] { lock.withLock { storage } }
}
