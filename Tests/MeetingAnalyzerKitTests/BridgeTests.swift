import Foundation
import Testing
@testable import MeetingAnalyzerKit

/// URLSession を、ネットワークなしで差し替える。
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var requests: [(request: URLRequest, body: Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        } else if let data = request.httpBody { body = data }
        Self.requests.append((request, body))
        do {
            let (status, data) = try Self.handler?(request) ?? (200, Data())
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private let token = String(repeating: "t", count: 43)

@Suite("BridgeEndpoint: 送り先は、ローカルのブリッジだけ", .serialized)
struct BridgeEndpointTests {
    @Test("http の 127.0.0.1 / localhost だけを受け付ける")
    func loopbackOnly() throws {
        #expect((try? BridgeEndpoint.parse(url: "http://127.0.0.1:43821", token: token).get()) != nil)
        #expect((try? BridgeEndpoint.parse(url: "http://localhost:43821/", token: token).get()) != nil)
        for bad in ["https://127.0.0.1:43821", "http://example.com", "http://192.168.0.5:43821", "http://127.0.0.1.evil.example", "http://user:pw@127.0.0.1:1", "http://127.0.0.1:1/captions", "http://127.0.0.1:1?x=1", "ftp://127.0.0.1", "not a url"] {
            #expect(throws: BridgeEndpoint.ParseError.notLoopbackHTTP, "\(bad)") { try BridgeEndpoint.parse(url: bad, token: token).get() }
        }
    }

    @Test("トークンは 32 文字以上で、空白を含まない")
    func tokenShape() {
        #expect(throws: BridgeEndpoint.ParseError.shortToken) { try BridgeEndpoint.parse(url: "http://127.0.0.1:1", token: "short").get() }
        #expect(throws: BridgeEndpoint.ParseError.shortToken) { try BridgeEndpoint.parse(url: "http://127.0.0.1:1", token: String(repeating: "a", count: 20) + " " + String(repeating: "b", count: 20)).get() }
    }
}

@Suite("Events: ブリッジへ送る JSON の形", .serialized)
struct EventsTests {
    private let sessionId = UUID(uuidString: "6F0E5C2A-1B3D-4E7F-8A9B-0C1D2E3F4A5B")!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: BridgeClient.encoder.encode(value)) as? [String: Any])
    }

    @Test("字幕のバッチは、live-support の /captions と同じキーと型")
    func captionBatchShape() throws {
        let batch = CaptionBatch.make(
            sessionId: sessionId, sequence: 3, meetingId: "定例",
            utterances: [Utterance(id: 2, speaker: .others, text: "テスト環境はいつですか", isFinal: false, startedAt: 12.5, version: 4)], sessionStart: start
        )
        let json = try object(batch)
        #expect(Set(json.keys) == ["sessionId", "sequence", "meetingId", "platform", "updates"])
        #expect(json["sessionId"] as? String == "6f0e5c2a-1b3d-4e7f-8a9b-0c1d2e3f4a5b", "小文字の UUID")
        #expect(json["sequence"] as? Int == 3)
        #expect(json["platform"] as? String == "Mac")
        let update = try #require((json["updates"] as? [[String: Any]])?.first)
        #expect(Set(update.keys) == ["messageId", "messageVersion", "speakerName", "transcript", "timestamp", "version", "deviceId"])
        #expect(update["messageId"] as? String == "others-2")
        #expect(update["speakerName"] as? String == "相手")
        #expect(update["deviceId"] as? String == "others")
        #expect(update["transcript"] as? String == "テスト環境はいつですか")
        #expect(update["messageVersion"] as? Int == 4)
        #expect(update["timestamp"] as? Double == (1_800_000_000 + 12.5) * 1000, "発話の開始時刻（エポックからのミリ秒）")
    }

    @Test("あなたの発話は speakerName が「あなた」")
    func youIsNamed() throws {
        let batch = CaptionBatch.make(sessionId: sessionId, sequence: 1, meetingId: "m", utterances: [Utterance(id: 1, speaker: .you, text: "はい", isFinal: true, startedAt: 0)], sessionStart: start)
        #expect(batch.updates.first?.speakerName == "あなた")
    }

    @Test("終了の合図は、会議の長さ・件数・文字起こしのパスを持つ")
    func endEventShape() throws {
        let end = EndEvent.make(
            sessionId: sessionId, meetingId: "定例", reason: .user, startedAt: start, endedAt: start.addingTimeInterval(1800.4),
            batches: 12, utterances: 80, transcriptPath: "/tmp/x/transcript.md"
        )
        let json = try object(end)
        #expect(Set(json.keys) == ["sessionId", "meetingId", "platform", "reason", "startedAt", "endedAt", "durationSeconds", "batches", "utterances", "transcriptPath"])
        #expect(json["reason"] as? String == "user")
        #expect(json["durationSeconds"] as? Int == 1800)
        #expect(json["transcriptPath"] as? String == "/tmp/x/transcript.md")
        let without = try object(EndEvent.make(sessionId: sessionId, meetingId: "m", reason: .silence, startedAt: start, endedAt: start, batches: 0, utterances: 0, transcriptPath: nil))
        #expect(without["transcriptPath"] == nil, "書けなかったときは、キーごと無い")
    }
}

@Suite("BridgeClient: 認証・経路・失敗の分類", .serialized)
struct BridgeClientTests {
    private func client() -> BridgeClient {
        StubProtocol.requests = []
        let endpoint = try! BridgeEndpoint.parse(url: "http://127.0.0.1:43821", token: token).get()
        return BridgeClient(endpoint: endpoint, session: StubProtocol.session())
    }

    private let batch = CaptionBatch.make(sessionId: UUID(), sequence: 1, meetingId: "m", utterances: [Utterance(id: 1, speaker: .others, text: "あ", isFinal: true, startedAt: 0)], sessionStart: Date())

    @Test("バッチは POST /captions に、Bearer トークンと JSON で送る")
    func sendsBatch() async throws {
        let client = client()
        StubProtocol.handler = { _ in (202, Data()) }
        try await client.send(batch)
        let sent = try #require(StubProtocol.requests.first)
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.url?.path == "/captions")
        #expect(sent.request.value(forHTTPHeaderField: "authorization") == "Bearer " + token)
        #expect(sent.request.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect((try JSONSerialization.jsonObject(with: sent.body) as? [String: Any])?["platform"] as? String == "Mac")
    }

    @Test("終了の合図は POST /end、確認は GET /health")
    func endAndHealth() async throws {
        let client = client()
        StubProtocol.handler = { _ in (200, Data()) }
        try await client.health()
        try await client.send(EndEvent.make(sessionId: UUID(), meetingId: "m", reason: .user, startedAt: Date(), endedAt: Date(), batches: 0, utterances: 0, transcriptPath: nil))
        #expect(StubProtocol.requests.map { $0.request.url?.path } == ["/health", "/end"])
        #expect(StubProtocol.requests.map { $0.request.httpMethod } == ["GET", "POST"])
    }

    @Test("ステータスと通信の失敗を、型で区別する")
    func failures() async {
        let client = client()
        for (status, expected) in [(401, BridgeError.unauthorized), (503, .notReady), (400, .rejected(400)), (413, .rejected(413)), (500, .rejected(500))] {
            StubProtocol.handler = { _ in (status, Data()) }
            await #expect(throws: expected, "HTTP \(status)") { try await client.send(batch) }
        }
        StubProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        await #expect(throws: BridgeError.unreachable) { try await client.send(batch) }
    }
}
