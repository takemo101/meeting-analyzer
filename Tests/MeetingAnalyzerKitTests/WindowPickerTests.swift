import Testing
@testable import MeetingAnalyzerKit

@Suite("撮るウィンドウの選び方")
struct WindowPickerTests {
    private func window(_ bundle: String?, pid: Int32 = 100, layer: Int = 0, _ w: Double = 800, _ h: Double = 600, onScreen: Bool = true) -> WindowCandidate {
        WindowCandidate(bundleID: bundle, processID: pid, layer: layer, width: w, height: h, isOnScreen: onScreen)
    }

    @Test("画面に出ているものが先（別のデスクトップのほうが大きくても）。撮れなければ次を試せるよう、全部を返す")
    func prefersOnScreen() {
        let small = window("com.google.Chrome", 1000, 700)
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

    @Test("本体が別のデスクトップ（フルスクリーン）にあるあいだ、画面に出ている細い補助のウィンドウ（上端の帯など）は撮らない。本体の大きさの 2 割に満たないものは、候補にしない")
    func ignoresThinAuxiliaryWindows() {
        let fullscreenVideo = window("com.google.Chrome", 1568, 863, onScreen: false)
        let toolbarStrip = window("com.google.Chrome", 1568, 98)
        #expect(WindowPicker.ranked([toolbarStrip, fullscreenVideo], bundleID: "com.google.Chrome", processIDs: []) == [1], "細い帯は、画面に出ていても、候補にしない")
        let secondWindow = window("com.google.Chrome", 900, 600)
        #expect(WindowPicker.ranked([fullscreenVideo, secondWindow], bundleID: "com.google.Chrome", processIDs: []) == [1, 0], "同じくらいの大きさ（2 割以上）の別のウィンドウは、候補に残る（画面に出ているものが先）")
        #expect(WindowPicker.ranked([toolbarStrip], bundleID: "com.google.Chrome", processIDs: []) == [0], "ほかに無ければ、そのウィンドウ")
    }
}
