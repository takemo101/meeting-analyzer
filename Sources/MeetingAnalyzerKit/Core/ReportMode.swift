import Foundation

/// 会議のあとに作る資料（SPEC §3.11）。開始の前に、メニューで選ぶ。
public enum ReportMode: String, CaseIterable, Sendable {
    /// 作らない（既定）。画面の画像は、セッションの終了で消す。
    case off
    /// PDF を作る（記録・画面・エージェントのサマリー）。画面の画像は、資料のために、記録の下へ残す。
    case pdf

    public var title: String {
        switch self {
        case .off: return "なし"
        case .pdf: return "PDF（記録・画面・サマリー）"
        }
    }

    /// 資料のために残す画像の上限（それより古いものは消す）。
    public var screenshotLimit: Int { self == .pdf ? 120 : 30 }
}
