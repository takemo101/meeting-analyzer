import Foundation

/// 取り込みの設定（設定ウィンドウで選び、再起動しても覚えておく。SPEC §5）：マイク・システム音声・画面の取り込み・転送のまとめ方・分析のプリセット。
/// アプリの設定（`UserDefaults`）に、型ごとに 1 つのキーで保存する。**読むときに、一度だけ検査して型にする**（壊れた値・知らない値は、その項目だけ既定に戻す）。
public struct CapturePreferences: Sendable, Equatable {
    public var microphone = true
    public var system = SystemSource.off
    public var screen = ScreenSelection.off
    public var batchMode = BatchMode.utterance
    public var presetID = AnalysisPreset.defaultID
    /// 使う文字起こし（Mac 標準か、ダウンロードしたモデル。SPEC §3.12）。
    public var transcription = TranscriptionChoice.apple
    /// 使う `ACTOR.md` のパス（SPEC §3.13）。無ければ `nil`。
    public var actorFile: String?
    /// 話者の推定に使う判断モデルの ID（`DecisionModelCatalog`）。無ければ `nil`＝推定しない（「相手」のまま。SPEC §3.13）。
    public var decisionModel: String?
    /// 声による話者の分離（SPEC §3.14）。既定はオフ。オンにできるのは、モデルが取得済みのときだけ（アプリが確かめる）。
    public var voiceSeparation = false
    /// 声紋を使う（SPEC §3.15）。既定はオフ。オンにできるのは、声による話者の分離がオンのときだけ（アプリが確かめる）。
    public var voiceprints = false
    /// 声による話者の分離の、話者の人数（SPEC §3.14）。無指定（`nil`）は、自動。2〜8。声の似た人が 1 つにまとまるとき、指定する。
    public var voiceSpeakerCount: Int?
    /// 分離の調整（SPEC §3.16）。声の特徴を、同じ人にまとめる距離の上限。無指定（`nil`）は、既定（0.6）。範囲は `VoiceSeparationTuning.clusterThresholdRange`。
    public var voiceClusterThreshold: Double?
    /// 分離の調整（SPEC §3.16）。これより短い区間（秒）は、声の特徴を取らない。無指定（`nil`）は、既定（1.0）。範囲は `VoiceSeparationTuning.minSegmentSecondsRange`。
    public var voiceMinSegmentSeconds: Double?
    /// 相手（システム音声）の音声を保存する（SPEC §3.16）。既定はオフ。オンにできるのは、声による話者の分離がオンのときだけ（アプリが確かめる）。
    public var saveOthersAudio = false
    /// 最近使った `ACTOR.md`（新しい順。選んでいるものを含む。メニューで切り替える。SPEC §3.13）。
    public var actorFiles: [String] = []
    /// `ACTOR.md` ごとの、出席者から外した人の名前（既定は全員出席。あとから足された人は、出席）。
    public var absentActors: [String: [String]] = [:]

    public static let maxActorFiles = 8

    public init() {}

    /// 選んだ `ACTOR.md` を、最近の一覧の先頭へ（すでにあれば、先頭へ移す。上限を超えた古いものは、捨てる）。
    public mutating func remember(actorFile path: String) {
        actorFiles.removeAll { $0 == path }
        actorFiles.insert(path, at: 0)
        if actorFiles.count > Self.maxActorFiles { actorFiles.removeLast(actorFiles.count - Self.maxActorFiles) }
    }

    /// その `ACTOR.md` の、外した人を置き換える（空なら、項目ごと消す）。
    public mutating func setAbsent(_ names: Set<String>, for path: String) {
        if names.isEmpty { absentActors[path] = nil } else { absentActors[path] = names.sorted() }
    }

    static let keys = (microphone: "capture.microphone", system: "capture.system", screen: "capture.screen", batchMode: "capture.batchMode", presetID: "capture.presetID", transcription: "capture.transcription", actorFile: "capture.actorFile", decisionModel: "capture.decisionModel", actorFiles: "capture.actorFiles", absentActors: "capture.absentActors", voiceSeparation: "capture.voiceSeparation", voiceprints: "capture.voiceprints", voiceSpeakerCount: "capture.voiceSpeakerCount", saveOthersAudio: "capture.saveOthersAudio", voiceClusterThreshold: "capture.voiceClusterThreshold", voiceMinSegmentSeconds: "capture.voiceMinSegmentSeconds")

