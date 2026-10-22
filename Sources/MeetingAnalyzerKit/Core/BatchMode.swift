import Foundation

/// エージェントへ渡す「まとめ方」（SPEC §3.6）。開始の前に、メニューで選ぶ。
public enum BatchMode: String, CaseIterable, Sendable {
    /// 発話の区切りごと（既定）。字幕が 1.2 秒静かになったら、または最も古い未送信が 10 秒たったら。新しい発話の開始でも（3 秒の間隔つき）。
    case utterance
    /// 会話の区切りごと。3 秒静かになったら、または最も古い未送信が 30 秒たったら。発話の切れ目では送らず、話の 1 まとまりを、まとめて渡す。解説・提案に向く。
    case conversation
    /// まとまってから解説。5 秒静かになり、本文が 80 字以上たまったら（途切れなく続くなら 60 秒で）。相づちなどの短い発話だけでは送らない。エージェントを動かす回数を、いちばん減らす。
    case digest
    /// 約 30 秒ごと。
    case every30
    /// 約 5 秒ごと（細かく）。
    case every5

    public var policy: BatchingPolicy {
        switch self {
        case .utterance: return BatchingPolicy()
        case .conversation: return BatchingPolicy(quiet: 3, maxHold: 30, boundaryGap: .infinity)
        case .digest: return BatchingPolicy(quiet: 5, maxHold: 60, boundaryGap: .infinity, minCharacters: 80)
        case .every30: return BatchingPolicy(cadence: 30)
        case .every5: return BatchingPolicy(cadence: 5)
        }
    }

    public var title: String {
        switch self {
        case .utterance: return "発話の区切りごと（1.2 秒静かになったら）"
        case .conversation: return "会話の区切りごと（3 秒静かになったら）"
        case .digest: return "まとまってから解説（5 秒静かになり、一定量たまったら）"
        case .every30: return "約 30 秒ごと"
        case .every5: return "約 5 秒ごと（細かく）"
        }
    }
}
