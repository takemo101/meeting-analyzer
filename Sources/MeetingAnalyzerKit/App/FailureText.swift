import Foundation

/// 失敗を、利用者に見せる文にする（SPEC §4：原因と対処を、短い文で）。見せ方を決めるのは、この境界だけ。
enum FailureText {
    static func bridge(_ error: BridgeError) -> String {
        switch error {
        case .unreachable: return "エージェント側（live-support）に接続できません。エージェントを起動してから、もう一度試してください"
        case .unauthorized: return "エージェント側のトークンが違います。エージェントを起動し直してください"
        case .notReady: return "エージェント側が、まだ受け付けられません。エージェントのセッションを確認してください"
        case .rejected(let status): return "エージェント側が、内容を受け付けませんでした（HTTP \(status)）"
        }
    }

    static func token(_ error: TokenError, directory: String) -> String {
        switch error {
        case .missing: return "トークンがありません（\(directory)/token）。エージェント側を一度起動してください"
        case .unreadable: return "トークンを読めません（\(directory)/token）"
        }
    }

    static func start(_ error: LiveSessionError) -> String {
        switch error {
        case .bridge(let error): return bridge(error)
        case .capture(.permissionDenied(let reason)): return reason
        case .capture(.targetNotFound(let reason)): return reason
        case .capture(.failed(let reason)): return reason
        case .transcription(.unsupportedLocale(let locale)): return "この Mac では、\(locale) のオンデバイス認識を使えません"
        case .transcription(.unreadableAudio(let reason)), .transcription(.failed(let reason)): return "文字起こしを始められません: \(reason)"
        case .invalidState: return "いまは、その操作はできません"
        case .failed(let reason): return reason
        }
    }

    /// 会議の途中の知らせ（メニューの 1 行）。
    static func notice(_ notice: LiveSessionNotice) -> String {
        switch notice {
        case .captureStopped(let speaker):
            return speaker == .you ? "マイクの取り込みが止まりました" : "相手の音声の取り込みが止まりました（会議アプリを確認）"
        case .transcriptionFailed(let speaker, _):
            return "\(speaker.displayName)の文字起こしが止まりました"
        case .sendFailed(let error):
            switch error {
            case .unreachable: return "字幕を送れません（エージェント側に接続できません）"
            case .unauthorized: return "字幕を送れません（トークンが違います）"
            case .notReady: return "字幕を送れません（エージェント側が未接続）"
            case .rejected(let status): return "字幕が受け付けられませんでした（HTTP \(status)）"
            }
        }
    }
}
