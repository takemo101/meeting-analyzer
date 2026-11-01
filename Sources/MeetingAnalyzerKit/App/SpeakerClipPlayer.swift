import AVFoundation
import Foundation

/// 聞き直し（SPEC §3.16）：保存した相手の音声の、一部の区間を再生する。ネットワークは使わない（この Mac のファイルだけ）。
/// 同時に 1 か所だけ鳴らす（別の区間を押したら、前のものを止める）。区間の終わりで、自分で止まる。
@MainActor
final class SpeakerClipPlayer {
    /// いま鳴らしている区間の印（画面が、停止ボタンに替えるため）。
    private(set) var playingKey: String?
    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?
    /// 再生の状態が変わったときに呼ぶ処理。
    var onChange: (() -> Void)?

    /// `url` の音声の、`position` 秒から `duration` 秒を再生する。再生できなければ、理由を返す。
    func play(key: String, url: URL, position: TimeInterval, duration: TimeInterval) -> String? {
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            guard position < player.duration else { return "再生する区間が、音声の長さを超えています" }
            player.currentTime = position
            guard player.play() else { return "再生を始められませんでした" }
            self.player = player
            playingKey = key
            let length = min(duration, player.duration - position)
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0.2, length)))
                guard !Task.isCancelled else { return }
                self?.finish(key: key)
            }
            onChange?()
            return nil
        } catch {
            return "音声を再生できません"
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
        if playingKey != nil {
            playingKey = nil
            onChange?()
        }
    }

    private func finish(key: String) {
        guard playingKey == key else { return }
        stop()
    }
}
