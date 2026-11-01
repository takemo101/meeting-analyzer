import Foundation

/// 話者の名付け（SPEC §3.15）：直前の会議の、声で分けた話者（話者 N）に、人間が名前を付ける。
extension MeetingController {
    /// 確定の結果。`failure`：確定できなかった理由（確定していない）。`warning`：確定したが、声を覚えられなかった理由。
    struct NamingOutcome: Equatable {
        var failure: String?
        var warning: String?
    }

    /// 名前を付けていない話者が、1 人以上いるか、または、音声が保存されていて分け直せるか（メニューの「話者の名付け…」を出す条件）。
    var canNameSpeakers: Bool {
        guard namingSession != nil else { return false }
        return namingSpeakers.contains { namedSpeakers[$0.id] == nil } || namingAudioAvailable
    }

    /// 名前の選択肢（出席者。ACTOR.md を選んでいなければ、空。自分で入力することもできる）。
    var nameCandidates: [String] {
        actorChoices.filter(\.present).map(\.name)
    }

    /// 話者 N に、名前を確定する。記録を書き直し、`speakers` の出来事を出す。
    /// `remember`：声紋を使うとき、その声を覚える（確定のあと。覚えられなくても、名前は確定したまま）。
    func confirmSpeakerName(_ id: Int, name: String, remember: Bool = false) async -> NamingOutcome {
        guard let session = namingSession else { return NamingOutcome(failure: "名付けできる会議がありません（次の会議を始めたあとは、名付けられません）") }
        switch await session.nameSpeakers([id: name]) {
        case .success(let named):
            // 確定している間に、別の会議へ替えた（名付けの対象が替わった）ら、画面の状態へは反映しない（記録は、すでに書き直されている）。
            guard namingSession === session else { return NamingOutcome() }
            for item in named.speakers { namedSpeakers[item.speaker] = item.name }
            var outcome = NamingOutcome()
            if remember, voiceprintsEnabled, let confirmed = named.speakers.first?.name {
                outcome.warning = rememberVoice(name: confirmed, embedding: await session.voiceEmbedding(of: id))
            }
            changed()
            refreshPastMeetings()
            return outcome
        case .failure(let error):
            return NamingOutcome(failure: error.message)
        }
    }

    /// 名付けの画面を開いたとき、名前のヒントを計算する（SPEC §3.13）：**判断モデルを選んでいて、ACTOR.md を読めて、相手の側の人がいるときだけ**。
    /// 名前の無い話者ごとに、長い発話を最大 20 件、判断モデルへ問い、確率の平均の上位 3 人を、ヒントにする（**名前は決めない**）。計算は、画面を止めない別のスレッドで行い、終わったらモデルを解放する。
    /// 1 回の名付けにつき 1 回だけ（開き直しても、計算し直さない）。失敗は、理由を画面に出す（名付けは、できる）。
    func computeNamingHints() async {
        guard state == .idle, let session = namingSession, hintState == .notRequested, let model = decisionModel, let file = actorFile else { return }
        guard case .success(let list) = ActorFile.load(path: file), !list.others.isEmpty else { return }
        hintState = .computing
        changed()
        var texts: [Int: [String]] = [:]
        for speaker in namingSpeakers where namedSpeakers[speaker.id] == nil { texts[speaker.id] = await session.speakerTexts(of: speaker.id) }
        let attendance = actorSelection.attendance, store = modelStore, factory = hintJudgeFactory
        let collected = texts
        let result: Result<[Int: [SpeakerHint]], Error> = await Task.detached(priority: .userInitiated) {
            do {
                let judge = try factory(model, store, list.others)
                let maker = SpeakerHintMaker(list: list, judge: judge, attendance: attendance)
                var hints: [Int: [SpeakerHint]] = [:]
                for (id, list) in collected.sorted(by: { $0.key < $1.key }) { hints[id] = try await maker.hints(for: list) }
                return .success(hints)
            } catch {
                return .failure(error)
            }
        }.value
        // 計算の間に、次の会議が始まった（名付けの対象が替わった）ら、捨てる。
        guard namingSession === session else { return }
        switch result {
        case .success(let hints):
            namingHints = hints
            hintState = .ready
        case .failure(let error):
            hintState = .failed("名前のヒントを出せません" + ((error as? DecisionModelError).map { "（\($0.message)）" } ?? ""))
        }
        changed()
    }

    /// 次の会議の開始のとき、名付けの対象を手放す（話者 N のままの人は、そのまま）。
    func clearNaming() {
        guard namingSession != nil || !namingSpeakers.isEmpty || previousSession != nil else { return }
        stopPlayback()
        namingSession = nil
        namingMeeting = nil
        previousSession = nil
        previousMeeting = nil
        namingSpeakers = []
        namedSpeakers = [:]
        namingCandidates = [:]
        voiceMatched = []
        namingHints = [:]
        hintState = .notRequested
        reseparation = .idle
        playbackFailure = nil
        changed()
    }
}
