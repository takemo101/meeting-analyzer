import Foundation

/// 声紋のファイルを読んだ結果（SPEC §3.15）。
public enum VoiceprintLoad: Sendable, Equatable {
    /// ファイルが無い（まだ、誰も覚えていない）。
    case none
    case loaded(VoiceprintLibrary)
    /// 読めない・壊れている・知らない版の書式。**消さずに**、使わない（理由つき）。
    case unusable(String)
}

public enum VoiceprintStoreError: Error, Sendable, Equatable {
    case writeFailed
}

/// 声紋（名前と声の特徴だけ。音声は含まない）を、`<データの置き場所>/voiceprints.json` に、利用者だけが読める形で置く（ディレクトリ 0700・ファイル 0600）。
/// **読むときに、一度だけ検査して**、型にする（名前・上限・数の値）。壊れたファイルは、使わず、消さない。
public struct VoiceprintStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var file: URL { root.appendingPathComponent("voiceprints.json") }

    private static let format = 1

    private struct Envelope: Codable {
        let version: Int
        let modelRevision: String
        let people: [VoiceprintLibrary.Person]
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func load() -> VoiceprintLoad {
        guard FileManager.default.fileExists(atPath: file.path) else { return .none }
        guard let data = try? Data(contentsOf: file) else { return .unusable("声紋のファイルを読めません") }
        guard let envelope = try? Self.decoder().decode(Envelope.self, from: data) else { return .unusable("声紋のファイルの書式が壊れています") }
        guard envelope.version == Self.format else { return .unusable("声紋のファイルの書式の版（\(envelope.version)）を、このアプリは読めません") }
        guard envelope.people.count <= VoiceprintLibrary.maxPeople else { return .unusable("声紋の人数が多すぎます") }
        var people: [VoiceprintLibrary.Person] = []
        var names = Set<String>()
        for person in envelope.people {
            guard SpeakerNameRule.normalize(person.name) == person.name, names.insert(person.name).inserted else { return .unusable("声紋の名前が不正です") }
            guard !person.vectors.isEmpty, person.vectors.count <= VoiceprintLibrary.maxVectorsPerPerson else { return .unusable("声紋の数が不正です") }
            var vectors: [[Float]] = []
            for vector in person.vectors {
                guard let normalized = VoiceprintLibrary.normalized(vector) else { return .unusable("声紋の値が不正です") }
                vectors.append(normalized)
            }
            people.append(VoiceprintLibrary.Person(name: person.name, vectors: vectors, lastUsed: person.lastUsed))
        }
        return .loaded(VoiceprintLibrary(modelRevision: envelope.modelRevision, people: people))
    }

    /// 書く（全体を置き換える）。誰もいなければ、ファイルを消す。
    public func save(_ library: VoiceprintLibrary) throws {
        do {
            if library.isEmpty {
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                return
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try Self.encoder().encode(Envelope(version: Self.format, modelRevision: library.modelRevision, people: library.people))
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            throw VoiceprintStoreError.writeFailed
        }
    }
}
