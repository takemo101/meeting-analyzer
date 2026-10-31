import Foundation

/// 判断モデルを読み込めない・動かせない理由（SPEC §3.13）。
public enum DecisionModelError: Error, Equatable, Sendable {
    /// ファイルを読めない・形が想定と違う（壊れている・版が違う）。
    case unreadable(String)
    /// この Mac の GPU（Metal）を使えない。
    case noGPU
    /// 入力が長すぎて、選択肢だけで、上限を超える。
    case inputTooLong
    /// 実行の途中で失敗した。
    case failed(String)

    /// 利用者に見せる文（原因。会議の本文は含めない）。
    public var message: String {
        switch self {
        case .unreadable(let reason): return reason
        case .noGPU: return "この Mac の GPU（Metal）を使えません"
        case .inputTooLong: return "アクターの人数・説明が、判断モデルの入力に収まりません（ACTOR.md の人数を減らすか、説明を短くしてください）"
        case .failed(let reason): return reason
        }
    }
}
