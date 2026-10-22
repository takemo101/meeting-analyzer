import Foundation

public enum BridgeError: Error, Sendable, Equatable {
    /// 接続できない（ブリッジが起動していない）。
    case unreachable
    /// トークンが違う。
    case unauthorized
    /// ブリッジはあるが、受け付けられる状態でない（エージェントのセッションが未接続など）。
    case notReady
    /// 内容が拒否された（HTTP のステータス）。
    case rejected(Int)
}

/// 送り先。ローカルのブリッジだけに送る（字幕は端末の外へ直接出さない）。境界で一度だけ検査して型にする。
public struct BridgeEndpoint: Sendable, Equatable {
    public enum ParseError: Error, Sendable, Equatable {
        case notLoopbackHTTP
        case shortToken
    }

    public let baseURL: URL
    public let token: String

    /// `http://127.0.0.1:<port>`（または `localhost`）だけを受け付ける。トークンは 32 文字以上（ブリッジの要件）。
    public static func parse(url: String, token: String) -> Result<BridgeEndpoint, ParseError> {
        guard let parsed = URL(string: url), parsed.scheme == "http", let host = parsed.host,
              host == "127.0.0.1" || host == "localhost", parsed.user == nil, parsed.password == nil,
              parsed.path.isEmpty || parsed.path == "/", parsed.query == nil
        else { return .failure(.notLoopbackHTTP) }
        guard token.count >= 32, token.allSatisfy({ !$0.isWhitespace && !$0.isNewline }) else { return .failure(.shortToken) }
        return .success(BridgeEndpoint(baseURL: parsed, token: token))
    }
}

/// 字幕と終了の合図を送る窓口。差し替えが要る箇所（再生のテストで、ブリッジを使わずに受け取る）だけ、プロトコルにする。
public protocol BridgeSending: Sendable {
    /// 送る前の確認（ブリッジが起動していて、トークンが合っているか）。
    func health() async throws
    func send(_ batch: CaptionBatch) async throws
    func send(_ end: EndEvent) async throws
}

public final class BridgeClient: BridgeSending, @unchecked Sendable {
    private let endpoint: BridgeEndpoint
    private let session: URLSession

    public init(endpoint: BridgeEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    public func health() async throws {
        try await request(path: "/health", method: "GET", body: nil)
    }

    public func send(_ batch: CaptionBatch) async throws {
        try await request(path: "/captions", method: "POST", body: try Self.encoder.encode(batch))
    }

    public func send(_ end: EndEvent) async throws {
        try await request(path: "/end", method: "POST", body: try Self.encoder.encode(end))
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private func request(path: String, method: String, body: Data?) async throws {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "authorization")
        request.timeoutInterval = 8
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        let response: URLResponse
        do { (_, response) = try await session.data(for: request) }
        catch { throw BridgeError.unreachable }
        guard let http = response as? HTTPURLResponse else { throw BridgeError.unreachable }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw BridgeError.unauthorized
        case 503: throw BridgeError.notReady
        default: throw BridgeError.rejected(http.statusCode)
        }
    }
}
