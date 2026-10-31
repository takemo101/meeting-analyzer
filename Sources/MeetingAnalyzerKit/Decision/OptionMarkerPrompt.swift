import Foundation

/// 「状態・問い・選択肢」を、判断モデル（Tiny-Jev）が読むトークン列にする。選択肢ごとに、印（`<opt>`）を置き、その直前のトークンの位置が、採点の位置になる。
/// Tiny-Jev の `modeling_tiny_jev.py`（`encode`）と、同じ組み立て・同じ切り詰め（状態の先頭 7 割と末尾を残す）。
struct OptionMarkerPrompt {
    /// 選択肢の最後に付ける言葉（モデルの設定 `cue`）。
    static let cue = " - correct?"
    /// 選択肢の最大数（グラフの出力の幅）。
    static let maxOptions = 32

    let encode: (String) throws -> [Int]
    let optionTokenId: Int
    /// 入力の長さの上限（トークン）。
    let maxLength: Int

    struct Rendered: Equatable {
        let ids: [Int]
        let positions: [Int]
    }

    /// 問いと選択肢だけを入れたときの長さ（発言を入れる前。選択肢が多すぎれば `inputTooLong`）。段（入力の長さ）を選ぶのに使う。
    func fixedLength(question: String, options: [String]) throws -> Int {
        guard !options.isEmpty, options.count <= Self.maxOptions else { throw DecisionModelError.inputTooLong }
        let pre = try encode("<state>\n"), post = try encode("</options>")
        let mid = try encode("\n</state>\n<question>\n" + question + "\n</question>\n<options>\n")
        let newline = try encode("\n")
        let opts = try options.map { try encode($0 + Self.cue).count + 1 + newline.count }
        return pre.count + mid.count + opts.reduce(0, +) + post.count
    }

    func render(state: String, question: String, options: [String]) throws -> Rendered {
        guard !options.isEmpty, options.count <= Self.maxOptions else { throw DecisionModelError.inputTooLong }
        let pre = try encode("<state>\n")
        let mid = try encode("\n</state>\n<question>\n" + question + "\n</question>\n<options>\n")
        let newline = try encode("\n")
        let opts = try options.map { try encode($0 + Self.cue) + [optionTokenId] + newline }
        let post = try encode("</options>")
        let budget = maxLength - (pre.count + mid.count + opts.reduce(0) { $0 + $1.count } + post.count)
        guard budget >= 0 else { throw DecisionModelError.inputTooLong }
        var st = try encode(state)
        if st.count > budget {
            let head = Int(Double(budget) * 0.7)
            st = budget > 0 ? Array(st[..<head]) + Array(st[(st.count - (budget - head))...]) : []
        }
        var ids = pre + st + mid
        var positions: [Int] = []
        for o in opts {
            positions.append(ids.count + o.count - 3)   // 印の直前のトークン
            ids += o
        }
        return Rendered(ids: ids + post, positions: positions)
    }
}
