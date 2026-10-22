import Foundation

/// 相手の声が、スピーカーからマイクへ回り込んでいる疑いを、文字起こしの重なりで見つける純粋な規則（SPEC §3.3・A12）。
/// 「あなた」の発話が、直近の「相手」の発話と、ほとんど同じ文字列なら、回り込みを疑う。判断だけで、発話は変えない。
public struct EchoDetector: Sendable {
    /// 「相手」の発話を覚えておく秒数。
    public let window: TimeInterval
    /// 比べるのに必要な、文字の 2 つ組の数の下限（短い相づちの偶然の一致を除く）。
    public let minimumPairs: Int
    /// 重なりの割合（共通の組の数 ÷ 短いほうの組の数）がこの値以上なら、疑う。
    public let threshold: Double

    private struct Entry {
        var time: TimeInterval
        var pairs: [String: Int]
        var count: Int
    }

    private var others: [String: Entry] = [:]

    public init(window: TimeInterval = 10, minimumPairs: Int = 6, threshold: Double = 0.7) {
        self.window = window
        self.minimumPairs = minimumPairs
        self.threshold = threshold
    }

    /// 発話の更新を 1 つ見る。「相手」なら覚え（同じ `key` は、最新の本文で置き換える）、「あなた」なら、回り込みを疑うかを返す。
    public mutating func observe(speaker: Speaker, key: String, text: String, at now: TimeInterval) -> Bool {
        others = others.filter { now - $0.value.time <= window }
        let (pairs, count) = Self.pairs(of: text)
        switch speaker {
        case .others:
            others[key] = Entry(time: now, pairs: pairs, count: count)
            return false
        case .you:
            guard count >= minimumPairs else { return false }
            return others.values.contains { entry in
                guard entry.count >= minimumPairs else { return false }
                var common = 0
                for (pair, n) in pairs { common += min(n, entry.pairs[pair] ?? 0) }
                return Double(common) / Double(min(count, entry.count)) >= threshold
            }
        }
    }

    /// 文字（句読点・空白を除く）の、隣り合う 2 つ組の出現数。
    static func pairs(of text: String) -> ([String: Int], Int) {
        let characters = text.lowercased().filter { $0.isLetter || $0.isNumber }.map(String.init)
        guard characters.count >= 2 else { return ([:], 0) }
        var result: [String: Int] = [:]
        for index in 0..<(characters.count - 1) { result[characters[index] + characters[index + 1], default: 0] += 1 }
        return (result, characters.count - 1)
    }
}
