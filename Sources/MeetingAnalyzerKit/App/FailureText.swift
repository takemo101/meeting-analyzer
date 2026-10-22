import Foundation

/// 失敗を、利用者に見せる文にする（SPEC §4：原因と対処を、短い文で）。見せ方を決めるのは、この境界だけ。
enum FailureText {
    static func start(_ error: LiveSessionError) -> String {
        switch error {
        case .capture(.permissionDenied(_, let reason)): return reason
        case .capture(.targetNotFound(let reason)): return reason
        case .capture(.failed(let reason)): return reason
        case .transcription(.unsupportedLocale(let locale)): return "この Mac では、\(locale) のオンデバイス認識を使えません"
        case .transcription(.unreadableAudio(let reason)), .transcription(.failed(let reason)): return "文字起こしを始められません: \(reason)"
        case .invalidState: return "いまは、その操作はできません"
        case .failed(let reason): return reason
        }
    }

    /// エージェントへ渡す窓口（ハブ）を開けなかったとき。
    static func hub(_ error: HubError) -> String {
        switch error {
        case .alreadyRunning: return "別の meeting-analyzer が起動しています（エージェントへ渡す窓口が使用中）"
        case .pathTooLong(let path): return "エージェントへ渡す窓口のパスが長すぎます（\(path)）"
        case .failed(let reason): return "エージェントへ渡す窓口を開けません: \(reason)"
        }
    }

    /// 途中の知らせ（メニューの 1 行）。
    static func notice(_ notice: LiveSessionNotice) -> String {
        switch notice {
        case .captureStopped(let speaker):
            return speaker == .you ? "マイクの取り込みが止まりました" : "システム音声の取り込みが止まりました（取り込み先のアプリを確認）"
        case .transcriptionFailed(let speaker, _):
            return "\(speaker.displayName)の文字起こしが止まりました"
        case .possibleEcho:
            return "相手の声がマイクに入っている可能性があります。ヘッドホンを使うと確実です"
        }
    }
}
