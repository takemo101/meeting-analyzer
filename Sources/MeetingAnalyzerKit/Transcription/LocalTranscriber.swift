import AVFoundation
import Foundation

/// ダウンロードしたモデルで、音声を文字にする（SPEC §3.12）。音声は、この Mac の中だけで処理し、外へ出さない。
/// モデルは、ストリーミングに対応しない（暫定の文字は出ない）。そこで、音声区間の検出（VAD）で**発話ごとに区切り、発話が終わったら、その発話を 1 回で文字にする**。
/// 認識のモデルは、マイクと相手の 2 つの流れで共有する（1 つのモデルで、同時に実行できるのは 1 つ）。VAD は、流れごとに持つ。
public final class LocalTranscriber: @unchecked Sendable {
    public let model: LocalModel
    private let recognizer: NativeRecognizer
    private let voiceActivityModel: URL
    /// 16 kHz・モノラル・float。VAD とモデルが求める形。
    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(UtteranceSegmenter.sampleRate), channels: 1, interleaved: false)!
    /// 発話の終わりを待つあいだに、保持する音声の長さ（秒）。発話の上限（約 30 秒）と、前後の余白より長い。
    private static let keepSeconds = 45

    /// モデルを開く（読み込みに、数秒かかることがある）。取得されていない・検証に通らなければ、`modelUnavailable`。
    public init(model: LocalModel, store: ModelStore) throws {
        guard store.ensureVerified(model.artifact), store.ensureVerified(LocalModelCatalog.voiceActivity) else {
            throw TranscriptionError.modelUnavailable(model.name)
        }
        do { recognizer = try NativeRecognizer(modelURL: store.fileURL(model.artifact)) }
        catch { throw TranscriptionError.failed("モデル「\(model.name)」を開けません: \(error)") }
        voiceActivityModel = store.fileURL(LocalModelCatalog.voiceActivity)
        self.model = model
    }

    // MARK: ライブ

    /// ライブの音声（マイク・システム音声）を、発話ごとに文字にして返す。バッファの流れが終わると、残りの発話を文字にして終わる。
    /// `start`／`end` は、最初のバッファを 0 とした、入力した音声の長さでの秒数。
    public func updates(forLive buffers: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        stream { feed in
            let converter = AudioFormatConverter(target: Self.format)
            for await buffer in buffers {
                guard let converted = converter.convert(buffer), let data = converted.floatChannelData else { continue }
                try await feed(Array(UnsafeBufferPointer(start: data[0], count: Int(converted.frameLength))))
            }
        }
    }

    // MARK: ファイル

    /// 音声ファイルを、発話ごとに文字にして返す。
    public func updates(forFile url: URL) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        stream { feed in
            let file: AVAudioFile
            do { file = try AVAudioFile(forReading: url) } catch { throw TranscriptionError.unreadableAudio(url.path) }
            let converter = AudioFormatConverter(target: Self.format)
            let frames = AVAudioFrameCount(file.processingFormat.sampleRate)   // 1 秒ずつ
            while file.framePosition < file.length {
                try Task.checkCancellation()
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { break }
                do { try file.read(into: buffer, frameCount: frames) } catch { throw TranscriptionError.unreadableAudio(url.path) }
                guard buffer.frameLength > 0 else { break }
                if let converted = converter.convert(buffer), let data = converted.floatChannelData {
                    try await feed(Array(UnsafeBufferPointer(start: data[0], count: Int(converted.frameLength))))
                }
            }
        }
    }

    // MARK: 共通

    /// `produce` が、音声（16 kHz・モノラル）を、`feed` で順に渡す。発話が終わるたびに、文字にして `continuation` へ返す。`produce` が終わったら、残りを処理して終わる。
    private func stream(_ produce: @escaping @Sendable (_ feed: @escaping ([Float]) async throws -> Void) async throws -> Void) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let voice = try NativeVoiceActivity(modelURL: voiceActivityModel)
                    let utterances = UtteranceCollector(recognizer: recognizer, keepSamples: Self.keepSeconds * UtteranceSegmenter.sampleRate) { continuation.yield($0) }
                    try await produce { samples in
                        try await utterances.append(samples, probabilities: try voice.feed(samples))
                    }
                    try await utterances.finish(probabilities: try voice.flush())
                    continuation.finish()
                } catch let error as TranscriptionError {
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: TranscriptionError.failed("\(error)"))
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}

/// 音声を溜め、VAD の確率から、発話の範囲を決め、その範囲を文字にして返す。1 つの音声の流れにつき 1 つ。
private actor UtteranceCollector {
    private let recognizer: NativeRecognizer
    private let keepSamples: Int
    private let emit: @Sendable (TranscriptionUpdate) -> Void
    private var segmenter = UtteranceSegmenter()
    /// 溜めている音声（`base` が、先頭のサンプルの、流れ全体での位置）。
    private var samples: [Float] = []
    private var base = 0

    init(recognizer: NativeRecognizer, keepSamples: Int, emit: @escaping @Sendable (TranscriptionUpdate) -> Void) {
        self.recognizer = recognizer
        self.keepSamples = keepSamples
        self.emit = emit
    }

    func append(_ chunk: [Float], probabilities: [Float]) async throws {
        samples.append(contentsOf: chunk)
        for segment in segmenter.push(probabilities) { try await recognize(segment) }
        // 古い音声を捨てる（これから使うのは、最近の分だけ）。
        let excess = samples.count - keepSamples
        if excess > 0 { samples.removeFirst(excess); base += excess }
    }

    func finish(probabilities: [Float]) async throws {
        for segment in segmenter.push(probabilities) + segmenter.flush() { try await recognize(segment) }
    }

    private func recognize(_ segment: UtteranceSegmenter.Segment) async throws {
        let frame = UtteranceSegmenter.frameSamples
        let total = base + samples.count
        let start = max(base, segment.startFrame * frame), end = min(total, segment.endFrame * frame)
        guard end > start else { return }
        let slice = Array(samples[(start - base)..<(end - base)])
        let recognizer = recognizer
        let text: String
        do { text = try await Task.detached(priority: .userInitiated) { try recognizer.transcribe(slice) }.value }
        catch { throw TranscriptionError.failed("認識に失敗しました: \(error)") }
        guard !text.isEmpty else { return }
        let rate = Double(UtteranceSegmenter.sampleRate)
        emit(TranscriptionUpdate(text: text, isFinal: true, start: Double(start) / rate, end: Double(end) / rate))
    }
}

extension LocalTranscriber {
    /// ファイルの文字起こし（モデルを開くところから）。モデルが取得されていなければ、`modelUnavailable` で終わる。モデルを開く間、呼び出し元を止めない。
    public static func updates(forFile url: URL, model: LocalModel, store: ModelStore) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let transcriber = try await Task.detached(priority: .userInitiated) { try LocalTranscriber(model: model, store: store) }.value
                    for try await update in transcriber.updates(forFile: url) { continuation.yield(update) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}
