import Foundation

/// 会話に出てくる人（アクター）1 人。`ACTOR.md` の「## 名前」の節 1 つ（SPEC §3.13）。
public struct Actor: Equatable, Sendable {
    public let name: String
    public let role: String?
    /// 呼ばれ方（「山田さん」「PM」など）。
    public let aliases: [String]
    /// その人が話しそうな話題・担当。
    public let topics: [String]
    /// マイクで話している人（「本人」）か。
    public let isSelf: Bool

    public init(name: String, role: String? = nil, aliases: [String] = [], topics: [String] = [], isSelf: Bool = false) {
        self.name = name
        self.role = role
        self.aliases = aliases
        self.topics = topics
        self.isSelf = isSelf
    }

    static let honorifics = ["さん", "様", "さま", "くん", "君", "ちゃん", "氏", "先生"]

    /// 発言の中で、この人を指す言葉。氏名・姓名の各部分（2 文字以上）・呼ばれ方（敬称を外したものも）。
    var mentionTerms: [String] {
        var terms: [String] = [name.filter { !$0.isWhitespace }]
        terms += name.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.count >= 2 }
        for alias in aliases {
            terms.append(alias)
            if let suffix = Self.honorifics.first(where: { alias.hasSuffix($0) }) {
                let stripped = String(alias.dropLast(suffix.count))
                if stripped.count >= 2 { terms.append(stripped) }
            }
        }
        var seen = Set<String>()
        return terms.filter { $0.count >= 2 && seen.insert($0.lowercased()).inserted }
    }
}

/// `ACTOR.md` を読み込めなかった理由。
public enum ActorListError: Error, Equatable, Sendable {
    /// 「## 名前」の節が 1 つも無い。
    case empty
    case tooMany(max: Int)
    case duplicate(String)
    case multipleSelf([String])
    case nameTooLong(String)
}

/// `ACTOR.md` から取り出した、アクターの一覧。外から来た文章を、ここで一度だけ検査して型にする（内側で再検証しない）。
///
/// 書式：「## 名前」が 1 人分の節。節の中の「- 項目: 値」を読む（項目：`役割`・`呼ばれ方`・`話題`・`本人`。値の複数は `、` か `,` で区切る）。
/// それ以外の文章（説明・ほかの見出し）は、読まずに、そのままにする。
public struct ActorList: Equatable, Sendable {
    public static let maxActors = 12
    static let maxNameLength = 40
    static let maxItemLength = 60
    static let maxItems = 10

    public let actors: [Actor]
    /// 読んだが、使わなかった項目（知らない項目名・長すぎる値など）。止めずに、知らせるだけ。
    public let warnings: [String]

    public init(actors: [Actor], warnings: [String] = []) {
        self.actors = actors
        self.warnings = warnings
    }

    /// マイクで話している人（無いことがある）。
    public var selfActor: Actor? { actors.first(where: \.isSelf) }
    /// システム音声（相手）の側で話し得る人。
    public var others: [Actor] { actors.filter { !$0.isSelf } }

    /// 記録の見出しに書く 1 行：「山田 太郎（本人）、佐藤 花子」。
    public var summary: String {
        actors.map { $0.isSelf ? "\($0.name)（本人）" : $0.name }.joined(separator: "、")
    }

    public static func parse(_ text: String) -> Result<ActorList, ActorListError> {
        struct Draft {
            var name: String
            var role: String?
            var aliases: [String] = []
            var topics: [String] = []
            var isSelf = false
        }
        var drafts: [Draft] = []
        var warnings: [String] = []
        var nameProblem: ActorListError?

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                let name = line.dropFirst(3).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if name.isEmpty { warnings.append("名前の無い「##」の節は、使いません"); drafts.append(Draft(name: "")); continue }
                if name.count > maxNameLength, nameProblem == nil { nameProblem = .nameTooLong(name) }
                drafts.append(Draft(name: name))
                continue
            }
            // 「##」より深い・浅い見出しは、節の区切りにしない（説明の見出しとして、読み飛ばす）。
            guard !drafts.isEmpty, !line.hasPrefix("#"), let item = parseItem(line) else { continue }
            let owner = drafts[drafts.count - 1].name
            if owner.isEmpty { continue }
            switch item.key {
            case "役割":
                drafts[drafts.count - 1].role = clip(item.value, in: owner, key: item.key, warnings: &warnings)
            case "呼ばれ方":
                drafts[drafts.count - 1].aliases = list(item.value, in: owner, key: item.key, warnings: &warnings)
            case "話題":
                drafts[drafts.count - 1].topics = list(item.value, in: owner, key: item.key, warnings: &warnings)
            case "本人":
                switch item.value.lowercased() {
                case "はい", "yes", "true", "y": drafts[drafts.count - 1].isSelf = true
                case "いいえ", "no", "false", "n", "": drafts[drafts.count - 1].isSelf = false
                default: warnings.append("「\(owner)」の「本人」は、「はい」か「いいえ」で書きます（「\(item.value)」は、使いません）")
                }
            default:
                warnings.append("「\(owner)」の項目「\(item.key)」は、使いません（使えるのは 役割・呼ばれ方・話題・本人）")
            }
        }

        if let nameProblem { return .failure(nameProblem) }
        let actors = drafts.filter { !$0.name.isEmpty }.map { Actor(name: $0.name, role: $0.role, aliases: $0.aliases, topics: $0.topics, isSelf: $0.isSelf) }
        guard !actors.isEmpty else { return .failure(.empty) }
        guard actors.count <= maxActors else { return .failure(.tooMany(max: maxActors)) }
        var seen = Set<String>()
        for actor in actors where !seen.insert(actor.name.lowercased()).inserted { return .failure(.duplicate(actor.name)) }
        let selves = actors.filter(\.isSelf).map(\.name)
        guard selves.count <= 1 else { return .failure(.multipleSelf(selves)) }
        return .success(ActorList(actors: actors, warnings: warnings))
    }

    /// 「- 項目: 値」（行頭は `-`・`*`・`・`。区切りは `:` か `：`）。
    private static func parseItem(_ line: String) -> (key: String, value: String)? {
        guard let first = line.first, "-*・".contains(first) else { return nil }
        let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
        guard let colon = body.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        let key = body[..<colon].trimmingCharacters(in: .whitespaces)
        let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : (key, value)
    }

    private static func clip(_ value: String, in owner: String, key: String, warnings: inout [String]) -> String? {
        guard !value.isEmpty else { return nil }
        guard value.count <= maxItemLength * 2 else {
            warnings.append("「\(owner)」の「\(key)」が長すぎます（\(maxItemLength * 2) 文字まで。使いません）")
            return nil
        }
        return value
    }

    private static func list(_ value: String, in owner: String, key: String, warnings: inout [String]) -> [String] {
        var items: [String] = []
        for part in value.split(whereSeparator: { $0 == "、" || $0 == "," || $0 == "，" }) {
            let item = part.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            guard item.count <= maxItemLength else { warnings.append("「\(owner)」の「\(key)」の「\(item.prefix(10))…」は長すぎます（\(maxItemLength) 文字まで。使いません）"); continue }
            if items.count == maxItems { warnings.append("「\(owner)」の「\(key)」は、\(maxItems) 件までです（残りは使いません）"); break }
            items.append(item)
        }
        return items
    }
}
