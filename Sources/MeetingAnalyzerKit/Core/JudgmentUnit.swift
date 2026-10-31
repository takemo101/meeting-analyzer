import Foundation

/// 話者の判断の単位（SPEC §3.13）。確定した発話（無音で区切られた単位）を、どの大きさで判断するか。
public enum JudgmentUnit: String, CaseIterable, Sendable, Codable {
    /// 発話を**文に分けて、1 文ずつ**判断する。話者が文の途中で入れ替わっていれば、別の発話に分ける。ターンが速く入れ替わる会話に強い（既定）。
    case sentence
    /// 発話を**分けず、まとめて 1 回で**判断する。1 つの確定した発話は、1 人が話したと考える。同じ話者の文が長く続くほど当たり、判断の回数も減る。話者が混ざった発話では、1 人に決めてしまう。
    case utterance

    public static let `default` = JudgmentUnit.sentence

    public var title: String {
        switch self {
        case .sentence: return "文ごとに判断"
        case .utterance: return "発話ごとに判断"
        }
    }
}
