import Foundation

/// `ACTOR.md` を読めなかった理由（SPEC §3.13）。
public enum ActorFileError: Error, Equatable, Sendable {
    case notReadable(String)
    case tooLarge(bytes: Int)
    case notUTF8
    case invalid(ActorListError)

    /// 利用者に見せる文（原因と対処。CLI・設定ウィンドウが同じ文を使う）。
    public var message: String {
        switch self {
        case .notReadable(let path): return "ファイルを読めません: \(path)"
        case .tooLarge(let bytes): return "ファイルが大きすぎます（\(bytes / 1024) KB。\(ActorFile.maxBytes / 1024) KB まで）。アクターの一覧だけを書いてください"
        case .notUTF8: return "文字コードが UTF-8 ではありません"
        case .invalid(.empty): return "アクターが 1 人も見つかりません。「## 名前」の見出しで、1 人ずつ書いてください"
        case .invalid(.tooMany(let max)): return "アクターが多すぎます（\(max) 人まで）"
        case .invalid(.duplicate(let name)): return "同じ名前が 2 回あります: \(name)"
        case .invalid(.multipleSelf(let names)): return "「本人: はい」は、1 人だけに付けます（\(names.joined(separator: "・"))）"
        case .invalid(.nameTooLong(let name)): return "名前が長すぎます: \(name.prefix(20))…"
        }
    }
}

/// `ACTOR.md` の読み取り。外から来たファイルを、ここで一度だけ、大きさ・文字コード・書式を検査して、`ActorList` にする。
public enum ActorFile {
    /// 一覧だけを書くファイルなので、小さい（言語モデルへ渡す量の上限にもなる）。
    public static let maxBytes = 64 * 1024

    public static func load(path: String) -> Result<ActorList, ActorFileError> {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let handle = FileHandle(forReadingAtPath: path) else { return .failure(.notReadable(path)) }
        defer { try? handle.close() }
        // 大きなファイルを全部読まない（上限 + 1 バイトだけ読んで、超えたら断る）。
        guard let data = try? handle.read(upToCount: maxBytes + 1) else { return .failure(.notReadable(path)) }
        guard data.count <= maxBytes else { return .failure(.tooLarge(bytes: (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? data.count)) }
        guard let text = String(data: data, encoding: .utf8) else { return .failure(.notUTF8) }
        return ActorList.parse(text).mapError { ActorFileError.invalid($0) }
    }
}
