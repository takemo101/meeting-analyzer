import Darwin
import Foundation

/// ハブの受け手側の出来事。
public enum HubClientEvent: Equatable, Sendable {
    /// ハブへつながった（これから `hello`・これまでの出来事・`sync` が来る）。
    case connected
    /// つながっていない（まだ起動していない、または切れた）。再接続を試し続ける。
    case disconnected
    case message(HubMessage)
}

/// ハブ（このアプリ）へつながり、出来事を受ける。つながらないとき・切れたときは、間隔をあけて、つなぎ直す。
/// `meeting-analyzer mcp` が使う。ハブが後から起動しても、エージェントを起動し直さなくてよいように。
public struct HubClient: Sendable {
    public let socketPath: String
    public let retryInterval: TimeInterval

    public init(socketPath: String, retryInterval: TimeInterval = 2) {
        self.socketPath = socketPath
        self.retryInterval = retryInterval
    }

    /// 流れを取り消すと、接続も閉じる。
    public func events() -> AsyncStream<HubClientEvent> {
        AsyncStream { continuation in
            let state = ConnectionState()
            let path = socketPath, interval = retryInterval
            let thread = Thread {
                // 切れている間、「切れた」を、1 回だけ知らせる。
                var reportedDown = false
                while !state.isStopped {
                    if let fd = Self.connect(path: path) {
                        guard state.adopt(fd) else { Darwin.close(fd); break }
                        reportedDown = false
                        continuation.yield(.connected)
                        Self.read(fd: fd) { continuation.yield(.message($0)) }
                        state.release(fd)
                    }
                    if !reportedDown {
                        reportedDown = true
                        continuation.yield(.disconnected)
                    }
                    if state.isStopped { break }
                    Thread.sleep(forTimeInterval: interval)
                }
                continuation.finish()
            }
            thread.name = "meeting-analyzer.hub-client"
            continuation.onTermination = { _ in state.stop() }
            thread.start()
        }
    }

    // MARK: ソケット

    private static func connect(path: String) -> Int32? {
        guard path.utf8.count <= 103 else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = HubServer.address(path: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { Darwin.close(fd); return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// 1 行ずつ読んで渡す。切れる（または、閉じられる）まで戻らない。
    private static func read(fd: Int32, _ deliver: (HubMessage) -> Void) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return }
            pending.append(buffer, count: count)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                if let message = HubWire.decode(Data(line)) { deliver(message) }
            }
        }
    }

    /// 取り消しと、いまの接続を、スレッドをまたいで共有する。
    private final class ConnectionState: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var current: Int32 = -1

        var isStopped: Bool { lock.withLock { stopped } }

        func adopt(_ fd: Int32) -> Bool {
            lock.withLock {
                if stopped { return false }
                current = fd
                return true
            }
        }

        func release(_ fd: Int32) {
            lock.withLock { current = -1 }
            Darwin.close(fd)
        }

        func stop() {
            lock.withLock {
                stopped = true
                // 読み取りで待っているスレッドを、起こす。
                if current >= 0 { shutdown(current, SHUT_RDWR) }
            }
        }
    }
}
