import Darwin
import Foundation

public enum HubError: Error, Sendable, Equatable {
    /// 同じ場所で、別のハブ（実行中のこのアプリ）が待っている。
    case alreadyRunning(String)
    /// ソケットのパスが長すぎる（`sockaddr_un` は 103 バイトまで）。
    case pathTooLong(String)
    case failed(String)
}

/// エージェントへ渡す窓口。このアプリの中で、Unix ドメインソケット（ディレクトリ 0700・ソケット 0600・同じユーザーだけ）で待ち、
/// 出来事（`TranscriptEvent`）を、接続している受け手（`meeting-analyzer mcp`）すべてへ、1 行 1 件の JSON で流す。
/// ネットワークは使わない。直近の出来事を、メモリ上だけに保持して、あとから接続した受け手へ、先に渡す。
public final class HubServer: EventSink, @unchecked Sendable {
    public let socketPath: String
    public let hubId = UUID().uuidString.lowercased()

    private let logLimit: Int
    private let lock = NSLock()
    private var log: [HubEnvelope] = []
    private var nextId = 1
    private var clients: [ObjectIdentifier: Client] = [:]
    private var listener: DispatchSourceRead?
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "dev.takemo101.meeting-analyzer.hub.accept")
    private var onClientCount: (@Sendable (Int) -> Void)?

    public init(socketPath: String, logLimit: Int = 2000) {
        self.socketPath = socketPath
        self.logLimit = logLimit
    }

    /// 受け手の数が変わったときに呼ぶ（メニューの表示用）。呼び出しは、どのスレッドからでも来る。
    public func setClientCountHandler(_ handler: (@Sendable (Int) -> Void)?) {
        lock.withLock { onClientCount = handler }
    }

    public var clientCount: Int { lock.withLock { clients.count } }

    // MARK: 開始・停止

    public func start() throws {
        // 受け手が切れた直後の書き込みは、SIGPIPE になる（アプリが終了してしまう）。ソケットの SO_NOSIGPIPE は、相手が先に切れていると設定に失敗するので、
        // プロセス全体で SIGPIPE を無視して、書き込みの失敗（EPIPE）として扱う。
        signal(SIGPIPE, SIG_IGN)
        guard socketPath.utf8.count <= 103 else { throw HubError.pathTooLong(socketPath) }
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { throw HubError.failed("置き場所を作れません: \(directory.path)") }

        // 古いソケットのファイルが残っているとき：別のハブが生きていれば断り、死んでいれば消す。
        if FileManager.default.fileExists(atPath: socketPath) {
            if Self.canConnect(path: socketPath) { throw HubError.alreadyRunning(socketPath) }
            unlink(socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HubError.failed("ソケットを作れません (errno \(errno))") }
        var address = Self.address(path: socketPath)
        // ソケットのファイルは、作ったあとすぐ 0600 にする。置き場所のディレクトリが 0700 なので、それまでの間も、他のユーザーは届かない。
        // （プロセス全体の umask は、他のスレッドのファイル作成に影響するので、変えない。）
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { let code = errno; close(fd); throw HubError.failed("待ち受けを始められません (errno \(code))") }
        chmod(socketPath, 0o600)
        guard listen(fd, SOMAXCONN) == 0 else { let code = errno; close(fd); unlink(socketPath); throw HubError.failed("listen に失敗 (errno \(code))") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
        source.setCancelHandler { close(fd) }
        lock.withLock { listenFD = fd; listener = source }
        source.resume()
    }

    public func stop() {
        let (source, all): (DispatchSourceRead?, [Client]) = lock.withLock {
            let result = (listener, Array(clients.values))
            listener = nil
            listenFD = -1
            clients = [:]
            return result
        }
        source?.cancel()
        unlink(socketPath)
        for client in all { client.close() }
    }

    // MARK: 公開

    public func publish(_ event: TranscriptEvent) {
        lock.withLock {
            // 新しいセッションが始まったら、前のセッションの出来事は、もう要らない。
            if case .started = event { log.removeAll() }
            let envelope = HubEnvelope(id: nextId, event: event)
            nextId += 1
            log.append(envelope)
            if log.count > logLimit { log.removeFirst(log.count - logLimit) }
            let line = HubWire.line(.event(envelope))
            for client in clients.values { client.send(line) { [weak self] in self?.remove($0) } }
        }
    }

    // MARK: 受け手

    private func acceptPending(on listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            var uid: uid_t = 0, gid: gid_t = 0
            // 同じユーザーのプロセスだけを受け付ける。
            guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { close(fd); continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            attach(Client(fd: fd, onClose: { [weak self] in self?.remove($0) }))
        }
    }

    private func attach(_ client: Client) {
        let handler: (@Sendable (Int) -> Void)? = lock.withLock {
            // これまでの出来事を、新しい出来事より先に、同じ待ち行列へ入れる（ロックの中なので、順序が崩れない）。
            let remove: @Sendable (Client) -> Void = { [weak self] in self?.remove($0) }
            client.send(HubWire.line(.hello(hubId: hubId)), onFailure: remove)
            for envelope in log { client.send(HubWire.line(.event(envelope)), onFailure: remove) }
            client.send(HubWire.line(.sync), onFailure: remove)
            // 登録の前に、もう切れていた受け手は、登録しない。
            guard !client.isClosed else { return nil }
            clients[ObjectIdentifier(client)] = client
            return onClientCount
        }
        handler?(clientCount)
    }

    private func remove(_ client: Client) {
        let (removed, handler, count): (Bool, (@Sendable (Int) -> Void)?, Int) = lock.withLock {
            let removed = clients.removeValue(forKey: ObjectIdentifier(client)) != nil
            return (removed, onClientCount, clients.count)
        }
        client.close()
        if removed { handler?(count) }
    }

    // MARK: ソケット

    static func address(path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(path.utf8)
            for (index, byte) in bytes.enumerated() where index < buffer.count - 1 { buffer[index] = byte }
        }
        return address
    }

    /// 別のハブが、そのパスで待っているか。
    static func canConnect(path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = address(path: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return result == 0
    }

    /// 1 つの受け手。書き込みは、受け手ごとの待ち行列で順に行い、遅い受け手が、会議の処理を止めないようにする。
    /// fd は、読み取りの監視（同じ待ち行列）の取り消しの中で閉じる。進行中の書き込みが終わってから閉じるので、閉じた fd を触らない。
    private final class Client: @unchecked Sendable {
        private let fd: Int32
        private let queue = DispatchQueue(label: "dev.takemo101.meeting-analyzer.hub.client")
        private let lock = NSLock()
        private var closed = false
        private let source: DispatchSourceRead

        /// `onClose`：受け手が切れたとき（読めて 0 バイト）。受け手からは、何も送られない前提。
        init(fd: Int32, onClose: @escaping @Sendable (Client) -> Void) {
            self.fd = fd
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setCancelHandler { Darwin.close(fd) }
            source.setEventHandler { [unowned self] in
                var byte: UInt8 = 0
                if read(fd, &byte, 1) <= 0 { onClose(self) }
            }
            source.resume()
        }

        var isClosed: Bool { lock.withLock { closed } }

        func send(_ data: Data, onFailure: @escaping @Sendable (Client) -> Void) {
            queue.async { [self] in
                guard !isClosed else { return }
                if !write(data) { onFailure(self) }
            }
        }

        private func write(_ data: Data) -> Bool {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written > 0 { offset += written; continue }
                    if written < 0 && errno == EINTR { continue }
                    return false
                }
                return true
            }
        }

        func close() {
            let first: Bool = lock.withLock {
                if closed { return false }
                closed = true
                return true
            }
            if first { source.cancel() }
        }
    }
}
