import Foundation

/// 端末への見せ方の部品。色は、端末（TTY）へ出すときだけ、かつ、`NO_COLOR` が無く、`TERM` が dumb でないときだけ付ける
/// （パイプ・ファイルへ出す文字列に、エスケープシーケンスを混ぜない）。
public struct TerminalStyle: Sendable, Equatable {
    public let color: Bool

    public init(color: Bool) { self.color = color }

    public static let plain = TerminalStyle(color: false)

    public static func detect(isTerminal: Bool, environment: [String: String]) -> TerminalStyle {
        let noColor = !(environment["NO_COLOR"] ?? "").isEmpty
        return TerminalStyle(color: isTerminal && !noColor && environment["TERM"] != "dumb")
    }

    private func paint(_ text: String, _ code: String) -> String { color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }

    func bold(_ text: String) -> String { paint(text, "1") }
    func dim(_ text: String) -> String { paint(text, "2") }
    func red(_ text: String) -> String { paint(text, "31") }
    func green(_ text: String) -> String { paint(text, "32") }
    func yellow(_ text: String) -> String { paint(text, "33") }
    func cyan(_ text: String) -> String { paint(text, "36") }

    func success(_ text: String) -> String { green("✔") + " " + text }
    func warning(_ text: String) -> String { yellow("!") + " " + text }
    func failure(_ text: String) -> String { red("✖") + " " + text }

    /// 画面上の幅（全角・絵文字は 2 桁）。色のエスケープは数えない（付ける前の文字列で測る）。
    static func displayWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF:
            return true
        default:
            return false
        }
    }

    /// 画面上の幅 `width` になるよう、右へ空白を足す（日本語を含む表の桁を揃える）。
    static func pad(_ text: String, to width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - displayWidth(text)))
    }

    /// 見出し + 2 桁の字下げの行（見出しは太字）。
    func section(_ title: String, _ lines: [String]) -> [String] {
        [bold(title)] + lines.map { "  " + $0 }
    }

    /// 左に項目名、右に説明の表。説明が複数行なら、2 行目からは項目名の下へ揃える。項目名は `label` で飾れる。
    func table(_ rows: [(name: String, text: [String])], label: (String) -> String = { $0 }) -> [String] {
        let width = rows.map { Self.displayWidth($0.name) }.max() ?? 0
        return rows.flatMap { row -> [String] in
            row.text.enumerated().map { index, line in
                (index == 0 ? label(Self.pad(row.name, to: width)) : String(repeating: " ", count: width)) + "  " + line
            }
        }
    }
}
