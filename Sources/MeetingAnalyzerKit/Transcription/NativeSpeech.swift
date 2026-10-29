import CTranscribe
import Foundation

/// ネイティブ（transcribe.cpp）の呼び出しの失敗。
enum NativeSpeechError: Error, Equatable {
    /// モデルを開けない（壊れている・形式が違う）。
    case load(String)
    /// 認識・音声区間の検出の実行に失敗した。
    case run(String)
}

private func describe(_ status: transcribe_status) -> String {
    "\(String(cString: transcribe_status_string(Int32(status.rawValue))))（\(status.rawValue)）"
}

/// 文字起こしのモデル 1 つ（GGUF）を開いて、音声を文字にする。Metal（GPU）を使う。
/// ネイティブの規則：**1 つのモデルで、同時に実行できるのは 1 つ**。マイクと相手の 2 つの流れが共有するので、ロックで直列にする。
final class NativeRecognizer: @unchecked Sendable {
    private var session: OpaquePointer?
    private let lock = NSLock()

    init(modelURL: URL) throws {
        var load = transcribe_model_load_params()
        transcribe_model_load_params_init(&load)
        var parameters = transcribe_session_params()
        transcribe_session_params_init(&parameters)
        let status = transcribe_open(modelURL.path, &load, &parameters, &session)
        guard status.rawValue == 0, session != nil else { throw NativeSpeechError.load(describe(status)) }
    }

    deinit {
        if let session { transcribe_session_free(session) }
    }

    /// 16 kHz・モノラル・float（-1〜1）の音声 1 つ（発話 1 つ）を、日本語の文字にする。
    func transcribe(_ samples: [Float], language: String = "ja") throws -> String {
        guard !samples.isEmpty, let session else { return "" }
        lock.lock()
        defer { lock.unlock() }
        var run = transcribe_run_params()
        transcribe_run_params_init(&run)
        let status = language.withCString { code -> transcribe_status in
            run.language = code
            return samples.withUnsafeBufferPointer { transcribe_run(session, $0.baseAddress, Int32($0.count), &run) }
        }
        guard status.rawValue == 0 else { throw NativeSpeechError.run(describe(status)) }
        return String(cString: transcribe_full_text(session)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 音声区間の検出（Silero VAD）。16 kHz の音声を、いくつに分けて渡しても、512 サンプル（32 ms）のフレームごとの「声である確率」を返す。
/// 1 つの音声の流れにつき 1 つ作る（状態を持つ。スレッドをまたいで同時には使わない）。
final class NativeVoiceActivity: @unchecked Sendable {
    private var model: OpaquePointer?
    private var session: OpaquePointer?

    init(modelURL: URL) throws {
        var load = transcribe_model_load_params()
        transcribe_model_load_params_init(&load)
        var status = transcribe_model_load_file(modelURL.path, &load, &model)
        guard status.rawValue == 0, model != nil else { throw NativeSpeechError.load(describe(status)) }
        var parameters = transcribe_vad_session_params()
        transcribe_vad_session_params_init(&parameters)
        status = transcribe_vad_session_init(model, &parameters, &session)
        guard status.rawValue == 0, session != nil else {
            transcribe_model_free(model)
            throw NativeSpeechError.load(describe(status))
        }
    }

    deinit {
        if let session { transcribe_vad_session_free(session) }
        if let model { transcribe_model_free(model) }
    }

    /// 音声（16 kHz・モノラル・float）を渡し、それで完成したフレームの確率を返す。
    func feed(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty, let session else { return [] }
        let status = samples.withUnsafeBufferPointer { transcribe_vad_stream_feed(session, $0.baseAddress, Int32($0.count)) }
        guard status.rawValue == 0 else { throw NativeSpeechError.run(describe(status)) }
        return probabilities()
    }

    /// 入力の終わり：端数を、0 で埋めて処理する（確率は、多くても 1 つ）。
    func flush() throws -> [Float] {
        guard let session else { return [] }
        let status = transcribe_vad_stream_flush(session)
        guard status.rawValue == 0 else { throw NativeSpeechError.run(describe(status)) }
        return probabilities()
    }

    private func probabilities() -> [Float] {
        guard let session else { return [] }
        var result = transcribe_vad_result()
        transcribe_vad_result_init(&result)
        guard transcribe_vad_get_result(session, &result).rawValue == 0, result.n_probs > 0, let probabilities = transcribe_vad_probs(session) else { return [] }
        return Array(UnsafeBufferPointer(start: probabilities, count: Int(result.n_probs)))
    }
}
