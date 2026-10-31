import Foundation

/// 試験用の、一時ファイル・ディレクトリの場所（まだ作らない）。名前は、毎回違う（試験を並べて走らせても、ぶつからない）。
func tempURL(_ label: String, ext: String? = nil) -> URL {
    let name = "ma-\(label)-" + UUID().uuidString + (ext.map { "." + $0 } ?? "")
    return FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: ext == nil)
}

/// 試験用：別のスレッドから渡される値を、順に溜める（読み取りは、そのときまでの写し）。
final class Collected<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []
    func add(_ value: Element) { lock.withLock { storage.append(value) } }
    var values: [Element] { lock.withLock { storage } }
}
