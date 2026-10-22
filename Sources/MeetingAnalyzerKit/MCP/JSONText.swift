import Foundation

/// JSON の文章を、**書式を保ったまま**（他のキー・並び・インデントはそのまま）、オブジェクトの中のメンバーを 1 つ足す・置き換える。
/// エージェントの設定ファイル（利用者が手で整えていることがある）へ、MCP サーバーを登録するのに使う。
/// コメントを含む JSON（JSONC）や、読めない形は、安全に編集できないので、`nil` を返す（呼び出し側が、手で足す案内を出す）。
public enum JSONText {
    /// `container`（ルートのオブジェクトのキー）の中の `key` に、`valueJSON` を設定した文章。`container` が無ければ作る。空・ルートが無い文章は、新しく作る。
    public static func setMember(in text: String, container: String, key: String, valueJSON: String) -> String? {
        let bytes = Array(text.utf8)
        guard let rootStart = firstNonSpace(bytes, 0) else {
            return "{\n  \(quote(container)): {\n    \(quote(key)): \(valueJSON)\n  }\n}\n"
        }
        guard bytes[rootStart] == UInt8(ascii: "{"), let root = members(bytes, objectStart: rootStart) else { return nil }
        var result: [UInt8]
        if let containerMember = root.members.first(where: { $0.key == container }) {
            guard bytes[containerMember.valueStart] == UInt8(ascii: "{"), let inner = members(bytes, objectStart: containerMember.valueStart) else { return nil }
            if let member = inner.members.first(where: { $0.key == key }) {
                result = Array(bytes[..<member.valueStart]) + Array(valueJSON.utf8) + Array(bytes[member.valueEnd...])
            } else {
                result = insert(member: "\(quote(key)): \(valueJSON)", into: bytes, object: inner, defaultIndent: indent(of: containerMember, in: bytes) + "  ")
            }
        } else {
            let value = "{\n\(indentUnit(root, bytes))\(indentUnit(root, bytes))\(quote(key)): \(valueJSON)\n\(indentUnit(root, bytes))}"
            result = insert(member: "\(quote(container)): \(value)", into: bytes, object: root, defaultIndent: "  ")
        }
        guard let output = String(bytes: result, encoding: .utf8), valid(output, container: container, key: key, valueJSON: valueJSON) else { return nil }
        return output
    }

    /// `container` の中の `key` の値（JSON として読めたもの）。無ければ `nil`。
    public static func member(in text: String, container: String, key: String) -> Any? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
        return (object[container] as? [String: Any])?[key]
    }

    // MARK: 内部

    private struct Member { let key: String; let valueStart: Int; let valueEnd: Int; let keyStart: Int }
    private struct ObjectInfo { let open: Int; let close: Int; let members: [Member] }

    private static func quote(_ text: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\(text)\""
    }

    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }

    private static func firstNonSpace(_ bytes: [UInt8], _ from: Int) -> Int? {
        var i = from
        while i < bytes.count, isSpace(bytes[i]) { i += 1 }
        return i < bytes.count ? i : nil
    }

    /// 文字列の終わり（閉じの引用符の次）。
    private static func skipString(_ bytes: [UInt8], _ start: Int) -> Int? {
        var i = start + 1
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "\\") { i += 2; continue }
            if bytes[i] == UInt8(ascii: "\"") { return i + 1 }
            i += 1
        }
        return nil
    }

    /// 値の終わり（次の文字の位置）。コメントがあれば `nil`。
    private static func skipValue(_ bytes: [UInt8], _ start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        switch bytes[start] {
        case UInt8(ascii: "\""): return skipString(bytes, start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0, i = start
            while i < bytes.count {
                let b = bytes[i]
                if b == UInt8(ascii: "\"") { guard let end = skipString(bytes, i) else { return nil }; i = end; continue }
                if b == UInt8(ascii: "/") { return nil }
                if b == UInt8(ascii: "{") || b == UInt8(ascii: "[") { depth += 1 }
                if b == UInt8(ascii: "}") || b == UInt8(ascii: "]") { depth -= 1; if depth == 0 { return i + 1 } }
                i += 1
            }
            return nil
        default:
            var i = start
            while i < bytes.count, bytes[i] != UInt8(ascii: ","), bytes[i] != UInt8(ascii: "}"), bytes[i] != UInt8(ascii: "]"), !isSpace(bytes[i]) {
                if bytes[i] == UInt8(ascii: "/") { return nil }
                i += 1
            }
            return i
        }
    }

    private static func members(_ bytes: [UInt8], objectStart open: Int) -> ObjectInfo? {
        var found: [Member] = []
        var i = open + 1
        while true {
            while i < bytes.count, isSpace(bytes[i]) || bytes[i] == UInt8(ascii: ",") { i += 1 }
            guard i < bytes.count else { return nil }
            if bytes[i] == UInt8(ascii: "}") { return ObjectInfo(open: open, close: i, members: found) }
            guard bytes[i] == UInt8(ascii: "\""), let keyEnd = skipString(bytes, i) else { return nil }
            let keyStart = i
            let key = String(bytes: bytes[(i + 1)..<(keyEnd - 1)], encoding: .utf8) ?? ""
            i = keyEnd
            while i < bytes.count, isSpace(bytes[i]) { i += 1 }
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
            i += 1
            while i < bytes.count, isSpace(bytes[i]) { i += 1 }
            guard let end = skipValue(bytes, i) else { return nil }
            found.append(Member(key: key, valueStart: i, valueEnd: end, keyStart: keyStart))
            i = end
        }
    }

    /// そのメンバーの行の、先頭の空白。
    private static func indent(of member: Member, in bytes: [UInt8]) -> String {
        var i = member.keyStart
        while i > 0, bytes[i - 1] != 0x0A { i -= 1 }
        let line = bytes[i..<member.keyStart]
        return line.allSatisfy { $0 == 0x20 || $0 == 0x09 } ? String(bytes: line, encoding: .utf8) ?? "  " : "  "
    }

    private static func indentUnit(_ object: ObjectInfo, _ bytes: [UInt8]) -> String {
        object.members.first.map { indent(of: $0, in: bytes) } ?? "  "
    }

    private static func insert(member: String, into bytes: [UInt8], object: ObjectInfo, defaultIndent: String) -> [UInt8] {
        let pad = object.members.first.map { indent(of: $0, in: bytes) } ?? defaultIndent
        let text: String
        if object.members.isEmpty {
            // 空のオブジェクト（`{}` や `{ }`）：中身だけを入れ替える。
            text = "\n\(pad)\(member)\n\(String(pad.dropLast(2)))"
            return Array(bytes[...object.open]) + Array(text.utf8) + Array(bytes[object.close...])
        }
        text = "\n\(pad)\(member),"
        return Array(bytes[...object.open]) + Array(text.utf8) + Array(bytes[(object.open + 1)...])
    }

    /// 編集した結果が、JSON として読め、足した値が、意図したものか。
    private static func valid(_ output: String, container: String, key: String, valueJSON: String) -> Bool {
        guard let got = member(in: output, container: container, key: key),
              let want = try? JSONSerialization.jsonObject(with: Data(valueJSON.utf8), options: [.fragmentsAllowed]) else { return false }
        return (got as AnyObject).isEqual(want)
    }
}
