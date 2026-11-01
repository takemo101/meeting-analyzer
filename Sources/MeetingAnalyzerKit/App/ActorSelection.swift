import Foundation

/// 会議で使う `ACTOR.md` の選択まわり（SPEC §3.13）：今日の出席者・会議が開始のときに読んだ一覧・設定ウィンドウに見せる状態・会議の開始のときの labeler の組み立て。
/// **選んだファイル・最近の一覧・ファイルごとの外した人は、`CapturePreferences`（`MeetingController` が持つ 1 つの値）にあり**、ここは、それを `inout` で受けて更新する（保存と通知は、呼び出し側）。
@MainActor
final class ActorSelection {
    /// 設定ウィンドウに見せる、選んだ `ACTOR.md` の状態。
    enum Status: Equatable {
        case none
        case loaded(count: Int, hasSelf: Bool, warnings: [String])
        case failed(String)
    }

    /// 出席者の選択肢の 1 人分（相手の側の人。本人は、出さない）。
    struct Choice: Equatable {
        let name: String
        let role: String?
        let present: Bool
    }

    /// 会議の開始のための結果：`ActorSource`（選んでいなければ無し）と、利用者へ知らせる理由（あれば）。
    struct Setup {
        var actors: ActorSource?
        var notice: String?
    }

    /// 今日の出席者（外した人）。会議の途中でも変えられ、名付けのヒントは、そのときの出席者を見る。
    let attendance = Attendance()
    /// 実行中の会議が、開始のときに読んだ一覧（会議の途中で、ファイルが書き換わっても、メニューは、会議が使っている一覧を見せる）。
    private var active: ActorList?

    /// 起動のとき：保存してあった、選んだファイルの外した人を、出席者に反映する。
    func restore(from preferences: CapturePreferences) {
        attendance.replace(excluded: Set(preferences.actorFile.flatMap { preferences.absentActors[$0] } ?? []))
    }

    /// `ACTOR.md` を選ぶ（`nil`＝外す）。最近の一覧へ入れ、出席者は、選んだファイルごとに覚えているものへ切り替える（別のファイルへ切り替えると、そのファイルで外した人に変わる）。
    func select(_ path: String?, in preferences: inout CapturePreferences) {
        preferences.actorFile = path
        if let path { preferences.remember(actorFile: path) }
        restore(from: preferences)
    }

    /// 出席者を、足す・外す。選んだファイルごとに、覚える（ファイルを選んでいなければ、何もしない）。**会議の実行中でも、呼べる**（次の判断から効く。すでに付いた名前は、付け直さない）。
    func setPresent(_ name: String, _ present: Bool, in preferences: inout CapturePreferences) -> Bool {
        guard let file = preferences.actorFile else { return false }
        attendance.setPresent(name, present)
        let absent = attendance.excludedNames
        preferences.absentActors[file] = absent.isEmpty ? nil : absent.sorted()
        return true
    }

    /// 選んだファイルを、いま読んで検査した結果（読むのは、設定ウィンドウの表示のときだけ。小さいファイル）。
    func status(file: String?) -> Status {
        guard let file else { return .none }
        switch ActorFile.load(path: file) {
        case .success(let list): return .loaded(count: list.actors.count, hasSelf: list.selfActor != nil, warnings: list.warnings)
        case .failure(let error): return .failed(error.message)
        }
    }

    /// 出席者の選択肢。会議の実行中は、開始のときに読んだ一覧。待機中は、選んだファイルを、いま読む（読めなければ、空）。
    func choices(file: String?, meetingRunning: Bool) -> [Choice] {
        let list: ActorList?
        if meetingRunning, let active {
            list = active
        } else if let file, case .success(let loaded) = ActorFile.load(path: file) {
            list = loaded
        } else {
            list = nil
        }
        return (list?.others ?? []).map { Choice(name: $0.name, role: $0.role, present: attendance.isPresent($0.name)) }
    }

    /// 会議で使う `ACTOR.md`（SPEC §3.13）。読めないときは、アクターなしで会議を始め、理由を知らせる（失敗を黙って捨てない）。
    /// 会議の最中に、「相手」の名前は付けない（判断モデルも、読み込まない）。「本人」の名前だけ、一覧の本人から付く。
    func prepare(file: String?) -> Setup {
        active = nil
        guard let file else { return Setup() }
        switch ActorFile.load(path: file) {
        case .failure(let error):
            return Setup(notice: "ACTOR.md を使えません: \(error.message)")
        case .success(let list):
            active = list
            return Setup(actors: ActorSource(list: list, file: file))
        }
    }
}
