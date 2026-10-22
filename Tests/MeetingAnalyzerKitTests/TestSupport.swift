import Foundation

/// 試験用の、一時ファイル・ディレクトリの場所（まだ作らない）。名前は、毎回違う（試験を並べて走らせても、ぶつからない）。
func tempURL(_ label: String, ext: String? = nil) -> URL {
    let name = "ma-\(label)-" + UUID().uuidString + (ext.map { "." + $0 } ?? "")
    return FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: ext == nil)
}
