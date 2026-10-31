import Foundation

public enum ModelDownloadError: Error, Sendable, Equatable {
    /// 通信の失敗（接続できない・途中で切れた）。取得済みの分は残り、続きから再開できる。
    case network(String)
    /// サーバーが、想定外の応答を返した。
    case badStatus(Int)
    /// ファイルの大きさが、固定した値と違う（取得し直す）。
    case sizeMismatch(expected: Int64, actual: Int64)
    /// SHA-256 が、固定した値と違う（途中のファイルを捨てる）。
    case checksumMismatch
    /// 利用者が、取り消した。取得済みの分は残り、続きから再開できる。
    case cancelled
    /// ディスクに書けない。
    case writeFailed(String)
}

extension ModelDownloadError {
    /// 利用者に見せる、原因の文（メニュー・CLI が同じ文を使う。対処の案内は、見せる側が足す）。
    public var message: String {
        switch self {
        case .network(let reason): return "通信に失敗しました（\(reason)）"
        case .badStatus(let code): return "サーバーが、想定外の応答（\(code)）を返しました"
        case .sizeMismatch: return "ファイルの大きさが、想定と違います"
        case .checksumMismatch: return "ファイルの検証（SHA-256）に通りません"
        case .cancelled: return "取り消しました"
        case .writeFailed(let reason): return "ディスクに書けません（\(reason)）"
        }
    }
}

/// モデルのファイルを、Hugging Face から取得する（SPEC §3.12）。**利用者が押したときだけ**使う。音声は送らない（通信するのは、固定した版のファイルの取得だけ）。
/// 途中で切れても、取得済みの分（`.part`）から、続きを（HTTP の Range で）再開できる。完了したら、大きさと SHA-256 を確かめ、合えば、本来の名前にして、0600 にする。
/// 同時に 1 つだけ。
public final class ModelDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let store: ModelStore
    private let configuration: URLSessionConfiguration
    private let resolveURL: @Sendable (ModelArtifact) -> URL

    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var artifact: ModelArtifact?
    private var received: Int64 = 0
    private var offset: Int64 = 0
    private var progress: (@Sendable (Int64, Int64) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: ModelDownloadError?

    /// `resolveURL`：取得先（試験で、差し替える）。
    public init(store: ModelStore, configuration: URLSessionConfiguration = .ephemeral, resolveURL: @escaping @Sendable (ModelArtifact) -> URL = { $0.downloadURL }) {
        self.store = store
        self.configuration = configuration
        self.resolveURL = resolveURL
    }

    /// 取り消す（取得済みの分は残す）。
    public func cancel() {
        lock.lock(); let task = task; lock.unlock()
        task?.cancel()
    }

    /// 取得して、検証する。`progress`：（取得済みのバイト数、全体のバイト数）。すでに検証済みなら、何もしない。
    public func download(_ artifact: ModelArtifact, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        if store.isInstalled(artifact) { progress(artifact.bytes, artifact.bytes); return }
        try store.prepareParent(of: artifact)
        let part = store.partURL(artifact)
        var resumeFrom = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        if resumeFrom > artifact.bytes { try? FileManager.default.removeItem(at: part); resumeFrom = 0 }

        if resumeFrom < artifact.bytes {
            try await transfer(artifact, from: resumeFrom, progress: progress)
        }
        try finish(artifact)
        progress(artifact.bytes, artifact.bytes)
    }

    private func transfer(_ artifact: ModelArtifact, from resumeFrom: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let part = store.partURL(artifact)
        if !FileManager.default.fileExists(atPath: part.path) {
            guard FileManager.default.createFile(atPath: part.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ModelDownloadError.writeFailed(part.path) }
        }
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: part); try handle.seekToEnd() } catch { throw ModelDownloadError.writeFailed(error.localizedDescription) }

        var request = URLRequest(url: resolveURL(artifact))
        request.timeoutInterval = 60
        if resumeFrom > 0 { request.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range") }

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate(); try? handle.close() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            self.session = session
            self.artifact = artifact
            self.handle = handle
            self.received = resumeFrom
            self.offset = resumeFrom
            self.progress = progress
            self.continuation = continuation
            self.failure = nil
            let task = session.dataTask(with: request)
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    /// 完了後の検証：大きさ → SHA-256。合えば、本来の名前にして、0600・検証済みの印を付ける。
    private func finish(_ artifact: ModelArtifact) throws {
        let part = store.partURL(artifact)
        let size = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size == artifact.bytes else {
            try? FileManager.default.removeItem(at: part)
            throw ModelDownloadError.sizeMismatch(expected: artifact.bytes, actual: size)
        }
        guard let sum = try? ModelStore.sha256(of: part), sum == artifact.sha256 else {
            try? FileManager.default.removeItem(at: part)
            throw ModelDownloadError.checksumMismatch
        }
        let destination = store.fileURL(artifact)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: part, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch { throw ModelDownloadError.writeFailed(error.localizedDescription) }
        store.markVerified(artifact)
    }

    // MARK: URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { fail(.network("応答を読めません")); completionHandler(.cancel); return }
        lock.lock(); let offset = self.offset; lock.unlock()
        switch http.statusCode {
        case 206:
            // 続きの位置が、こちらの取得済みの位置と同じでなければ、使えない。
            let range = (http.value(forHTTPHeaderField: "Content-Range") ?? "").split(separator: " ").last?.split(separator: "-").first.flatMap { Int64($0) }
            if range != offset { fail(.network("続きの位置が合いません")); completionHandler(.cancel); return }
        case 200:
            // 再開の指定が無視された（全体を、先頭から送ってきた）。取得済みの分を捨てて、先頭から書く。
            if offset > 0 {
                lock.lock()
                try? handle?.truncate(atOffset: 0); try? handle?.seek(toOffset: 0)
                received = 0; self.offset = 0
                lock.unlock()
            }
        default:
            fail(.badStatus(http.statusCode)); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil, let handle, let artifact else { return }
        do {
            try handle.write(contentsOf: data)
            received += Int64(data.count)
            progress?(min(received, artifact.bytes), artifact.bytes)
        } catch {
            failure = .writeFailed(error.localizedDescription)
            dataTask.cancel()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.task = nil
        var result = failure
        lock.unlock()
        if result == nil, let error {
            result = (error as? URLError)?.code == .cancelled ? .cancelled : .network(error.localizedDescription)
        }
        if let result { continuation?.resume(throwing: result) } else { continuation?.resume() }
    }

    private func fail(_ error: ModelDownloadError) {
        lock.lock(); failure = failure ?? error; lock.unlock()
    }
}
