import Testing
@testable import MeetingAnalyzerKit

@Suite("撮るウィンドウの選び方")
struct WindowPickerTests {
    private func window(_ bundle: String?, pid: Int32 = 100, layer: Int = 0, _ w: Double = 800, _ h: Double = 600, onScreen: Bool = true) -> WindowCandidate {
        WindowCandidate(bundleID: bundle, processID: pid, layer: layer, width: w, height: h, isOnScreen: onScreen)
    }

    @Test("画面に出ているものが先（別のデスクトップのほうが大きくても）。撮れなければ次を試せるよう、全部を返す")
    func prefersOnScreen() {
        let small = window("com.google.Chrome", 400, 300)
        let bigElsewhere = window("com.google.Chrome", 1600, 1000, onScreen: false)
        #expect(WindowPicker.ranked([bigElsewhere, small], bundleID: "com.google.Chrome", processIDs: []) == [1, 0])
    }

    @Test("画面に出ているものが無ければ、別のデスクトップ・フルスクリーンのものを撮る")
    func fallsBackToOffScreen() {
        let fullscreen = window("com.google.Chrome", 1600, 1000, onScreen: false)
        #expect(WindowPicker.ranked([fullscreen], bundleID: "com.google.Chrome", processIDs: []) == [0])
    }

    @Test("bundle ID が違っても、同じアプリのプロセスのウィンドウは、同じアプリとして扱う")
    func matchesByProcessID() {
        let child = window("com.google.Chrome.helper", pid: 4242)
        #expect(WindowPicker.ranked([child], bundleID: "com.google.Chrome", processIDs: [4242]) == [0])
        #expect(WindowPicker.ranked([child], bundleID: "com.google.Chrome", processIDs: [1]).isEmpty)
    }

    @Test("メニューや小さな部品（レイヤー 0 以外・小さすぎる）は撮らない")
    func ignoresNonWindows() {
        let candidates = [window("com.google.Chrome", layer: 25), window("com.google.Chrome", 30, 30), window("other.app")]
        #expect(WindowPicker.ranked(candidates, bundleID: "com.google.Chrome", processIDs: []).isEmpty)
    }
}
