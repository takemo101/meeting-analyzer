import Foundation

/// 声紋の候補 1 件（名付けの画面に見せる。SPEC §3.15）。
public struct VoiceprintCandidate: Sendable, Equatable {
    public let name: String
    /// コサイン類似度（1 人の複数の声紋のうち、最大のもの）。
    public let similarity: Double

    public init(name: String, similarity: Double) {
        self.name = name
        self.similarity = similarity
    }
}

/// 声の特徴（話者の埋め込み）と、人の名前の対応（SPEC §3.15）。**音声は含まない**。純粋な規則（保存は `VoiceprintStore`）。
public struct VoiceprintLibrary: Codable, Equatable, Sendable {
    /// 1 人の名前と、その人の声の特徴（正規化した数値のベクトル。古い順）。
    public struct Person: Codable, Equatable, Sendable {
        public let name: String
        public var vectors: [[Float]]
        /// 最後に使った（覚えた・照合で一致した）日。
        public var lastUsed: Date
    }

    public enum AddError: Error, Sendable, Equatable {
        case invalidName
        /// 声の特徴が、空・0 ベクトル・数でない値を含む。
        case invalidVector
        /// 50 人を超える。
        case full
        /// 保存してある声紋が、別の版の分離モデルで作られている（混ぜると、比べられない）。
        case revisionMismatch
    }

    public static let maxPeople = 50
    public static let maxVectorsPerPerson = 5
    /// 自動で名前を付ける類似度の下限と、次点（別の人）との差の下限（暫定の値。SPEC §3.15・測定は検証記録の 2026-11-01）。
    public static let autoThreshold = 0.8
    public static let autoMargin = 0.1
    /// 候補として見せる類似度の下限。
    public static let candidateThreshold = 0.45

    /// この声紋を作った分離モデルの版（`VoiceModel.revision`）。
    public let modelRevision: String
    public private(set) var people: [Person]

    public init(modelRevision: String, people: [Person] = []) {
        self.modelRevision = modelRevision
        self.people = people
    }

    public var isEmpty: Bool { people.isEmpty }

    /// ベクトルを長さ 1 にする。空・0 ベクトル・有限でない値を含むものは `nil`。
    static func normalized(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return nil }
        return vector.map { $0 / norm }
    }

    /// 声の特徴 2 つのコサイン類似度（長さが違えば 0）。
    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = Float(0)
        for index in lhs.indices { dot += lhs[index] * rhs[index] }
        return Double(dot)
    }

    /// 人ごとの類似度（その人の声紋のうち最大）を、高い順に。
    public func ranking(of embedding: [Float]) -> [VoiceprintCandidate] {
        guard let query = Self.normalized(embedding) else { return [] }
        return people.map { person in
            VoiceprintCandidate(name: person.name, similarity: person.vectors.map { Self.cosine(query, $0) }.max() ?? 0)
        }.sorted { lhs, rhs in
            lhs.similarity != rhs.similarity ? lhs.similarity > rhs.similarity : lhs.name < rhs.name
        }
    }

    /// 照合の結果（SPEC §3.15）：自動で名前を付ける人と、候補（類似度が `candidateThreshold` 以上で、自動の対象でない人）。
    public struct Match: Sendable, Equatable {
        public let automatic: VoiceprintCandidate?
        public let candidates: [VoiceprintCandidate]
    }

    /// **0.8 以上で、次点（別の人）との差が 0.1 以上なら、自動**。0.45 以上は、候補。0.45 未満は、何も返さない。
    public func match(_ embedding: [Float]) -> Match {
        let ranked = ranking(of: embedding)
        guard let best = ranked.first, best.similarity >= Self.candidateThreshold else { return Match(automatic: nil, candidates: []) }
        let runnerUp = ranked.dropFirst().first?.similarity
        if best.similarity >= Self.autoThreshold, best.similarity - (runnerUp ?? -1) >= Self.autoMargin {
            return Match(automatic: best, candidates: [])
        }
        return Match(automatic: nil, candidates: ranked.filter { $0.similarity >= Self.candidateThreshold })
    }

    /// 声の特徴を、その人へ足す（人がいなければ、作る）。1 人 5 つまで（古いものから置き換える）。名前は `SpeakerNameRule` に従う。
    public mutating func add(name rawName: String, vector: [Float], now: Date) throws {
        guard let name = SpeakerNameRule.normalize(rawName) else { throw AddError.invalidName }
        guard let vector = Self.normalized(vector) else { throw AddError.invalidVector }
        if let index = people.firstIndex(where: { $0.name == name }) {
            people[index].vectors.append(vector)
            if people[index].vectors.count > Self.maxVectorsPerPerson { people[index].vectors.removeFirst(people[index].vectors.count - Self.maxVectorsPerPerson) }
            people[index].lastUsed = now
        } else {
            guard people.count < Self.maxPeople else { throw AddError.full }
            people.append(Person(name: name, vectors: [vector], lastUsed: now))
        }
    }

    /// 照合で一致した日を、記録する（一覧の「最後に使った日」）。
    public mutating func touch(name: String, now: Date) {
        if let index = people.firstIndex(where: { $0.name == name }) { people[index].lastUsed = now }
    }

    public mutating func remove(name: String) { people.removeAll { $0.name == name } }
    public mutating func removeAll() { people = [] }
}
