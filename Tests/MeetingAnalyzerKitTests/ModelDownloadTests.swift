import CryptoKit
import Foundation
import Testing
@testable import MeetingAnalyzerKit

/// 通信の代わり。要求（Range を含む）を見て、応答を返す。
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// 本文を、この大きさずつ送る。
        var chunk = 64 * 1024
        /// true なら、最初の 1 つの断片を送ったあと、終わらずに待つ（取り消しの試験）。
        var stall = false
    }
    /// 試験ごとに別の取得先（パス）を使い、その取得先の応答だけを登録する（試験が並行して動いても、混ざらない）。
    nonisolated(unsafe) private static var handlers: [String: @Sendable (URLRequest) -> Reply] = [:]
    nonisolated(unsafe) private static var requests: [String: [URLRequest]] = [:]
    private static let lock = NSLock()

    static func register(_ artifact: ModelArtifact, _ handler: @escaping @Sendable (URLRequest) -> Reply) {
        lock.lock(); handlers[artifact.downloadURL.path] = handler; requests[artifact.downloadURL.path] = []; lock.unlock()
    }
    static func seenRequests(_ artifact: ModelArtifact) -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests[artifact.downloadURL.path] ?? [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var stopped = false

    override func startLoading() {
        let key = request.url?.path ?? ""
        Self.lock.lock(); Self.requests[key, default: []].append(request); let handler = Self.handlers[key]; Self.lock.unlock()
        guard let reply = handler?(request), let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var index = reply.body.startIndex
        while index < reply.body.endIndex, !stopped {
            let end = reply.body.index(index, offsetBy: reply.chunk, limitedBy: reply.body.endIndex) ?? reply.body.endIndex
            client?.urlProtocol(self, didLoad: reply.body[index..<end])
            index = end
            if reply.stall { return }
        }
        if !stopped { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() { stopped = true }
}

private func makeConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return configuration
}

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private func artifact(for data: Data, name: String = "m.gguf") -> ModelArtifact {
    ModelArtifact(repository: "o/\(UUID().uuidString)", revision: "rev", filename: name, bytes: Int64(data.count), sha256: sha(data))
}

private func payload(_ n: Int, seed: UInt8 = 1) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }) }

/// Range（`bytes=N-`）つきの要求なら 206、無ければ 200 を返す、まともなサーバー。
private func honestServer(_ data: Data) -> @Sendable (URLRequest) -> StubProtocol.Reply {
    { request in
        if let range = request.value(forHTTPHeaderField: "Range"), let start = Int(range.dropFirst("bytes=".count).dropLast()) {
            return .init(status: 206, headers: ["Content-Range": "bytes \(start)-\(data.count - 1)/\(data.count)"], body: data.suffix(from: start))
        }
        return .init(status: 200, body: data)
    }
}

@Suite("ModelDownloader: ダウンロードと検証（SPEC §3.12）", .serialized)
struct ModelDownloadTests {
    private func makeStore() -> ModelStore { ModelStore(root: tempURL("models")) }

    @Test("取得 → 大きさと SHA-256 を確かめ → 本来の名前（0600）にして、検証済みになる。進み具合は、増えて、最後に全体になる")
    func success() async throws {
        let data = payload(300_000)
        let store = makeStore(), item = artifact(for: data)
        defer { try? FileManager.default.removeItem(at: store.root) }
        StubProtocol.register(item, honestServer(data))
        let reports = Collected<Int64>()
        try await ModelDownloader(store: store, configuration: makeConfiguration()).download(item) { received, _ in reports.add(received) }
        #expect(store.isInstalled(item))
        #expect(try Data(contentsOf: store.fileURL(item)) == data)
        #expect((try FileManager.default.attributesOfItem(atPath: store.fileURL(item).path)[.posixPermissions] as? Int) == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int) == 0o700)
        #expect(!FileManager.default.fileExists(atPath: store.partURL(item).path), "途中のファイルは、残らない")
        let values = reports.values
        #expect(values == values.sorted() && values.last == item.bytes)
        // 取得済みなら、通信しない
        StubProtocol.register(item) { _ in .init(status: 500) }
        try await ModelDownloader(store: store, configuration: makeConfiguration()).download(item) { _, _ in }
        #expect(StubProtocol.seenRequests(item).isEmpty)
    }

