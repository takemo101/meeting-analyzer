import AVFoundation
import CoreMedia
import Foundation
import Speech

/// 文字起こしの 1 回の更新。確定前（`isFinal == false`）は、同じ区間の本文が後から書き換わる。
public struct TranscriptionUpdate: Sendable, Equatable {
    public var text: String
    public var isFinal: Bool
    /// 音声の先頭からの秒数（この更新が指す区間）。
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, isFinal: Bool, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.isFinal = isFinal
        self.start = start
        self.end = end
    }
}

public enum TranscriptionError: Error, Sendable, Equatable {
    /// この言語のオンデバイス認識が、この Mac で使えない。
    case unsupportedLocale(String)
    /// 音声ファイルを開けない。
    case unreadableAudio(String)
    /// 認識に失敗した（モデルの取得・解析中のエラー）。
    case failed(String)
}

/// この Mac で、その言語のオンデバイス認識が使えるか（`doctor` と、検証の前提確認に使う）。
public struct SpeechReadiness: Sendable, Equatable {
    public let locale: String
    public let supported: Bool
    public let installed: Bool

    public static func check(locale: Locale) async -> SpeechReadiness {
        let supported = await SpeechTranscriber.supportedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        let installed = await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        return SpeechReadiness(locale: locale.identifier, supported: supported, installed: installed)
    }
}

/// Apple の `SpeechTranscriber`（オンデバイス）で、音声ファイルを文字にする。音声はこの Mac の外へ出さない。
public struct AppleSpeechTranscriber: Sendable {
    public init() {}

    /// 言語のモデルが未取得なら、OS の仕組みで取得する（初回だけ。取得は Apple のサーバーから）。
    static func ensureModel(for transcriber: SpeechTranscriber) async throws {
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw TranscriptionError.failed("言語モデルを用意できません: \(error.localizedDescription)")
        }
    }

    /// ファイルを先頭から解析し、更新（確定前を含む）を順に返す。最後に確定した結果で終わる。
    public func updates(forFile url: URL, locale: Locale) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let readiness = await SpeechReadiness.check(locale: locale)
                    guard readiness.supported else { throw TranscriptionError.unsupportedLocale(locale.identifier) }
                    let file: AVAudioFile
                    do { file = try AVAudioFile(forReading: url) }
                    catch { throw TranscriptionError.unreadableAudio(url.path) }

                    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
                    try await Self.ensureModel(for: transcriber)
                    let analyzer = SpeechAnalyzer(modules: [transcriber])

                    let reader = Task {
                        for try await result in transcriber.results {
                            let start = result.range.start.seconds, end = result.range.end.seconds
                            continuation.yield(TranscriptionUpdate(
                                text: String(result.text.characters), isFinal: result.isFinal,
                                start: start.isFinite ? start : 0, end: end.isFinite ? end : (start.isFinite ? start : 0)
                            ))
                        }
                    }
                    if let last = try await analyzer.analyzeSequence(from: file) {
                        try await analyzer.finalizeAndFinish(through: last)
                    } else {
                        await analyzer.cancelAndFinishNow()
                    }
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
