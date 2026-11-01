import Foundation

/// 会議の題名の規則（SPEC §3.2）。開始の前の設定の画面で、利用者が付ける（任意）。境界（画面の入力）で、一度だけ検査して、使う。
public enum MeetingTitleRule {
    public static let maxLength = 80

    /// 改行・制御文字は空白にし、前後と連続する空白を整え、80 文字までにする。空なら `nil`（自動の題名を使う）。
    public static func normalize(_ raw: String) -> String? {
        let separators = CharacterSet.controlCharacters.union(.whitespacesAndNewlines)
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.map { separators.contains($0) ? " " : $0 }))
        let words = cleaned.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let title = words.joined(separator: " ")
        return title.isEmpty ? nil : String(title.prefix(maxLength))
    }
}