    @Test("SHA-256 が違えば、失敗し、途中のファイルも、本来のファイルも残らない")
    func checksumMismatch() async throws {
        let data = payload(100_000)
        let store = makeStore(), item = artifact(for: data)
        defer { try? FileManager.default.removeItem(at: store.root) }
        StubProtocol.register(item, honestServer(payload(100_000, seed: 9)))   // 同じ大きさで、中身が違う
        await #expect(throws: ModelDownloadError.checksumMismatch) {
            try await ModelDownloader(store: store, configuration: makeConfiguration()).download(item) { _, _ in }
        }
        #expect(!store.isInstalled(item) && !FileManager.default.fileExists(atPath: store.partURL(item).path) && !FileManager.default.fileExists(atPath: store.fileURL(item).path))
    }

    @Test("大きさが違えば（途中で切れた）、失敗する。HTTP の失敗は、状態を返す")
    func sizeAndStatus() async throws {
        let data = payload(100_000)
        let store = makeStore(), item = artifact(for: data)
        defer { try? FileManager.default.removeItem(at: store.root) }
        StubProtocol.register(item) { _ in .init(status: 200, body: data.prefix(40_000)) }
        await #expect(throws: ModelDownloadError.sizeMismatch(expected: 100_000, actual: 40_000)) {
            try await ModelDownloader(store: store, configuration: makeConfiguration()).download(item) { _, _ in }
        }
        StubProtocol.register(item) { _ in .init(status: 404) }
        await #expect(throws: ModelDownloadError.badStatus(404)) {
            try await ModelDownloader(store: store, configuration: makeConfiguration()).download(item) { _, _ in }
        }
    }

    @Test("途中のファイルがあれば、続きから（Range）取得する。Range を無視するサーバーでも、正しく完成する")
    func resume() async throws {
        let data = payload(200_000)
        let store = makeStore(), item = artifact(for: data)
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.prepareDirectory()
        try data.prefix(70_000).write(to: store.partURL(item))
        StubProtocol.register(item, honestServer(data))
        try await ModelDownloader(store: store, configuration: makeConfiguration()).download(item) { _, _ in }
        #expect(StubProtocol.seenRequests(item).first?.value(forHTTPHeaderField: "Range") == "bytes=70000-")
        #expect(try Data(contentsOf: store.fileURL(item)) == data)
        store.delete(item)

        // Range を無視して、全体を 200 で返すサーバー：取得済みの分を捨てて、先頭から書き直す
        try data.prefix(70_000).write(to: store.partURL(item))
        StubProtocol.register(item) { _ in .init(status: 200, body: data) }
        try await ModelDownloader(store: store, configuration: makeConfiguration()).download(item) { _, _ in }
        #expect(try Data(contentsOf: store.fileURL(item)) == data)
    }

    @Test("取り消すと、cancelled で終わり、取得済みの分は残る。そのあと、続きから完成できる")
    func cancelThenResume() async throws {
        let data = payload(500_000)
        let store = makeStore(), item = artifact(for: data)
        defer { try? FileManager.default.removeItem(at: store.root) }
        StubProtocol.register(item) { _ in .init(body: data, chunk: 100_000, stall: true) }   // 100 KB を送って、止まる
        let downloader = ModelDownloader(store: store, configuration: makeConfiguration())
        let running = Task { try await downloader.download(item) { _, _ in } }
        for _ in 0..<200 where store.downloadedBytes(item) < 100_000 { try await Task.sleep(for: .milliseconds(10)) }
        downloader.cancel()
        await #expect(throws: ModelDownloadError.cancelled) { try await running.value }
        let kept = store.downloadedBytes(item)
        #expect(kept >= 100_000 && kept < item.bytes && !store.isInstalled(item))

        StubProtocol.register(item, honestServer(data))
        try await ModelDownloader(store: store, configuration: makeConfiguration()).download(item) { _, _ in }
        #expect(StubProtocol.seenRequests(item).first?.value(forHTTPHeaderField: "Range") == "bytes=\(kept)-")
        #expect(try Data(contentsOf: store.fileURL(item)) == data)
    }
}

