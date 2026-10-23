import Foundation

/// 取り込みの設定（設定ウィンドウで選び、再起動しても覚えておく。SPEC §5）：マイク・システム音声・画面の取り込み・転送のまとめ方・分析のプリセット。
/// アプリの設定（`UserDefaults`）に、型ごとに 1 つのキーで保存する。**読むときに、一度だけ検査して型にする**（壊れた値・知らない値は、その項目だけ既定に戻す）。
public struct CapturePreferences: Sendable, Equatable {
    public var microphone = true
    public var system = SystemSource.off
    public var screen = ScreenSelection.off
    public var batchMode = BatchMode.utterance
    public var presetID = AnalysisPreset.defaultID

    public init() {}

    static let keys = (microphone: "capture.microphone", system: "capture.system", screen: "capture.screen", batchMode: "capture.batchMode", presetID: "capture.presetID")

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
    }
}
