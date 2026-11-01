import Foundation

/// 相手の音声の保存（SPEC §3.16）：設定のオン・オフと、保存した音声の削除。保存そのものは、会議の終了の処理（`LiveSession`）が行う。
extension MeetingController {
    /// 「相手の音声を保存する」を、オン・オフする。オンにできるのは、声による話者の分離がオンのときだけ。会議の実行中は、変えられない。
    func setSaveOthersAudio(_ enabled: Bool) {
        if enabled { guard voiceSeparation else { return } }
        mutateWhenIdle { $0.saveOthersAudio = enabled }
    }

    /// 保存した音声を、すべて消す（記録・声紋は残す）。実行中の会議の音声は、終了まで書かれないので、巻き込まない。
    func deleteSavedAudio() {
        let store = savedAudioStore
        Task.detached(priority: .utility) {
            let removed = store.deleteAll()
            let summary = store.summary()
            await MainActor.run {
                self.updateSavedAudio(summary)
                self.notice = removed == 0 ? "保存した音声は、ありませんでした" : "保存した音声を \(removed) 件、削除しました"
                self.changed()
            }
        }
    }

    func updateSavedAudio(_ summary: SavedAudioSummary) {
        guard summary != savedAudio else { return }
        savedAudio = summary
        changed()
    }
}
