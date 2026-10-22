import AVFoundation
import Foundation

/// 取り込みに要る OS の権限。
public enum CapturePermission: Sendable, Equatable {
    case microphone
    case screenRecording

    /// システム設定の、その権限のページ。
    public var settingsURL: URL {
        switch self {
        case .microphone: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .screenRecording: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }
}

public enum CaptureError: Error, Sendable, Equatable {
    /// 権限（マイク・画面収録）がない。取り込みを始めない。
    case permissionDenied(CapturePermission, String)
    /// 取り込みの対象（会議アプリ・画面）が見つからない。
    case targetNotFound(String)
    /// 取り込みを始められない・途中で止まった。
    case failed(String)
}

/// マイクの取り込み（「本人」）。ボイス処理（エコー除去）を有効にして、音声のバッファを流す。音声はメモリ上だけで扱い、書き出さない。
public final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    /// マイクの権限が、すでに許可されているか。確認だけで、要求はしない。
    public static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    private var running = false

    public init() {}

    /// 取り込みを始める。マイクの権限が未確認なら、OS の許可の確認が出る（利用者の開始の操作の中だけで呼ぶ）。
    public func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw CaptureError.permissionDenied(.microphone, "マイクの使用が許可されていません。システム設定 > プライバシーとセキュリティ > マイク で、meeting-analyzer をオンにしてください。\n\nすでにオンでも、アプリを入れ直す（just install）と、許可が無効になります（署名が ad-hoc で、ビルドごとに変わるため）。その場合は、一覧から meeting-analyzer を一度削除（−）して、もう一度開始してください（許可の確認が出ます）。")
        }
        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            throw CaptureError.failed("ボイス処理（エコー除去）を有効にできません: \(error.localizedDescription)")
        }
        // ボイス処理は、他のアプリの音（会議の相手の声）を下げる。相手の声を小さくしないよう、下げ幅を最小にする。
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .unbounded)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.failed("マイクの入力形式を取得できません")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            continuation.yield(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            throw CaptureError.failed("マイクの取り込みを始められません: \(error.localizedDescription)")
        }
        running = true
        terminate = { continuation.finish() }
        return stream
    }

    private var terminate: (@Sendable () -> Void)?

    public func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        terminate?()
        terminate = nil
    }
}
