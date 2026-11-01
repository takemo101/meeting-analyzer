import AVFoundation
import Foundation

extension LiveInputs {
    /// 実機の入力。本人＝マイク（ボイス処理）、相手＝`system` で選んだシステム音声。どちらも、オンデバイスで認識する。
    /// `transcription`：Mac 標準（`SpeechTranscriber`。既定）か、ダウンロードしたモデル（SPEC §3.12）。
    /// 言語が使えない（Mac 標準）・モデルが取得されていない（ダウンロード式）ときは、取り込みを始める前に、`TranscriptionError` を投げる。
    /// `recorder`：声による話者の分離（SPEC §3.14）を選んだときだけ。システム音声を、メモリ上だけに持つ（認識へ渡す音は、そのまま）。
    public static func device(system: SystemSource, locale: Locale, transcription: TranscriptionChoice = .apple, models: ModelStore? = nil, recorder: VoiceAudioRecorder? = nil) -> LiveInputs {
        // ダウンロード式のモデルは、会議 1 つにつき 1 回だけ開き、マイクと相手の流れで共有する（会議が終わると、解放する）。
        let shared = SharedLocalTranscriber()
        return LiveInputs { speaker in
            let updates: (AsyncStream<AVAudioPCMBuffer>) async throws -> AsyncThrowingStream<TranscriptionUpdate, Error>
            switch transcription {
            case .apple:
                guard await SpeechReadiness.check(locale: locale).supported else {
                    throw TranscriptionError.unsupportedLocale(locale.identifier)
                }
                let transcriber = AppleSpeechTranscriber()
                updates = { transcriber.updates(forLive: $0, locale: locale) }
            case .local(let id):
                guard let model = LocalModelCatalog.model(id: id), let models else { throw TranscriptionError.modelUnavailable(id) }
                let local = try await shared.transcriber(for: model, store: models)
                updates = { local.updates(forLive: $0) }
            }
            switch speaker {
            case .you:
                let microphone = MicrophoneCapture()
                let buffers = try await microphone.start()
                return LiveInputStream(updates: try await updates(buffers), stop: { microphone.stop() })
            case .others:
                let target: SystemAudioTarget
                switch system {
                case .off: throw CaptureError.failed("システム音声が選ばれていません")
                case .all: target = .allApps
                case .app(let bundleID, _): target = .apps([bundleID])
                }
                let capture = SystemAudioCapture()
                recorder?.begin()
                let buffers = try await capture.start(target: target)
                let heard = recorder.map { record(buffers, into: $0) } ?? buffers
                return LiveInputStream(updates: try await updates(heard), stop: { await capture.stop() })
            }
        }
    }

    /// 取り込んだ音を、`recorder` へ写しながら、そのまま流す。
    private static func record(_ buffers: AsyncStream<AVAudioPCMBuffer>, into recorder: VoiceAudioRecorder) -> AsyncStream<AVAudioPCMBuffer> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                for await buffer in buffers {
                    recorder.append(buffer)
                    continuation.yield(buffer)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// ダウンロード式のモデルを、1 回だけ開いて、共有する。
private actor SharedLocalTranscriber {
    private var transcriber: LocalTranscriber?

    func transcriber(for model: LocalModel, store: ModelStore) async throws -> LocalTranscriber {
        if let transcriber { return transcriber }
        // 読み込みと検証（SHA-256）は、数秒かかることがあるので、別のスレッドで行う。
        let opened = try await Task.detached(priority: .userInitiated) { try LocalTranscriber(model: model, store: store) }.value
        transcriber = opened
        return opened
    }
}
