import Foundation
import Testing
@testable import MeetingAnalyzerKit

@Suite("OptionMarkerPrompt：選択肢の印の位置と、長い入力の切り詰め")
struct OptionMarkerPromptTests {
    private let marker = 9_999
    /// 1 文字 = 1 トークン（偽のトークナイザ）。
    private func prompt(maxLength: Int) -> OptionMarkerPrompt {
        OptionMarkerPrompt(encode: { $0.unicodeScalars.map { Int($0.value) } }, optionTokenId: marker, maxLength: maxLength)
    }

    @Test("各選択肢の位置は、印（<opt>）の直前のトークン。選択肢は、書いた順")
    func positionsPrecedeMarkers() throws {
        let r = try prompt(maxLength: 400).render(state: "請求書の件です", question: "誰か", options: ["a: 営業", "b: 経理", "c: QA"])
        #expect(r.positions.count == 3)
        for position in r.positions { #expect(r.ids[position + 1] == marker) }
        #expect(r.ids.filter { $0 == marker }.count == 3)
        #expect(zip(r.positions, r.positions.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("上限を超える状態は、先頭の 7 割と末尾を残して切り詰め、ちょうど上限に収める。選択肢だけで上限を超えるときと、多すぎる選択肢は、断る")
    func truncation() throws {
        let long = String(repeating: "あ", count: 200) + "ここが末尾"
        let p = prompt(maxLength: 120)
        let r = try p.render(state: long, question: "q", options: ["x: 1", "y: 2"])
        #expect(r.ids.count == 120)
        let tail = "ここが末尾".unicodeScalars.map { Int($0.value) }
        let at = try #require(r.ids.firstRange(of: tail))
        #expect(at.upperBound <= r.ids.count && at.lowerBound > 0, "末尾の言葉が残る")
        #expect(throws: DecisionModelError.inputTooLong) { try prompt(maxLength: 20).render(state: "s", question: "q", options: ["x: 1", "y: 2"]) }
        #expect(throws: DecisionModelError.inputTooLong) { try prompt(maxLength: 5_000).render(state: "s", question: "q", options: (0...OptionMarkerPrompt.maxOptions).map { "o\($0)" }) }
        #expect(throws: DecisionModelError.inputTooLong) { try prompt(maxLength: 400).render(state: "s", question: "q", options: []) }
    }

    @Test("問いと選択肢だけの長さは、発言を空にして組み立てたものと同じ（段を選ぶ計算が、実際の組み立てとずれない）。選択肢が多すぎる・無いときは、断る")
    func fixedLengthMatchesRender() throws {
        let options = ["佐藤 花子: 営業。話題: 見積もり・商談", "田中 美咲: 経理", "鈴木 一郎"]
        let p = prompt(maxLength: 5_000)
        #expect(try p.fixedLength(question: "誰か", options: options) == p.render(state: "", question: "誰か", options: options).ids.count)
        #expect(try p.fixedLength(question: "誰か", options: options + ["もう 1 人"]) > p.fixedLength(question: "誰か", options: options), "選択肢が増えると、長くなる")
        #expect(throws: DecisionModelError.inputTooLong) { try p.fixedLength(question: "q", options: []) }
        #expect(throws: DecisionModelError.inputTooLong) { try p.fixedLength(question: "q", options: (0...OptionMarkerPrompt.maxOptions).map { "o\($0)" }) }
    }

    @Test("入力の長さの段：発言の分を取っておいて、収まる最小の段を選ぶ。最大の段でも収まらなければ、無し")
    func lengthTier() {
        let reserve = SystemOneJudge.utteranceReserve
        #expect(SystemOneJudge.tier(forFixedLength: 0) == 512, "候補が少なければ、標準の段（いまの速さを保つ）")
        #expect(SystemOneJudge.tier(forFixedLength: 512 - reserve) == 512)
        #expect(SystemOneJudge.tier(forFixedLength: 512 - reserve + 1) == 1024)
        #expect(SystemOneJudge.tier(forFixedLength: 2048 - reserve) == 2048)
        #expect(SystemOneJudge.tier(forFixedLength: 2048 - reserve + 1) == nil)
    }
}

@Suite("BPETokenizer：バイトレベルの BPE（合成した小さな tokenizer.json）")
struct BPETokenizerTests {
    /// 256 バイトの文字（GPT-2 の対応）を語彙に持ち、「ab」「abc」の結合と、追加トークン `<opt>` を持つ。
    private func makeTokenizer() throws -> BPETokenizer {
        var bs = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) { bs.append(b); cs.append(256 + n); n += 1 }
        var vocab: [String: Int] = [:]
        for (i, c) in cs.enumerated() { vocab[String(UnicodeScalar(c)!)] = i }
        vocab["ab"] = 300; vocab["abc"] = 301
        let json: [String: Any] = [
            "model": ["vocab": vocab, "merges": ["a b", "ab c"]],
            "added_tokens": [["id": 400, "content": "<opt>", "special": true]],
            "pre_tokenizer": ["type": "Sequence", "pretokenizers": [["type": "Split", "pattern": ["Regex": "\\s+(?!\\S)|\\s+|\\p{L}+|\\p{N}|[^\\s\\p{L}\\p{N}]+"]]]],
        ]
        let url = tempURL("tokenizer", ext: "json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return try BPETokenizer(tokenizerJSON: url)
    }

    @Test("結合の順位どおりに結合し、追加トークンは 1 つの ID になる。分解した文字（NFD）は、正規化して、合成した文字と同じ ID")
    func mergesSpecialsAndNormalization() throws {
        let tok = try makeTokenizer()
        #expect(try tok.encode("abc") == [301])
        #expect(try tok.encode("ab") == [300])
        #expect(try tok.encode("x<opt>y").count == 3 && (try tok.encode("x<opt>y"))[1] == 400)
        #expect(try tok.encode("e\u{301}") == tok.encode("\u{e9}"))
        #expect(try tok.encode("日本語").count > 3, "日本語は、バイト単位の語になる")
        #expect(tok.tokenId("<opt>") == 400)
    }

    @Test("読めないトークナイザは、理由つきで断る")
    func rejectsBrokenFile() throws {
        let url = tempURL("tokenizer-bad", ext: "json")
        try Data("{\"model\": {}}".utf8).write(to: url)
        #expect(throws: DecisionModelError.self) { try BPETokenizer(tokenizerJSON: url) }
    }
}

@Suite("判断モデルの保管：重みとトークナイザが、そろってはじめて「取得済み」")
struct DecisionModelStoreTests {
    private func model(_ weightBytes: Int, _ tokenizerBytes: Int) -> DecisionModel {
        func artifact(_ name: String, _ bytes: Int) -> ModelArtifact { ModelArtifact(repository: "x/y", revision: String(repeating: "a", count: 40), filename: name, bytes: Int64(bytes), sha256: String(repeating: "0", count: 64)) }
        return DecisionModel(
            id: "tiny-test", name: "テスト", summary: "", weights: artifact("w.safetensors", weightBytes), tokenizer: artifact("t.json", tokenizerBytes),
            architecture: .qwenOptionMarker(QwenShape(hidden: 1, layers: 1, heads: 1, kvHeads: 1, headDim: 1, intermediate: 1, rmsEps: 1e-6, ropeTheta: 1, temperature: 1)))
    }

    @Test("片方だけでは、取得済みにならない。削除は、両方を消す")
    func needsBothFiles() throws {
        let store = ModelStore(root: tempURL("decision-store"))
        try store.prepareDirectory()
        let m = model(8, 4)
        #expect(m.bytes == 12 && m.artifacts.map(\.filename) == ["t.json", "w.safetensors"], "小さいトークナイザが先")
        try Data(count: 4).write(to: store.fileURL(m.tokenizer)); store.markVerified(m.tokenizer)
        #expect(!store.isInstalled(m) && store.downloadedBytes(m) == 4)
        try Data(count: 8).write(to: store.fileURL(m.weights)); store.markVerified(m.weights)
        #expect(store.isInstalled(m) && store.downloadedBytes(m) == 12)
        store.delete(m)
        #expect(!store.isInstalled(m) && store.downloadedBytes(m) == 0)
    }

    @Test("一覧の ID は、文字起こしのモデルの ID と重ならない（models download <ID> で、どちらか決まる）。取得先は、版を固定している")
    func catalogInvariants() {
        let ids = LocalModelCatalog.all.map(\.id) + DecisionModelCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for m in DecisionModelCatalog.all {
            #expect(m.artifacts.allSatisfy { $0.revision.count == 40 && $0.sha256.count == 64 && $0.bytes > 0 })
            #expect(m.weights != m.tokenizer)
        }
    }

    /// 大きさだけ合う、中身が空の（疎な）ファイル。大きなモデルの保管を、試験で再現するため。
    private func sparseFile(_ url: URL, bytes: Int64) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
    }

    @Test("2 つの判断モデルが、同じトークナイザのファイルを使うとき、片方を消しても、もう一方が使っているあいだは、トークナイザを残す。最後の 1 つを消すと、消える")
    func sharedTokenizerSurvives() throws {
        let small = try #require(DecisionModelCatalog.model(id: "tiny-jev-0.6b")), large = try #require(DecisionModelCatalog.model(id: "tiny-jev-1.7b"))
        #expect(small.tokenizer.sha256 == large.tokenizer.sha256, "同じファイルなので、保管の場所も同じ")
        let store = ModelStore(root: tempURL("shared-tokenizer"))
        try store.prepareDirectory()
        for m in [small, large] {
            for a in m.artifacts { try sparseFile(store.fileURL(a), bytes: a.bytes); store.markVerified(a) }
        }
        #expect(store.isInstalled(small) && store.isInstalled(large))
        store.delete(small)
        #expect(!store.isInstalled(small.weights) && store.isInstalled(large), "大きいほうは、そのまま使える")
        store.delete(large)
        #expect(!store.isInstalled(large.tokenizer), "最後の 1 つを消すと、トークナイザも消える")
        try? FileManager.default.removeItem(at: store.directory)
    }
}

@Suite("CLI：判断モデルの models")
struct DecisionCommandTests {
    @Test("models download/delete は、判断モデルの ID も受ける。知らない ID は、使い方の誤り")
    func parses() {
        #expect(CommandParser.parse(["models", "download", "tiny-jev-0.6b"]) == .success(.models(.download(id: "tiny-jev-0.6b"))))
        #expect(CommandParser.parse(["models", "delete", "tiny-jev-0.6b"]) == .success(.models(.delete(id: "tiny-jev-0.6b"))))
        guard case .failure(.usage) = CommandParser.parse(["models", "download", "nope"]) else { Issue.record("知らない ID を断らない"); return }
    }
}
