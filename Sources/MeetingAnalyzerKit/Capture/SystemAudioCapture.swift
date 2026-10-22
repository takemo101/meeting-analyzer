import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// 取り込める会議アプリの 1 つ（システム音声の選択肢）。
public struct CaptureApp: Sendable, Equatable {
    public let bundleID: String
    public let name: String
}

/// 画面収録の権限。確認だけで、要求はしない（要求は、取り込みの開始が OS に対して行う）。
public enum ScreenRecordingPermission {
    public static var isGranted: Bool { CGPreflightScreenCaptureAccess() }
}

/// 選んだアプリのシステム音声の取り込み（「相手」）。他のアプリの音（動画・通知音）と、このアプリ自身の音は混ぜない。音声はメモリ上だけで扱い、書き出さない。
public final class SystemAudioCapture: NSObject, @unchecked Sendable {
    private var stream: SCStream?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private let queue = DispatchQueue(label: "dev.takemo101.meeting-analyzer.system-audio")

    public override init() { super.init() }

    /// 取り込める（音を出せる）アプリの一覧。画面収録の権限が未確認なら、OS の許可の確認が出る。
    public static func availableApps() async throws -> [CaptureApp] {
        let content = try await shareableContent()
        return content.applications
            .filter { !$0.bundleIdentifier.isEmpty && !$0.applicationName.isEmpty }
            .map { CaptureApp(bundleID: $0.bundleIdentifier, name: $0.applicationName) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.permissionDenied("画面収録が許可されていません（システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオの録音）: \(error.localizedDescription)")
        }
    }

    /// 取り込みを始める。`bundleIDs` のアプリが出す音だけを流す。
    public func start(bundleIDs: [String]) async throws -> AsyncStream<AVAudioPCMBuffer> {
        let content = try await Self.shareableContent()
        let apps = content.applications.filter { bundleIDs.contains($0.bundleIdentifier) }
        guard !apps.isEmpty else {
            throw CaptureError.targetNotFound("選んだアプリが起動していません: \(bundleIDs.joined(separator: ", "))")
        }
        guard let display = content.displays.first else {
            throw CaptureError.targetNotFound("画面が見つかりません")
        }
        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // 映像は使わない（画面の取り込みは別）。負荷を最小にする。
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let (audio, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .unbounded)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            continuation.finish()
            throw CaptureError.failed("システム音声の取り込みを始められません: \(error.localizedDescription)")
        }
        self.stream = stream
        self.continuation = continuation
        return audio
    }

    public func stop() async {
        let stream = self.stream
        self.stream = nil
        try? await stream?.stopCapture()
        continuation?.finish()
        continuation = nil
    }
}

extension SystemAudioCapture: SCStreamOutput, SCStreamDelegate {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        continuation?.yield(buffer)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        continuation?.finish()
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
