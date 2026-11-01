import Foundation

/// 再分離と聞き直し（SPEC §3.16）：保存した相手の音声で、声の分離をやり直し、名付けの画面で、話者の抜粋を聞き直す。
extension MeetingController {
    /// 保存した声紋を、この分離モデルの版で使えるか確かめて読む。使えないときは、理由（画面・知らせに出す文）を添える。「声紋を使う」がオフなら、何も読まない。
    func voiceprintLibrary(for model: VoiceModel) -> (library: VoiceprintLibrary?, notice: String?) {
        guard voiceprintsEnabled else { return (nil, nil) }
        switch voiceprintStore.load() {
        case .none: return (nil, nil)
        case .loaded(let loaded) where loaded.modelRevision == model.revision: return (loaded, nil)
        case .loaded: return (nil, "保存した声紋は、別の版の分離モデルで作られているため、使いません（設定で削除して、覚え直してください）")
        case .unusable(let reason): return (nil, "声紋を使えません: \(reason)（ファイルは消していません）")
        }
    }

    /// 名付けの対象の会議の音声が、保存されているか（再分離・聞き直しができる条件）。
    var namingAudioAvailable: Bool {
        guard let session = namingSession else { return false }
        return savedAudioStore.exists(sessionId: session.sessionId)
    }

    /// 分け直せるか：音声が保存されていて、分離のモデルが取得済みで、分け直している最中でないとき。
    var canReseparate: Bool {
        guard namingAudioAvailable, reseparation != .running, let model = voiceModel else { return false }
        return modelStore.isInstalled(model)
    }

    /// 保存した音声で、声の分離をやり直す。`count`：話者の人数（`nil`＝自動。2〜8）。
    /// 成功すると、その会議の名前は、すべて外れ（記録を書き直し、`speakers` の出来事〔`reseparated`〕を出す）、声紋の照合から、やり直す。失敗したら、何も変えない。
    func reseparateSpeakers(count: Int?) async {
        guard let session = namingSession, reseparation != .running else { return }
        if let count, !VoiceSeparationTuning.speakerCountRange.contains(count) { return }
        guard let model = voiceModel, modelStore.isInstalled(model) else {
            reseparation = .failed("話者の分離のモデルが、取得されていません")
            changed()
            return
        }
        stopPlayback()
        reseparation = .running
        changed()
        let loaded = voiceprintLibrary(for: model)
        let separator = voiceSeparatorFactory(model, modelStore, VoiceSeparationTuning(speakerCount: count))
        let result = await session.reseparate(audio: savedAudioStore, separator: separator, library: loaded.library)
        // 分け直している間に、次の会議が始まった（名付けの対象が替わった）ら、捨てる。
        guard namingSession === session else { return }
        switch result {
        case .success:
            let summaries = await session.speakerSummaries()
            let matched = await session.speakerNames()
            namingSpeakers = summaries
            namedSpeakers = matched
            voiceMatched = Set(matched.keys)
            namingCandidates = await session.speakerCandidates()
            namingHints = [:]
            hintState = .notRequested
            touchVoiceprints(Set(matched.values))
            reseparation = .done(summaries.count)
            if let notice = loaded.notice { self.notice = notice }
        case .failure(let error):
            reseparation = .failed(error.message)
        }
        changed()
        if case .success = result { await computeNamingHints() }
    }

    // MARK: 聞き直し

    /// 話者 `speaker` の `index` 番目の抜粋を、保存した音声から再生する。同じ抜粋が鳴っている最中なら、止める。
    func toggleClip(speaker: Int, index: Int) {
        let key = "\(speaker)-\(index)"
        if clipPlayer.playingKey == key { stopPlayback(); return }
        playbackFailure = nil
        guard let session = namingSession, let summary = namingSpeakers.first(where: { $0.id == speaker }), summary.clips.indices.contains(index) else { return }
        let clip = summary.clips[index]
        switch savedAudioStore.timeline(sessionId: session.sessionId) {
        case .failure(let error):
            playbackFailure = error.message
        case .success(let timeline):
            guard let range = timeline.playback(start: clip.start, end: clip.end) else {
                playbackFailure = "この抜粋の音声が、見つかりません"
                break
            }
            playbackFailure = clipPlayer.play(key: key, url: savedAudioStore.audioURL(sessionId: session.sessionId), position: range.position, duration: range.duration)
        }
        changed()
    }

    func stopPlayback() {
        clipPlayer.stop()
    }
}
