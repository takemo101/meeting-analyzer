import Foundation
import Testing
@testable import MeetingAnalyzerKit

@Suite("JSONText: 設定ファイルの書式を保った、メンバーの追加・置き換え")
struct JSONTextTests {
    private let entry = #"{"type":"local","command":["/x/y","mcp"],"enabled":true}"#

    private func parsed(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private let existing = """
    {
        "$schema": "https://opencode.ai/config.json",
        "model": "a/b",
        "mcp": {
            "deepwiki": {"type": "remote", "url": "https://mcp.deepwiki.com/mcp"},
            "mikan": {
                "type": "local",
                "command": ["mikan", "mcp"]
            }
        },
        "plugin": ["x"]
    }
    """

    @Test("既存のコンテナへ足す：他のキー・並び・インデントはそのまま、足した値だけ増える")
    func addsIntoExisting() throws {
        let result = try #require(JSONText.setMember(in: existing, container: "mcp", key: "meeting-analyzer", valueJSON: entry))
        // 元の文章の、足した行より前後が、そのまま残っている。
        #expect(result.contains("    \"$schema\": \"https://opencode.ai/config.json\",\n    \"model\": \"a/b\","))
        #expect(result.contains("        \"mikan\": {\n            \"type\": \"local\",\n            \"command\": [\"mikan\", \"mcp\"]\n        }\n    },\n    \"plugin\": [\"x\"]"))
        let object = try parsed(result)
        #expect(Set((object["mcp"] as? [String: Any])?.keys.map { $0 } ?? []) == ["deepwiki", "mikan", "meeting-analyzer"])
        #expect(object["plugin"] as? [String] == ["x"])
        #expect(result.range(of: "\"meeting-analyzer\"")!.lowerBound < result.range(of: "\"deepwiki\"")!.lowerBound, "足したメンバーは、先頭に入る")
    }

    @Test("同じキーがあれば、その値だけを置き換える（周りは、そのまま）")
    func replaces() throws {
        let with = existing.replacingOccurrences(of: "\"plugin\"", with: "\"meeting-analyzer\": 1,\n        \"plugin\"")
        let text = with.replacingOccurrences(of: "\"mcp\": {", with: "\"mcp\": {\n            \"meeting-analyzer\": {\"type\": \"local\", \"command\": [\"/old\", \"mcp\"]},")
        let result = try #require(JSONText.setMember(in: text, container: "mcp", key: "meeting-analyzer", valueJSON: entry))
        let mcp = try #require(try parsed(result)["mcp"] as? [String: Any])
        #expect((mcp["meeting-analyzer"] as? [String: Any])?["command"] as? [String] == ["/x/y", "mcp"])
        #expect(mcp.count == 3)
        #expect(result.contains("\"meeting-analyzer\": 1"), "別の階層の、同じ名前のキーには、触らない")
    }

    @Test("コンテナが無ければ作る。空のオブジェクトや、空のコンテナでも壊れない")
    func createsContainer() throws {
        for text in ["{}", "{ }", "{\n}\n", "{\"mcp\": {}}", "{\n  \"mcp\": {\n  }\n}", "{\"a\": 1}"] {
            let result = try #require(JSONText.setMember(in: text, container: "mcp", key: "meeting-analyzer", valueJSON: entry), "\(text)")
            let object = try parsed(result)
            #expect(((object["mcp"] as? [String: Any])?["meeting-analyzer"] as? [String: Any])?["enabled"] as? Bool == true, "\(text)")
        }
        let kept = try #require(JSONText.setMember(in: "{\"a\": 1}", container: "mcp", key: "k", valueJSON: "{}"))
        #expect(try parsed(kept)["a"] as? Int == 1)
    }

    @Test("空・空白だけのファイルは、新しく作る")
    func emptyFile() throws {
        for text in ["", "  \n"] {
            let result = try #require(JSONText.setMember(in: text, container: "mcpServers", key: "meeting-analyzer", valueJSON: #"{"command":"/x","args":["mcp"]}"#))
            #expect(JSONText.member(in: result, container: "mcpServers", key: "meeting-analyzer") != nil)
        }
    }

    @Test("文字列の中の括弧・引用符・エスケープ・日本語があっても、正しく読み飛ばす")
    func trickyStrings() throws {
        let text = """
        {"note": "} { \\" ] [ // /* あいう", "mcp": {"a": "}}\\\\", "b": ["]", {"c": "\\"}"}]}, "z": 1}
        """
        let result = try #require(JSONText.setMember(in: text, container: "mcp", key: "meeting-analyzer", valueJSON: entry))
        let object = try parsed(result)
        #expect(object["note"] as? String == "} { \" ] [ // /* あいう")
        #expect(object["z"] as? Int == 1)
        #expect((object["mcp"] as? [String: Any])?.keys.contains("meeting-analyzer") == true)
    }

    @Test("コメントを含む JSON・読めない形・オブジェクトでないルートは、編集しない（nil）")
    func refusesUnsafe() {
        #expect(JSONText.setMember(in: "{\n  // comment\n  \"mcp\": {}\n}", container: "mcp", key: "k", valueJSON: "1") == nil)
        #expect(JSONText.setMember(in: "{\"mcp\": {} /* c */}", container: "mcp", key: "k", valueJSON: "1") == nil)
        #expect(JSONText.setMember(in: "{\"mcp\": ", container: "mcp", key: "k", valueJSON: "1") == nil)
        #expect(JSONText.setMember(in: "[1, 2]", container: "mcp", key: "k", valueJSON: "1") == nil)
        #expect(JSONText.setMember(in: "{\"mcp\": [1]}", container: "mcp", key: "k", valueJSON: "1") == nil, "コンテナが、オブジェクトでない")
    }

    @Test("member は、読めた値を返す。無ければ nil")
    func member() {
        #expect(JSONText.member(in: existing, container: "mcp", key: "mikan") != nil)
        #expect(JSONText.member(in: existing, container: "mcp", key: "none") == nil)
        #expect(JSONText.member(in: "not json", container: "mcp", key: "x") == nil)
    }
}
