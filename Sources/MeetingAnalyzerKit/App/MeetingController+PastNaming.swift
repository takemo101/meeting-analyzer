import Foundation

/// 名付けている会議の表示（題名・開始）。
struct NamingMeeting: Equatable {
    let sessionId: UUID
    let title: String
    let startedAt: Date
}

/// あとからの名付け（SPEC §3.16）：音声を保存した過去の会議を、名付けの写し（`speakers.json`）から戻して、名付けの対象にする。
extension MeetingController {
    /// 名付けの画面で選べる会議（直前の会議・音声を保存した過去の会議。新しい順。同じ会議は 1 つ）。
    struct NamingChoice: Equatable, Identifiable {
        let meeting: NamingMeeting
        /// 声で分けた話者の数と、名前が確定した数（分かるとき）。
        let speakers: Int?
        let named: Int?
        let isPrevious: Bool
        var id: UUID { meeting.sessionId }
    }

    var namingChoices: [NamingChoice] {
        var choices: [NamingChoice] = []
        if let previous = previousMeeting, previousSession != nil {
            choices.append(NamingChoice(meeting: previous, speakers: nil, named: nil, isPrevious: true))
        }
        for past in pastMeetings where past.sessionId != previousMeeting?.sessionId || previousSession == nil {
            choices.append(NamingChoice(meeting: NamingMeeting(sessionId: past.sessionId, title: past.title, startedAt: past.startedAt), speakers: past.speakers, named: past.named, isPrevious: false))
        }
        return choices.sorted { $0.meeting.startedAt > $1.meeting.startedAt }
    }

    /// メニューの「話者の名付け…」を出す条件：待機中で、直前の会議に名付け・分け直しができるか、音声を保存した過去の会議があるとき。
    var canOpenNaming: Bool {
        state == .idle && (canNameSpeakers || !pastMeetings.isEmpty)
    }

    func updatePastMeetings(_ meetings: [PastMeeting]) {
        guard meetings != pastMeetings else { return }
        pastMeetings = meetings
        changed()
    }

    /// あとから名付けできる会議の一覧を、数え直す（名前を確定したあと。確定した数を、選びに出すため）。
    func refreshPastMeetings() {
        let store = savedAudioStore
        Task.detached(priority: .utility) {
            let meetings = store.pastMeetings()
            await MainActor.run { self.updatePastMeetings(meetings) }
        }
    }

    /// 名付けの対象を、`session` に替える（要約・確定した名前・候補を読み込み、ヒント・分け直しの状態・再生を、初期化する）。声紋で名前が付いた話者の、最後に使った日を更新する。確定済みの名前（話者 N → 名前）を返す。
    @discardableResult
    func adoptNaming(_ session: any NamingTarget, meeting: NamingMeeting) async -> [Int: String] {
        stopPlayback()
        let summaries = await session.speakerSummaries()
        let matched = await session.speakerNames()
        namingSession = session
        namingMeeting = meeting
        namingSpeakers = summaries
        namedSpeakers = matched
        voiceMatched = Set(matched.keys)
        namingCandidates = await session.speakerCandidates()
        namingHints = [:]
        hintState = .notRequested
        reseparation = .idle
        playbackFailure = nil
        touchVoiceprints(Set(matched.values))
        changed()
        return matched
    }

    /// 名付けの画面で選んだ会議を開く。直前の会議は、そのまま。過去の会議は、名付けの写しから戻す（待機中だけ。音声・写しが無い・読めない・版が違うときは、理由を返す）。
    func openNaming(_ id: UUID) async -> String? {
        guard state == .idle else { return "会議の実行中は、名付けを開けません" }
        if namingMeeting?.sessionId == id, namingSession != nil { return nil }
        if let previous = previousSession, let meeting = previousMeeting, meeting.sessionId == id {
            await adoptNaming(previous, meeting: meeting)
            return nil
        }
        switch savedAudioStore.readSnapshot(sessionId: id) {
        case .failure(let error):
            return error.message
        case .success(let snapshot):
            let model = voiceModel
            let revision = model.flatMap { modelStore.isInstalled($0) ? $0.revision : nil }
            let library = model.flatMap { voiceprintLibrary(for: $0).library }
            guard let restored = RestoredSession(snapshot: snapshot, sink: hub, store: SessionStore(root: dataDirectory), currentModelRevision: revision, library: library) else {
                return "名付けの写しから、会議を戻せませんでした"
            }
            await adoptNaming(restored, meeting: NamingMeeting(sessionId: id, title: snapshot.title, startedAt: snapshot.startedDate))
            return nil
        }
    }
}
