import Foundation

extension LiveInputs {
    /// 実機の入力。本人＝マイク（ボイス処理）、相手＝`system` で選んだシステム音声。どちらも、オンデバイスで認識する。
    /// 言語が使えないときは、取り込みを始める前に、`TranscriptionError.unsupportedLocale` を投げる。
    public static func device(system: SystemSource, locale: Locale) -> LiveInputs {
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
                let target: SystemAudioTarget
                switch system {
                case .off: throw CaptureError.failed("システム音声が選ばれていません")
                case .all: target = .allApps
                case .app(let bundleID, _): target = .apps([bundleID])
                }
                let capture = SystemAudioCapture()
                let buffers = try await capture.start(target: target)
                return LiveInputStream(updates: transcriber.updates(forLive: buffers, locale: locale), stop: { await capture.stop() })
            }
        }
    }
}
