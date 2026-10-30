import Foundation

/// Qwen2 系のバイトレベル BPE（`tokenizer.json`）。NFC 正規化 → 追加トークンで分割 → 正規表現で分割 → バイト → BPE。
/// Hugging Face のトークナイザと、同じ ID を返す（Tiny-Jev の固定した版で、61 件の文で確認。検証記録）。
final class BPETokenizer {
    private var vocab: [String: Int] = [:]
    private var ranks: [String: Int] = [:]
    private var added: [(content: String, id: Int)] = []
    private let regex: NSRegularExpression
    private var cache: [String: [Int]] = [:]

    /// GPT-2 の、バイト → 見える文字の対応。
    private static let byteToUnicode: [UInt8: Character] = {
        var bs = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) { bs.append(b); cs.append(256 + n); n += 1 }
        var map: [UInt8: Character] = [:]
        for (b, c) in zip(bs, cs) { if let scalar = UnicodeScalar(c) { map[UInt8(b)] = Character(scalar) } }
        return map
    }()

    init(tokenizerJSON url: URL) throws {
        guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any], let vocab = model["vocab"] as? [String: Int], let merges = model["merges"] as? [Any],
              let addedTokens = root["added_tokens"] as? [[String: Any]],
              let pre = (root["pre_tokenizer"] as? [String: Any])?["pretokenizers"] as? [[String: Any]],
              let pattern = ((pre.first?["pattern"] as? [String: Any])?["Regex"]) as? String,
              let regex = try? NSRegularExpression(pattern: pattern) else {
            throw DecisionModelError.unreadable("トークナイザのファイルを読めません")
        }
        self.vocab = vocab
        self.regex = regex
        for (i, m) in merges.enumerated() {
            if let s = m as? String { ranks[s] = i } else if let a = m as? [String], a.count == 2 { ranks[a[0] + " " + a[1]] = i }
        }
        for a in addedTokens {
            guard let content = a["content"] as? String, let id = a["id"] as? Int else { throw DecisionModelError.unreadable("トークナイザの追加トークンを読めません") }
            added.append((content, id))
        }
        added.sort { $0.content.count > $1.content.count }
    }

    func tokenId(_ content: String) -> Int? { added.first { $0.content == content }?.id ?? vocab[content] }

    func encode(_ text: String) throws -> [Int] {
        var ids: [Int] = []
        for piece in splitAdded(text.precomposedStringWithCanonicalMapping) {
            switch piece {
            case .special(let id): ids.append(id)
            case .text(let s): ids += try encodePlain(s)
            }
        }
        return ids
    }

    private enum Piece { case text(String), special(Int) }

    private func splitAdded(_ text: String) -> [Piece] {
        var out: [Piece] = []
        var rest = Substring(text)
        var buffer = ""
        while !rest.isEmpty {
            if let hit = added.first(where: { rest.hasPrefix($0.content) }) {
                if !buffer.isEmpty { out.append(.text(buffer)); buffer = "" }
                out.append(.special(hit.id))
                rest = rest.dropFirst(hit.content.count)
            } else {
                buffer.append(rest.removeFirst())
            }
        }
        if !buffer.isEmpty { out.append(.text(buffer)) }
        return out
    }

    private func encodePlain(_ text: String) throws -> [Int] {
        let ns = text as NSString
        var ids: [Int] = []
        var last = 0
        func word(_ s: String) throws { if !s.isEmpty { ids += try bpe(s) } }
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last { try word(ns.substring(with: NSRange(location: last, length: m.range.location - last))) }
            try word(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        if last < ns.length { try word(ns.substring(from: last)) }
        return ids
    }

    private func bpe(_ word: String) throws -> [Int] {
        if let c = cache[word] { return c }
        var parts: [String] = []
        for byte in word.utf8 {
            guard let ch = Self.byteToUnicode[byte] else { throw DecisionModelError.unreadable("トークナイザの変換に失敗しました") }
            parts.append(String(ch))
        }
        while parts.count > 1 {
            var best = Int.max, at = -1
            for i in 0..<(parts.count - 1) {
                if let r = ranks[parts[i] + " " + parts[i + 1]], r < best { best = r; at = i }
            }
            if at < 0 { break }
            parts.replaceSubrange(at...(at + 1), with: [parts[at] + parts[at + 1]])
        }
        var ids: [Int] = []
        for p in parts {
            guard let id = vocab[p] else { throw DecisionModelError.unreadable("トークナイザの語彙に無い語です") }
            ids.append(id)
        }
        cache[word] = ids
        return ids
    }
}
