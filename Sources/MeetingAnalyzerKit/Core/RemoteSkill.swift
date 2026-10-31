import Foundation

/// このリポジトリに置いてある skill（`skills/<名前>/SKILL.md`）を、**ファイルを置かずに、リモートのまま**エージェントに使わせる指示（README「skill を、ファイルを置かずに、リモートのまま使う」）。
/// 指示は「URL を読んで、その手順で、頼みごとをする」の形。設定ウィンドウが、コピーできるようにする。
public enum RemoteSkill: CaseIterable, Sendable {
    /// ACTOR.md を作る（`meeting-analyzer-actors`）。
    case actors
    /// 分析のプリセットを作る（`meeting-analyzer-presets`）。
    case presets
    /// 会議の文字起こしを受け取り、サマリーを出す（`meeting-analyzer`）。
    case analysis

    public static let repository = "takemo101/meeting-analyzer"

    /// `skills/` の下のフォルダ名。
    public var directory: String {
        switch self {
        case .actors: return "meeting-analyzer-actors"
        case .presets: return "meeting-analyzer-presets"
        case .analysis: return "meeting-analyzer"
        }
    }

    /// 設定ウィンドウに見せる名前。
    public var title: String {
        switch self {
        case .actors: return "ACTOR.md を作る"
        case .presets: return "分析のプリセットを作る"
        case .analysis: return "会議のサマリーの手順"
        }
    }

    /// 読ませたあとの頼みごと。
    private var request: String {
        switch self {
        case .actors: return "create an ACTOR.md for this project by following it."
        case .presets: return "create a meeting-analyzer preset for meeting minutes by following it."
        case .analysis: return "follow it for the meeting-analyzer events in this session."
        }
    }

    /// SKILL.md の URL。`ref` は、ブランチかタグ（既定は、このアプリの版のタグ：手順の形を、アプリと合わせる）。
    public func url(ref: String = "v" + AppInfo.version) -> String {
        "https://raw.githubusercontent.com/\(Self.repository)/\(ref)/skills/\(directory)/SKILL.md"
    }

    /// エージェントへ貼る指示。
    public func prompt(ref: String = "v" + AppInfo.version) -> String {
        "Read \(url(ref: ref)), then \(request)"
    }
}
