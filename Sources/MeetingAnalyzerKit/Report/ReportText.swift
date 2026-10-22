import CoreGraphics
import CoreText
import Foundation

/// 資料の本文の書式。サマリー（エージェントが書く、簡単な Markdown）を、CoreText の属性つき文字列にする。
/// 対応する書式：見出し（`#`〜`###`）、箇条書き（`-`・`*`・`•`）、番号つきの列挙（`1.`）、引用（`>`）、太字（`**`）。表・コードブロックなどは、そのまま文字として出す。
enum ReportText {
    static let regular = "HiraginoSans-W3"
    static let bold = "HiraginoSans-W6"

    static let ink = CGColor(gray: 0.1, alpha: 1)
    static let muted = CGColor(gray: 0.42, alpha: 1)
    static let accent = CGColor(red: 0.1, green: 0.35, blue: 0.75, alpha: 1)

    static func font(_ name: String, _ size: CGFloat) -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }

    static func style(spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 0, head: CGFloat = 0, first: CGFloat? = nil, lineSpacing: CGFloat = 2.5) -> CTParagraphStyle {
        var before = spacingBefore, after = spacingAfter, headIndent = head, firstIndent = first ?? head, extra = lineSpacing
        return withUnsafePointer(to: &before) { b in
            withUnsafePointer(to: &after) { a in
                withUnsafePointer(to: &headIndent) { h in
                    withUnsafePointer(to: &firstIndent) { f in
                        withUnsafePointer(to: &extra) { l in
                            let settings = [
                                CTParagraphStyleSetting(spec: .paragraphSpacingBefore, valueSize: MemoryLayout<CGFloat>.size, value: b),
                                CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: MemoryLayout<CGFloat>.size, value: a),
                                CTParagraphStyleSetting(spec: .headIndent, valueSize: MemoryLayout<CGFloat>.size, value: h),
                                CTParagraphStyleSetting(spec: .firstLineHeadIndent, valueSize: MemoryLayout<CGFloat>.size, value: f),
                                CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: l),
                            ]
                            return CTParagraphStyleCreate(settings, settings.count)
                        }
                    }
                }
            }
        }
    }

    static func attributes(font: CTFont, color: CGColor, style: CTParagraphStyle) -> [NSAttributedString.Key: Any] {
        [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        ]
    }

    /// 1 つの段落（末尾に改行つき）。`**太字**` を、太字の連なりにする。
    static func paragraph(_ text: String, size: CGFloat, color: CGColor = ink, boldAll: Bool = false, style: CTParagraphStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var isBold = false
        for (index, piece) in text.components(separatedBy: "**").enumerated() {
            if index > 0 { isBold.toggle() }
            guard !piece.isEmpty else { continue }
            result.append(NSAttributedString(string: piece, attributes: attributes(font: font(isBold || boldAll ? bold : regular, size), color: color, style: style)))
        }
        if result.length == 0 { result.append(NSAttributedString(string: "", attributes: attributes(font: font(regular, size), color: color, style: style))) }
        result.append(NSAttributedString(string: "\n", attributes: attributes(font: font(regular, size), color: color, style: style)))
        return result
    }

    /// `![説明](ファイル名)` だけの行（参考の画面）。ファイル名は、パスの末尾だけを見る。
    static func imageReference(_ line: String) -> (alt: String, name: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("!["), trimmed.hasSuffix(")"), let close = trimmed.range(of: "](") else { return nil }
        let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close.lowerBound])
        let target = String(trimmed[close.upperBound..<trimmed.index(before: trimmed.endIndex)])
        let name = URL(fileURLWithPath: target).lastPathComponent
        return name.isEmpty ? nil : (alt.trimmingCharacters(in: .whitespaces), name)
    }

    /// サマリーが参考として載せる画像のファイル名。
    static func imageNames(in markdown: String) -> Set<String> {
        Set(markdown.components(separatedBy: "\n").compactMap { imageReference($0)?.name })
    }

    /// サマリー（Markdown）を、本文にする。
    static func summary(_ markdown: String, size: CGFloat = 10.5) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                result.append(paragraph("", size: size * 0.5, style: style()))
            } else if let heading = headingLevel(line) {
                let sizes: [CGFloat] = [0, 15, 13, 11.5]
                result.append(paragraph(String(line.dropFirst(heading.level + 1)), size: sizes[heading.level], color: accent, boldAll: true, style: style(spacingBefore: 8, spacingAfter: 3)))
            } else if let rest = bullet(line) {
                result.append(paragraph("•  " + rest, size: size, style: style(head: 16, first: 4)))
            } else if let numbered = numbered(line) {
                result.append(paragraph(numbered, size: size, style: style(head: 18, first: 4)))
            } else if line.hasPrefix(">") {
                result.append(paragraph(String(line.dropFirst()).trimmingCharacters(in: .whitespaces), size: size, color: muted, style: style(head: 14, first: 14)))
            } else {
                result.append(paragraph(line, size: size, style: style(spacingAfter: 2)))
            }
        }
        return result
    }

    private static func headingLevel(_ line: String) -> (level: Int, Void)? {
        for level in [3, 2, 1] where line.hasPrefix(String(repeating: "#", count: level) + " ") { return (level, ()) }
        return nil
    }

    private static func bullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "• ", "・"] where line.hasPrefix(marker) { return String(line.dropFirst(marker.count)) }
        return nil
    }

    private static func numbered(_ line: String) -> String? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return "\(digits).  " + rest.dropFirst(2)
    }
}
