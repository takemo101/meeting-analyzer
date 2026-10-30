import Foundation

/// safetensors の読み取り（メモリへの対応づけ）。ヘッダの JSON と、テンソルのバイト列への窓だけ。
/// 外から来たファイルなので、ヘッダの範囲が、ファイルの中に収まるか（切り詰め・壊れ）を、読むときに一度だけ確かめる。
final class Safetensors {
    struct Info {
        let dtype: String
        let shape: [Int]
        let start: Int
        let end: Int
        var count: Int { shape.reduce(1, *) }
    }

    private let data: Data
    private let base: Int
    let tensors: [String: Info]

    init(url: URL) throws {
        do { data = try Data(contentsOf: url, options: .alwaysMapped) } catch { throw DecisionModelError.unreadable("重みのファイルを読めません") }
        guard data.count > 8 else { throw DecisionModelError.unreadable("重みのファイルが短すぎます") }
        let headerLength = data.prefix(8).withUnsafeBytes { Int($0.loadUnaligned(as: UInt64.self)) }
        guard headerLength > 0, 8 + headerLength <= data.count,
              let header = try? JSONSerialization.jsonObject(with: data.subdata(in: 8..<(8 + headerLength))) as? [String: Any] else {
            throw DecisionModelError.unreadable("重みのファイルのヘッダを読めません")
        }
        base = 8 + headerLength
        var map: [String: Info] = [:]
        for (name, value) in header where name != "__metadata__" {
            guard let v = value as? [String: Any], let dtype = v["dtype"] as? String, let shape = v["shape"] as? [Int],
                  let offsets = v["data_offsets"] as? [Int], offsets.count == 2, offsets[0] >= 0, offsets[0] <= offsets[1],
                  base + offsets[1] <= data.count else {
                throw DecisionModelError.unreadable("重みのファイルの中身が、想定と違います（\(name)）")
            }
            map[name] = Info(dtype: dtype, shape: shape, start: offsets[0], end: offsets[1])
        }
        tensors = map
    }

    func info(_ name: String) throws -> Info {
        guard let info = tensors[name] else { throw DecisionModelError.unreadable("重みに \(name) がありません") }
        return info
    }

    /// テンソルの生のバイト列（コピー）。
    func bytes(_ name: String) throws -> Data {
        let t = try info(name)
        return data.subdata(in: (base + t.start)..<(base + t.end))
    }

    /// BF16 の行（埋め込みの 1 行）を、Float32 へ。
    func bf16Row(_ name: String, row: Int, width: Int) throws -> [Float] {
        let t = try info(name)
        guard t.dtype == "BF16", t.shape.count == 2, t.shape[1] == width, row >= 0, row < t.shape[0] else { throw DecisionModelError.unreadable("埋め込みの形が想定と違います") }
        let offset = base + t.start + row * width * 2
        return data.withUnsafeBytes { raw in (0..<width).map { Float(bitPattern: UInt32(raw.loadUnaligned(fromByteOffset: offset + $0 * 2, as: UInt16.self)) << 16) } }
    }

    /// F32 のテンソル全体。
    func floats(_ name: String) throws -> [Float] {
        let t = try info(name)
        guard t.dtype == "F32" else { throw DecisionModelError.unreadable("\(name) の型が想定と違います") }
        let offset = base + t.start
        return data.withUnsafeBytes { raw in (0..<t.count).map { raw.loadUnaligned(fromByteOffset: offset + $0 * 4, as: Float.self) } }
    }
}