@Suite("ModelStore: 検証済みの印と、使う前の確認")
struct ModelStoreTests {
    private func install(_ data: Data) async throws -> (ModelStore, ModelArtifact) {
        let store = ModelStore(root: tempURL("models-store")), item = artifact(for: data)
        StubProtocol.register(item, honestServer(data))
        try await ModelDownloader(store: store, configuration: makeConfiguration()).download(item) { _, _ in }
        return (store, item)
    }

    @Test("取得したファイルを、あとから書き換えると、検証済みでなくなる。ensureVerified は、SHA-256 を確かめ、違えば消す")
    func tamper() async throws {
        let data = payload(50_000)
        let (store, item) = try await install(data)
        defer { try? FileManager.default.removeItem(at: store.root) }
        #expect(store.isInstalled(item) && store.ensureVerified(item))

        // 同じ大きさで、中身を書き換える（更新時刻が変わる）
        var tampered = data; tampered[10] ^= 0xFF
        try tampered.write(to: store.fileURL(item))
        #expect(!store.isInstalled(item), "印と更新時刻が合わない")
        #expect(!store.ensureVerified(item) && !FileManager.default.fileExists(atPath: store.fileURL(item).path), "SHA-256 が違えば、消す")
    }

    @Test("正しい中身のファイルを、コピー・移動（更新時刻が変わる）しても、SHA-256 で確かめて、使える。大きさが違えば、使えない")
    func recopyAndSize() async throws {
        let data = payload(50_000)
        let (store, item) = try await install(data)
        defer { try? FileManager.default.removeItem(at: store.root) }
        try data.write(to: store.fileURL(item))   // 同じ中身を、書き直した（更新時刻が変わる）
        #expect(!store.isInstalled(item) && store.ensureVerified(item) && store.isInstalled(item))

        try Data(data.prefix(10)).write(to: store.fileURL(item))
        #expect(!store.isInstalled(item) && !store.ensureVerified(item))
        store.delete(item)
        #expect(store.downloadedBytes(item) == 0)
    }

    @Test("固定した版が違えば、別のファイル名になる（古い版のファイルを、新しい版として使わない）。カタログの版・SHA-256 の形")
    func fileNames() {
        let a = ModelArtifact(repository: "o/r", revision: "r1", filename: "m.gguf", bytes: 1, sha256: String(repeating: "a", count: 64))
        let b = ModelArtifact(repository: "o/r", revision: "r2", filename: "m.gguf", bytes: 1, sha256: String(repeating: "b", count: 64))
        let store = ModelStore(root: URL(fileURLWithPath: "/tmp/x"))
        #expect(store.fileURL(a) != store.fileURL(b))
        #expect(a.downloadURL.absoluteString == "https://huggingface.co/o/r/resolve/r1/m.gguf")
        for artifact in LocalModelCatalog.all.map(\.artifact) + [LocalModelCatalog.voiceActivity] {
            #expect(artifact.sha256.count == 64 && artifact.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            #expect(artifact.revision.count == 40 && artifact.bytes > 0)
        }
        #expect(Set(LocalModelCatalog.all.map(\.id)).count == LocalModelCatalog.all.count)
        #expect(TranscriptionChoice(id: "apple") == .apple && TranscriptionChoice(id: "qwen3-asr-0.6b") == .local("qwen3-asr-0.6b") && TranscriptionChoice(id: "nope") == nil)
    }
}
