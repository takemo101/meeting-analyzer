import Foundation

/// 文字起こしの本文を、文に分ける純粋な規則（SPEC §3.13「発話者の分割」）。文の終わり（「。」「！」「？」「．」「…」と、改行）で切り、終わりの記号・閉じ括弧は、その文に含める。
/// 終わりの記号が無い本文は、1 つの文のまま。連結すると、元の本文（前後の空白を除く）に戻る。
public enum SentenceSplitter {
    private static let terminators: Set<Character> = ["。", "！", "？", "!", "?", "．", "…"]
    private static let closers: Set<Character> = ["」", "』", "）", ")", "］", "]", "”", "’"]

    public static func split(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var closing = false          // 終わりの記号のあと（続く記号・閉じ括弧は、同じ文に入れる）
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { sentences.append(trimmed) }
            current = ""
            closing = false
        }
        for ch in text {
            if ch.isNewline { flush(); continue }
            if closing, !(terminators.contains(ch) || closers.contains(ch)) { flush() }
            current.append(ch)
            if terminators.contains(ch) { closing = true }
        }
        flush()
        return sentences
    }
}
