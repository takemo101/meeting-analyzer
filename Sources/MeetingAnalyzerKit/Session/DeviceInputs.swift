import Foundation

extension LiveInputs {
    /// 実機の入力。あなた＝マイク（ボイス処理）、相手＝選んだ会議アプリのシステム音声。どちらも、オンデバイスで認識する。
    /// 言語が使えないときは、取り込みを始める前に、`TranscriptionError.unsupportedLocale` を投げる。
    public static func device(appBundleIDs: [String], locale: Locale) -> LiveInputs {
        LiveInputs { speaker in
            guard await SpeechReadiness.check(locale: locale).supported else {
                throw TranscriptionError.unsupportedLocale(locale.identifier)
            }
            let transcriber = AppleSpeechTranscriber()
            switch speaker {
            case .you:
                let microphone = MicrophoneCapture()
                let buffers = try await microphone.start()
                return LiveInputStream(updates: transcriber.updates(forLive: buffers, locale: locale), stop: { microphone.stop() })
            case .others:
                let system = SystemAudioCapture()
                let buffers = try await system.start(bundleIDs: appBundleIDs)
                return LiveInputStream(updates: transcriber.updates(forLive: buffers, locale: locale), stop: { await system.stop() })
            }
        }
    }
}
