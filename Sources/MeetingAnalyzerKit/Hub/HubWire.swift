import Foundation

/// ハブが付けた通し番号つきの出来事。`id` は、ハブが起動してからの通し番号（1 から）。
public struct HubEnvelope: Codable, Equatable, Sendable {
    public let id: Int
    public let event: TranscriptEvent
}

/// ハブ → 受け手の 1 行（JSON）。順序：`hello` → これまでの出来事（`event`）→ `sync` → 新しい出来事。
public enum HubMessage: Equatable, Sendable {
    /// 接続の最初。`hub` は、ハブの起動ごとに変わる識別子（通し番号が、ハブをまたいで比較できないことを、受け手が知るため）。
    case hello(hubId: String)
    case event(HubEnvelope)
    /// これまでの出来事を送り終えた印。これより後が、接続してから起きた出来事。
    case sync
}

enum HubWire {
    static let protocolVersion = 1

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// 末尾の改行つき 1 行。
    static func line(_ message: HubMessage) -> Data {
        var data: Data
        switch message {
        case .hello(let hubId):
            data = (try? JSONSerialization.data(withJSONObject: ["hello": ["hub": hubId, "version": protocolVersion]], options: [.sortedKeys])) ?? Data()
        case .event(let envelope):
            data = (try? encoder.encode(envelope)) ?? Data()
        case .sync:
            data = Data(#"{"sync":true}"#.utf8)
        }
        data.append(0x0A)
        return data
    }

    static func decode(_ line: Data) -> HubMessage? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
        if let hello = object["hello"] as? [String: Any], let hub = hello["hub"] as? String { return .hello(hubId: hub) }
        if object["sync"] as? Bool == true { return .sync }
        if let envelope = try? JSONDecoder().decode(HubEnvelope.self, from: line) { return .event(envelope) }
        return nil
    }
}
