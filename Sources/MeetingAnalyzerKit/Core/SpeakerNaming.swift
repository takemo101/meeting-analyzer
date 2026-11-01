import Foundation

/// 会議の時刻（開始からの秒）の区間。聞き直し（SPEC §3.16）で、保存した音声の、どこを再生するかに使う。
public struct SpeakerClip: Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

/// 名付けの画面に見せる、話者（話者 N）1 人分の要約（SPEC §3.15）。
public struct SpeakerSummary: Sendable, Equatable {
    /// 話者 N の N。
    public let id: Int
    /// 話した時間（確定した発話の長さの合計。秒）。
    public let seconds: TimeInterval
    public let utteranceCount: Int
    /// 発言の抜粋（長い発言から 3 件。時刻の順。60 文字まで）。
    public let excerpts: [String]
    /// 抜粋ごとの、会議の時刻の区間（`excerpts` と同じ並び。聞き直しに使う）。
    public let clips: [SpeakerClip]

    public init(id: Int, seconds: TimeInterval, utteranceCount: Int, excerpts: [String], clips: [SpeakerClip] = []) {
        self.id = id
        self.seconds = seconds
        self.utteranceCount = utteranceCount
        self.excerpts = excerpts
        self.clips = clips
    }
}

/// 名付けの名前の規則（SPEC §3.15）。境界（画面の入力）で、一度だけ検査して、使う。
public enum SpeakerNameRule {
    public static let maxLength = 40

    /// 前後の空白を除き、1〜40 文字で、改行・制御文字を含まなければ、その名前。そうでなければ `nil`。
    public static func normalize(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= maxLength else { return nil }
        guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }
}

/// 確定した名前 1 件（`speaker`＝話者 N の N）。
public struct SpeakerName: Codable, Equatable, Sendable {
    public let speaker: Int
    public let name: String

    public init(speaker: Int, name: String) {
        self.speaker = speaker
        self.name = name
    }
}

/// 名付けの確定の出来事の内容（SPEC §3.7 `speakers`）。記録は、すでに書き直されている。
public struct SpeakersNamed: Codable, Equatable, Sendable {
    public let sessionId: String
    /// 書き直した記録の絶対パス。無ければ（記録を書かない会議）省く。
    public let transcriptPath: String?
    public let speakers: [SpeakerName]
    /// 再分離（SPEC §3.16）のあとの出来事のとき `true`。**これまでの `speakers` は無効**（話者 N の対応が変わった）で、`speakers` が、いまの確定した名前のすべて（空のこともある）。通常の名付けでは、省く。
    public let reseparated: Bool?

    public init(sessionId: String, transcriptPath: String?, speakers: [SpeakerName], reseparated: Bool? = nil) {
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.speakers = speakers
        self.reseparated = reseparated
    }
}

/// 名付けを断った理由（SPEC §3.15）。
public enum SpeakerNamingError: Error, Sendable, Equatable {
    /// 会議が、まだ終わっていない。
    case notFinished
    /// 名前が、空・長すぎる・改行を含む。
    case invalidName
    /// その話者 N は、この会議に無い。
    case unknownSpeaker(Int)
    /// その話者は、すでに名前が確定している（確定した名前は、変えられない）。
    case alreadyNamed(Int)
    /// 渡された名前が、1 件も無い。
    case empty
    /// 記録を書き直せなかった（確定しない）。
    case writeFailed

    public var message: String {
        switch self {
        case .notFinished: return "会議が、まだ終わっていません"
        case .invalidName: return "名前は、1〜\(SpeakerNameRule.maxLength) 文字で、改行を含めないでください"
        case .unknownSpeaker(let id): return "話者 \(id) は、この会議にいません"
        case .alreadyNamed(let id): return "話者 \(id) の名前は、すでに確定しています"
        case .empty: return "名前が、ありません"
        case .writeFailed: return "記録を書き直せませんでした（名前は確定していません）"
        }
    }
}
