import AVFoundation
import Foundation
import Speech

extension AppleSpeechTranscriber {
    /// ライブの音声（マイク・システム音声）を解析し、更新（確定前を含む）を順に返す。バッファの流れが終わると、確定して終わる。
    /// `start`／`end` は、最初のバッファを 0 とした、入力した音声の長さでの秒数。
    public func updates(forLive buffers: AsyncStream<AVAudioPCMBuffer>, locale: Locale) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let readiness = await SpeechReadiness.check(locale: locale)
                    guard readiness.supported else { throw TranscriptionError.unsupportedLocale(locale.identifier) }

                    // 実時間の入力では、.fastResults がないと、結果が発話の終わり（数秒〜10 秒以上あと）まで出ない（合成音声での実測）。
                    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
                    try await Self.ensureModel(for: transcriber)
                    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                        throw TranscriptionError.failed("認識に使える音声の形式がありません")
                    }
                    let analyzer = SpeechAnalyzer(modules: [transcriber])
                    let (input, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

                    let reader = Task {
                        for try await result in transcriber.results {
                            let start = result.range.start.seconds, end = result.range.end.seconds
                            continuation.yield(TranscriptionUpdate(
                                text: String(result.text.characters), isFinal: result.isFinal,
                                start: start.isFinite ? start : 0, end: end.isFinite ? end : (start.isFinite ? start : 0)
                            ))
                        }
                    }
                    try await analyzer.start(inputSequence: input)

                    let converter = AudioFormatConverter(target: format)
                    for await buffer in buffers {
                        if let converted = converter.convert(buffer) { inputBuilder.yield(AnalyzerInput(buffer: converted)) }
                    }
                    inputBuilder.finish()
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    try await reader.value
                    continuation.finish()
                } catch let error as TranscriptionError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: TranscriptionError.failed(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}
