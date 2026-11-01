import Foundation

/// 名付けの画面に見せる、名前のヒント 1 件（SPEC §3.13）。**確定ではない**。
public struct SpeakerHint: Sendable, Equatable {
    public let name: String
    /// 話者の発話にわたる、確率の平均（0〜1）。名乗りだけのヒントは `nil`。
    public let probability: Double?
    /// その話者の発話に、名乗り（「佐藤です」）があった。
    public let introduced: Bool

    public init(name: String, probability: Double?, introduced: Bool) {
        self.name = name
        self.probability = probability
        self.introduced = introduced
    }
}

/// 話者（話者 N）の発話から、名前のヒントを出す（SPEC §3.13）。**名前を決めない**。確率のしきい値も、持たない。
///
/// 規則（`SpeakerGuesser` と同じ手がかり）：①6 文字未満の発言は、使わない。②名乗りがあれば、その人を「名乗りあり」のヒントにする（モデルを使わない）。
/// ③名前・呼ばれ方が出た人は、その発話の候補から外す。④判断モデルへ「誰が話したか」と「内容を持たないか」を問い、**「内容を持たない」確率が 0.5 以上の発話は、平均に入れない**。
/// 平均した確率の上位 3 人を返す。
public struct SpeakerHintMaker: Sendable {
    static let minimumLength = 6
    /// 「内容を持たない」確率が、これ以上の発話は、平均に入れない（暫定の値）。
    static let fillerLimit = 0.5
    /// 1 話者につき、判断に使う発話の数（長いものから）。
    public static let maxTexts = 20
    static let topCount = 3

    public let list: ActorList
    private let judge: any SpeakerJudge
    private let attendance: Attendance

    public init(list: ActorList, judge: any SpeakerJudge, attendance: Attendance = Attendance()) {
        self.list = list
        self.judge = judge
        self.attendance = attendance
    }

    /// `texts`：その話者の発話（長いものから最大 `maxTexts` 件が使われる）。出席者がいない・使える発話が無いときは、空。
    public func hints(for texts: [String]) async throws -> [SpeakerHint] {
        let others = attendance.present(list.others)
        guard !others.isEmpty else { return [] }
        var sums = [Double](repeating: 0, count: others.count)
        var used = 0
        var introduced: [Int: Int] = [:]
        let usable = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= Self.minimumLength }.prefix(Self.maxTexts)
        for text in usable {
            let found = Self.mentions(of: others, in: text)
            if found.introduced.count == 1, let only = found.introduced.first {
                introduced[only, default: 0] += 1
                continue
            }
            let indices = others.indices.filter { !found.mentioned.contains($0) }
            guard !indices.isEmpty else { continue }
            let candidates = indices.map { others[$0] }
            let answer = try await judge.judge(utterance: text, candidates: candidates)
            guard answer.probabilities.count == candidates.count, answer.filler < Self.fillerLimit else { continue }
            for (offset, index) in indices.enumerated() { sums[index] += answer.probabilities[offset] }
            used += 1
        }
        let named = introduced.sorted { $0.value != $1.value ? $0.value > $1.value : others[$0.key].name < others[$1.key].name }
            .map { SpeakerHint(name: others[$0.key].name, probability: nil, introduced: true) }
        guard used > 0 else { return named }
        let ranked = others.indices.map { (index: $0, average: sums[$0] / Double(used)) }
            .sorted { $0.average != $1.average ? $0.average > $1.average : others[$0.index].name < others[$1.index].name }
            .prefix(Self.topCount)
            .map { SpeakerHint(name: others[$0.index].name, probability: $0.average, introduced: false) }
        return named + ranked
    }

    private static let introductions = ["です", "と申します", "といいます", "と言います", "でございます"]

    /// 発言に名前が出た人（`others` の位置）。`introduced`：名乗り（「山田です」）だけで出てきた人。`mentioned`：呼びかけ・言及で出た人（名乗りだけの人は含まない）。
    /// 2 人以上に共通の語（同じ姓など）は、誰のことか決まらないので、使わない。
    static func mentions(of actors: [Actor], in text: String) -> (mentioned: Set<Int>, introduced: Set<Int>) {
        var owners: [String: Set<Int>] = [:]
        for (index, actor) in actors.enumerated() {
            for term in actor.mentionTerms { owners[term.lowercased(), default: []].insert(index) }
        }
        var mentioned = Set<Int>(), introduced = Set<Int>()
        let lowered = text.lowercased()
        for (term, who) in owners where who.count == 1 {
            guard let index = who.first else { continue }
            let honorific = Actor.honorifics.contains { term.hasSuffix($0) }
            var from = lowered.startIndex
            var plain = false, introducing = false
            while let range = lowered.range(of: term, range: from..<lowered.endIndex) {
                let after = lowered[range.upperBound...]
                if !honorific, introductions.contains(where: { after.hasPrefix($0) }) { introducing = true } else { plain = true }
                from = range.upperBound
            }
            if plain { mentioned.insert(index) } else if introducing { introduced.insert(index) }
        }
        // 呼びかけ・言及と、名乗りの両方に出る人は、言及を優先する（名乗りだけで決めない）。
        introduced.subtract(mentioned)
        return (mentioned, introduced)
    }
}