    public static func load(_ defaults: UserDefaults = .standard) -> CapturePreferences {
        var result = CapturePreferences()
        if defaults.object(forKey: keys.microphone) != nil { result.microphone = defaults.bool(forKey: keys.microphone) }
        if let stored = defaults.dictionary(forKey: keys.system) as? [String: String] {
            switch stored["kind"] {
            case "off": result.system = .off
            case "all": result.system = .all
            case "app": if let id = stored["bundleID"], let name = stored["name"], !id.isEmpty, !name.isEmpty { result.system = .app(bundleID: id, name: name) }
            default: break
            }
        }
        if let stored = defaults.dictionary(forKey: keys.screen) as? [String: String] {
            switch stored["kind"] {
            case "off": result.screen = .off
            case "display": result.screen = .display
            case "app": if let id = stored["bundleID"], let name = stored["name"], !id.isEmpty, !name.isEmpty { result.screen = .app(bundleID: id, name: name) }
            default: break
            }
        }
        if let raw = defaults.string(forKey: keys.batchMode), let mode = BatchMode(rawValue: raw) { result.batchMode = mode }
        if let id = defaults.string(forKey: keys.presetID), !id.isEmpty { result.presetID = id }
        // 知らないモデルの ID（消えたモデル・壊れた値）は、Mac 標準に戻す。
        if let id = defaults.string(forKey: keys.transcription), let choice = TranscriptionChoice(id: id) { result.transcription = choice }
        // 絶対パスだけ（壊れた値は、その項目だけ、無しに戻す）。
        if let path = defaults.string(forKey: keys.actorFile), path.hasPrefix("/") { result.actorFile = path }
        // 最近の一覧：絶対パスだけ・重複を除く・上限まで。選んでいるものが無ければ、先頭に足す（この項目が無かった版の設定を引き継ぐ）。
        var seen = Set<String>()
        result.actorFiles = (defaults.stringArray(forKey: keys.actorFiles) ?? []).filter { $0.hasPrefix("/") && seen.insert($0).inserted }
        if result.actorFiles.count > maxActorFiles { result.actorFiles.removeLast(result.actorFiles.count - maxActorFiles) }
        if let path = result.actorFile, !result.actorFiles.contains(path) { result.remember(actorFile: path) }
        if let stored = defaults.dictionary(forKey: keys.absentActors) as? [String: [String]] {
            for (path, names) in stored where path.hasPrefix("/") && !names.isEmpty { result.absentActors[path] = names }
        }
        // 知らないモデルの ID（消えたモデル・壊れた値）は、無し（推定しない）に戻す。
        if let id = defaults.string(forKey: keys.decisionModel), DecisionModelCatalog.model(id: id) != nil { result.decisionModel = id }
        if defaults.object(forKey: keys.voiceSeparation) != nil { result.voiceSeparation = defaults.bool(forKey: keys.voiceSeparation) }
        if defaults.object(forKey: keys.voiceprints) != nil { result.voiceprints = defaults.bool(forKey: keys.voiceprints) }
        if defaults.object(forKey: keys.saveOthersAudio) != nil { result.saveOthersAudio = defaults.bool(forKey: keys.saveOthersAudio) }
        // 範囲外・壊れた値は、自動（無指定）に戻す。
        if defaults.object(forKey: keys.voiceSpeakerCount) != nil, VoiceSeparationTuning.speakerCountRange.contains(defaults.integer(forKey: keys.voiceSpeakerCount)) { result.voiceSpeakerCount = defaults.integer(forKey: keys.voiceSpeakerCount) }
        if defaults.object(forKey: keys.voiceClusterThreshold) != nil, VoiceSeparationTuning.clusterThresholdRange.contains(defaults.double(forKey: keys.voiceClusterThreshold)) { result.voiceClusterThreshold = defaults.double(forKey: keys.voiceClusterThreshold) }
        if defaults.object(forKey: keys.voiceMinSegmentSeconds) != nil, VoiceSeparationTuning.minSegmentSecondsRange.contains(defaults.double(forKey: keys.voiceMinSegmentSeconds)) { result.voiceMinSegmentSeconds = defaults.double(forKey: keys.voiceMinSegmentSeconds) }
        return result
    }

    public func save(_ defaults: UserDefaults = .standard) {
        defaults.set(microphone, forKey: Self.keys.microphone)
        switch system {
        case .off: defaults.set(["kind": "off"], forKey: Self.keys.system)
        case .all: defaults.set(["kind": "all"], forKey: Self.keys.system)
        case .app(let id, let name): defaults.set(["kind": "app", "bundleID": id, "name": name], forKey: Self.keys.system)
        }
        switch screen {
        case .off: defaults.set(["kind": "off"], forKey: Self.keys.screen)
        case .display: defaults.set(["kind": "display"], forKey: Self.keys.screen)
        case .app(let id, let name): defaults.set(["kind": "app", "bundleID": id, "name": name], forKey: Self.keys.screen)
        }
        defaults.set(batchMode.rawValue, forKey: Self.keys.batchMode)
        defaults.set(presetID, forKey: Self.keys.presetID)
        defaults.set(transcription.id, forKey: Self.keys.transcription)
        if let actorFile { defaults.set(actorFile, forKey: Self.keys.actorFile) } else { defaults.removeObject(forKey: Self.keys.actorFile) }
        defaults.set(actorFiles, forKey: Self.keys.actorFiles)
        defaults.set(absentActors, forKey: Self.keys.absentActors)
        if let decisionModel { defaults.set(decisionModel, forKey: Self.keys.decisionModel) } else { defaults.removeObject(forKey: Self.keys.decisionModel) }
        defaults.set(voiceSeparation, forKey: Self.keys.voiceSeparation)
        defaults.set(voiceprints, forKey: Self.keys.voiceprints)
        defaults.set(saveOthersAudio, forKey: Self.keys.saveOthersAudio)
        if let voiceSpeakerCount { defaults.set(voiceSpeakerCount, forKey: Self.keys.voiceSpeakerCount) } else { defaults.removeObject(forKey: Self.keys.voiceSpeakerCount) }
        if let voiceClusterThreshold { defaults.set(voiceClusterThreshold, forKey: Self.keys.voiceClusterThreshold) } else { defaults.removeObject(forKey: Self.keys.voiceClusterThreshold) }
        if let voiceMinSegmentSeconds { defaults.set(voiceMinSegmentSeconds, forKey: Self.keys.voiceMinSegmentSeconds) } else { defaults.removeObject(forKey: Self.keys.voiceMinSegmentSeconds) }
    }
}
