import Foundation

extension String {
    /// 空なら `nil`。
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// 声紋（SPEC §3.15）：保存した声の特徴の、使う・使わない・一覧・削除・覚える。保存は `VoiceprintStore`（名前と声の特徴だけ。音声は含まない）。
extension MeetingController {
    /// 設定ウィンドウの一覧の 1 行。
    struct VoiceprintRow: Equatable {
        let name: String
        let vectorCount: Int
        let lastUsed: Date
    }

    /// 保存した声紋の一覧（名前の順）。読めないときは空。
    var voiceprintRows: [VoiceprintRow] {
        guard case .loaded(let library) = voiceprintState else { return [] }
        return library.people.map { VoiceprintRow(name: $0.name, vectorCount: $0.vectors.count, lastUsed: $0.lastUsed) }.sorted { $0.name < $1.name }
    }

    /// 声紋のファイルを使えない理由（壊れている・知らない書式）。使えるとき・無いときは `nil`。ファイルは消さない。
    var voiceprintProblem: String? {
        if case .unusable(let reason) = voiceprintState { return reason }
        return nil
    }

    /// 声紋を使う・使わない。オンにできるのは、声による話者の分離がオンのときだけ。会議の実行中は、変えられない。
    func setVoiceprints(_ enabled: Bool) {
        if enabled { guard voiceSeparation else { return } }
        mutateWhenIdle { $0.voiceprints = enabled }
    }

    func refreshVoiceprints() {
        voiceprintState = voiceprintStore.load()
        changed()
    }

    /// 1 人の声紋を削除する。
    func deleteVoiceprint(_ name: String) {
        guard case .loaded(var library) = voiceprintStore.load() else { return }
        library.remove(name: name)
        do { try voiceprintStore.save(library) } catch { notice = "声紋を削除できませんでした" }
        refreshVoiceprints()
    }

    /// 声紋を、すべて削除する（壊れていて読めないファイルも、消える）。
    func deleteAllVoiceprints() {
        do { try voiceprintStore.save(VoiceprintLibrary(modelRevision: voiceModel?.revision ?? "")) } catch { notice = "声紋を削除できませんでした" }
        refreshVoiceprints()
    }

    /// 声紋で名前が付いた人の、最後に使った日を更新する（一覧に出す。失敗しても、会議には影響しない）。
    func touchVoiceprints(_ names: Set<String>) {
        guard !names.isEmpty, case .loaded(var library) = voiceprintStore.load() else { return }
        let now = Date()
        for name in names { library.touch(name: name, now: now) }
        try? voiceprintStore.save(library)
        refreshVoiceprints()
    }

    /// 確定した名前に、その話者の声の特徴を結んで、保存する。**失敗は、理由の文を返す**（名前の確定は、すでに済んでいる。SPEC §3.15）。成功なら `nil`。
    func rememberVoice(name: String, embedding: [Float]?) -> String? {
        guard let embedding else { return "この話者の声の特徴を取れなかったので、声は覚えられませんでした" }
        guard let model = voiceModel else { return "分離のモデルが無いので、声は覚えられませんでした" }
        var library: VoiceprintLibrary
        switch voiceprintStore.load() {
        case .none: library = VoiceprintLibrary(modelRevision: model.revision)
        case .loaded(let loaded) where loaded.modelRevision == model.revision: library = loaded
        case .loaded: return "保存した声紋は、別の版の分離モデルで作られているため、声は覚えられませんでした（設定で削除してから、覚え直してください）"
        case .unusable(let reason): return "声紋のファイルを使えないため、声は覚えられませんでした（\(reason)）"
        }
        do {
            try library.add(name: name, vector: embedding, now: Date())
            try voiceprintStore.save(library)
        } catch VoiceprintLibrary.AddError.full {
            return "声紋が \(VoiceprintLibrary.maxPeople) 人に達しているため、声は覚えられませんでした（設定で削除してください）"
        } catch {
            return "声は覚えられませんでした（保存できません）"
        }
        refreshVoiceprints()
        return nil
    }
}
