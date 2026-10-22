import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MeetingAnalyzerKit

/// 単色の画像（任意で、一部に別の色の四角）。画面の代わり。
func makeImage(width: Int = 1920, height: Int = 1080, gray: UInt8 = 200, patch: (x: Int, y: Int, w: Int, h: Int, gray: UInt8)? = nil) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.setFillColor(gray: CGFloat(gray) / 255, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if let patch {
        context.setFillColor(gray: CGFloat(patch.gray) / 255, alpha: 1)
        context.fill(CGRect(x: patch.x, y: patch.y, width: patch.w, height: patch.h))
    }
    return context.makeImage()!
}

private func signature(_ image: CGImage) -> ScreenSignature { ImageTools.signature(of: image)! }

@Suite("ScreenChange: 画面に変化があったかの規則")
struct ScreenChangeTests {
    @Test("最初は、常に変化あり。同じ画面は、変化なし")
    func firstAndSame() {
        let base = signature(makeImage())
        #expect(ScreenChange.hasChanged(from: nil, to: base))
        #expect(!ScreenChange.hasChanged(from: base, to: signature(makeImage())))
    }

    @Test("画面の一部（動画のような、小さな四角）の変化も、変化とみなす")
    func partialChange() {
        let before = signature(makeImage())
        let video = signature(makeImage(patch: (x: 1200, y: 300, w: 480, h: 270, gray: 40)))
        #expect(ScreenChange.hasChanged(from: before, to: video))
    }

    @Test("ごく小さな変化（時計の秒のような）と、全体のわずかな明るさの揺れは、変化としない")
    func tinyChangeIsIgnored() {
        let before = signature(makeImage())
        #expect(!ScreenChange.hasChanged(from: before, to: signature(makeImage(patch: (x: 100, y: 100, w: 30, h: 15, gray: 20)))))
        #expect(!ScreenChange.hasChanged(from: before, to: signature(makeImage(gray: 190))))
    }

    @Test("全体が変わった（別の画面）なら、変化あり")
    func wholeChange() {
        #expect(ScreenChange.hasChanged(from: signature(makeImage(gray: 230)), to: signature(makeImage(gray: 30))))
    }
}

@Suite("ScreenshotGate: 画像を保存してよいかの規則")
struct ScreenshotGateTests {
    private let base = signature(makeImage())
    private let changed = signature(makeImage(gray: 30))

    @Test("最初は、間隔も変化も問わず、保存してよい。通し番号は 1 から")
    func firstIsAlwaysOpen() {
        let gate = ScreenshotGate(minGap: 10)
        #expect(gate.isOpen(at: 0) && gate.hasChanged(base) && gate.nextIndex == 1 && gate.savedCount == 0)
    }

    @Test("保存すると、間隔（minGap 秒）の間は閉じ、変化の無い画面は保存しない。番号が進む")
    func gapAndChange() {
        var gate = ScreenshotGate(minGap: 10)
        gate.didSave(base, at: 5)
        #expect(gate.savedCount == 1 && gate.nextIndex == 2)
        #expect(!gate.isOpen(at: 14.9) && gate.isOpen(at: 15), "ちょうど minGap 秒で、開く")
        #expect(!gate.hasChanged(base), "同じ画面は、変化なし")
        #expect(gate.hasChanged(changed))
        gate.didSave(changed, at: 15)
        #expect(gate.nextIndex == 3 && !gate.hasChanged(changed) && gate.hasChanged(base), "比べる相手は、最後に保存した画面")
    }

    @Test("minGap が 0 なら、いつでも開く")
    func zeroGap() {
        var gate = ScreenshotGate(minGap: 0)
        gate.didSave(base, at: 3)
        #expect(gate.isOpen(at: 3))
    }
}

@Suite("ImageTools / ScreenshotStore")
struct ScreenshotFilesTests {
    @Test("JPEG は、長い辺を 1280 以下に縮め、読み戻せる。小さい画像は、そのまま")
    func jpeg() throws {
        let big = try #require(ImageTools.jpegData(of: makeImage(width: 3000, height: 1500)))
        let small = try #require(ImageTools.jpegData(of: makeImage(width: 800, height: 600)))
        func size(_ data: Data) throws -> (Int, Int) {
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
        }
        #expect(try size(big) == (1280, 640))
        #expect(try size(small) == (800, 600))
        #expect(big.prefix(2) == Data([0xFF, 0xD8]), "JPEG の先頭")
    }

    @Test("保存は、ディレクトリ 0700・ファイル 0600。最新の keep 枚だけ残し、終了で全部消す")
    func store() throws {
        let root = tempURL("shots")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScreenshotStore(root: root, keep: 3)
        let session = UUID()
        var urls: [URL] = []
        for index in 1...5 { urls.append(try store.save(Data([0xFF, 0xD8, UInt8(index)]), sessionId: session, index: index).get()) }
        #expect((try FileManager.default.attributesOfItem(atPath: urls[4].path)[.posixPermissions] as? Int) == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: urls[4].deletingLastPathComponent().path)[.posixPermissions] as? Int) == 0o700)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: urls[4].deletingLastPathComponent().path).sorted()
        #expect(remaining == ["shot-0003.jpg", "shot-0004.jpg", "shot-0005.jpg"])
        store.deleteAll(sessionId: session)
        #expect(!FileManager.default.fileExists(atPath: urls[4].deletingLastPathComponent().path))
    }

    @Test("書けない場所は、失敗として返す")
    func writeFailure() {
        let result = ScreenshotStore(root: URL(fileURLWithPath: "/dev/null/nope")).save(Data([1]), sessionId: UUID(), index: 1)
        #expect(throws: ScreenshotStoreError.writeFailed) { try result.get() }
    }

    @Test("画面の画像のパスは、あるときだけ JSON に出る")
    func eventShape() throws {
        let with = TranscriptEvent.captions(sessionId: "s", sequence: 1, updates: [], screenshot: "/x/shot-0001.jpg")
        let without = TranscriptEvent.captions(sessionId: "s", sequence: 2, updates: [])
        let a = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(with)) as? [String: Any])
        let b = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(without)) as? [String: Any])
        #expect(a["screenshot"] as? String == "/x/shot-0001.jpg")
        #expect(b["screenshot"] == nil)
        #expect(try JSONDecoder().decode(TranscriptEvent.self, from: JSONEncoder().encode(with)) == with)
    }
}

/// 次に返す画像を、外から決められる偽の画面。
final class FakeScreen: @unchecked Sendable {
    private let lock = NSLock()
    private var image = makeImage()
    private var error: Error?
    private(set) var calls = 0

    func show(_ image: CGImage) { lock.withLock { self.image = image } }
    func fail(_ error: Error?) { lock.withLock { self.error = error } }
    var feed: ScreenFeed {
        ScreenFeed { [self] in
            try lock.withLock {
                calls += 1
                if let error { throw error }
                return image
            }
        }
    }
}

@Suite("LiveSession: 画面の取り込み")
struct LiveSessionScreenTests {
    private func session(_ screen: FakeScreen?, sink: RecordingSink, store: ScreenshotStore?, fake: FakeInputs = FakeInputs(), minGap: TimeInterval = 0, notify: @escaping @Sendable (LiveSessionNotice) -> Void = { _ in }) -> LiveSession {
        LiveSession(
            title: "t", speakers: [.others], inputs: fake.inputs, sink: sink, store: nil,
            tickInterval: .seconds(60), screen: screen?.feed, screenshots: store, screenInterval: .milliseconds(20), screenMinGap: minGap, notify: notify
        )
    }

    private func tempStore() -> (ScreenshotStore, URL) {
        let root = tempURL("shots")
        return (ScreenshotStore(root: root), root)
    }

    private func screenshots(_ sink: RecordingSink) -> [String] {
        sink.events.compactMap { if case .captions(_, _, _, let path) = $0 { return path } else { return nil } }
    }

    @Test("開始で最初の 1 枚を撮り、次のバッチへ添える。同じ画面は、もう添えない。変わったら、また添える")
    func attachesFirstAndChanges() async throws {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = FakeScreen(), sink = RecordingSink(), fake = FakeInputs()
        let live = session(screen, sink: sink, store: store, fake: fake)
        try await live.start()
        fake.emit(.others, "一つ目の話題です", final: true, 0, 1)
        try await live.pause()
        #expect(screenshots(sink).count == 1 && screenshots(sink)[0].hasSuffix("shot-0001.jpg"), "最初の 1 枚")

        screen.show(makeImage(patch: (x: 1000, y: 200, w: 600, h: 400, gray: 30)))
        try await live.resume()
        for _ in 0..<100 where (try? FileManager.default.contentsOfDirectory(atPath: store.directory(sessionId: live.sessionId).path))?.count != 2 { try await Task.sleep(for: .milliseconds(20)) }
        fake.emit(.others, "二つ目の話題です", final: true, 0, 1)
        try await live.pause()
        #expect(screenshots(sink).count == 2 && screenshots(sink)[1].hasSuffix("shot-0002.jpg"), "変わった画面")

        try await live.resume()
        try await Task.sleep(for: .milliseconds(150))
        fake.emit(.others, "三つ目の話題です", final: true, 0, 1)
        _ = try await live.end(reason: .user)
        #expect(screenshots(sink).count == 2, "同じ画面は、添えない（バッチは 3 つ目があるのに、画像は 2 枚のまま）")
        #expect(sink.events.filter { $0.kind == "captions" }.count == 3)
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: store.directory(sessionId: live.sessionId).path)) ?? []
        #expect(kept.sorted() == ["shot-0001.jpg", "shot-0002.jpg"], "終了のあとも、画像は残る（`retentionDays` 日たつまで。エージェントが、あとから開ける）")
    }

    @Test("前の保存から指定の秒数がたつまでは、画面が変わっても、新しい画像を作らない")
    func minimumGap() async throws {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = FakeScreen(), sink = RecordingSink()
        let live = session(screen, sink: sink, store: store, minGap: 3600)
        try await live.start()
        screen.show(makeImage(gray: 20))
        try await Task.sleep(for: .milliseconds(200))
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory(sessionId: live.sessionId).path)
        _ = try await live.end(reason: .user)
        #expect(files == ["shot-0001.jpg"])
    }

    @Test("開始のときに撮れなければ（権限なし）、何も始めず、開いた取り込みも無く、画像も残らない")
    func startFailsWithoutScreenPermission() async {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = FakeScreen(), sink = RecordingSink(), fake = FakeInputs()
        screen.fail(CaptureError.permissionDenied(.screenRecording, "画面収録"))
        let live = session(screen, sink: sink, store: store, fake: fake)
        await #expect(throws: LiveSessionError.capture(.permissionDenied(.screenRecording, "画面収録"))) { try await live.start() }
        #expect(fake.opened.isEmpty && sink.events.isEmpty)
        #expect(await live.phase == .idle)
    }

    @Test("実行中に撮れなくなっても、字幕の転送は続き、知らせは 1 回だけ")
    func failureWhileRunningContinues() async throws {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = FakeScreen(), sink = RecordingSink(), fake = FakeInputs(), notices = Notices()
        let live = session(screen, sink: sink, store: store, fake: fake, notify: { notices.add($0) })
        try await live.start()
        screen.fail(CaptureError.failed("ウィンドウが無い"))
        // 知らせが出るのを待つ（遅い環境でも通るよう、固定の待ちでなく、出るまで確かめる）。そのあと、2 回目が出ないことを見るため、少し待つ。
        for _ in 0..<300 where notices.all.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(150))
        fake.emit(.others, "字幕は届く", final: true, 0, 1)
        let outcome = try await live.end(reason: .user)
        #expect(outcome.utterances == 1)
        #expect(sink.events.contains { if case .captions = $0 { return true } else { return false } })
        #expect(notices.all == [.screenshotFailed("ウィンドウが無い")])
    }

    @Test("画面を選んでいなければ、撮らず、画像も添えない")
    func noScreenNoShots() async throws {
        let sink = RecordingSink(), fake = FakeInputs()
        let live = session(nil, sink: sink, store: nil, fake: fake)
        try await live.start()
        fake.emit(.others, "音声だけ", final: true, 0, 1)
        _ = try await live.end(reason: .user)
        #expect(screenshots(sink).isEmpty)
    }
}


@Suite("ScreenshotStore: 終了後の保持（7 日）")
struct ScreenshotRetentionTests {
    private func makeStore() -> (ScreenshotStore, URL) {
        let root = tempURL("retention")
        return (ScreenshotStore(root: root), root)
    }

    private func seed(_ store: ScreenshotStore, daysAgo: Double, now: Date) throws -> UUID {
        let id = UUID()
        let url = try store.save(Data([0xFF, 0xD8, 1]), sessionId: id, index: 1).get()
        let when = now.addingTimeInterval(-daysAgo * 86_400)
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: url.deletingLastPathComponent().path)
        return id
    }

    @Test("7 日以上たったセッションの画像だけを消す。ちょうど 7 日は消し、6 日は残す。消した数を返す")
    func deletesOnlyExpired() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let old = try seed(store, daysAgo: 8, now: now), edge = try seed(store, daysAgo: 7, now: now), recent = try seed(store, daysAgo: 6, now: now), today = try seed(store, daysAgo: 0, now: now)
        #expect(store.deleteExpired(now: now) == 2)
        func exists(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: store.directory(sessionId: id).path) }
        #expect(!exists(old) && !exists(edge) && exists(recent) && exists(today))
        #expect(store.deleteExpired(now: now) == 0, "2 回目は、何も消さない")
    }

    @Test("実行中のセッションは、古くても消さない。screens/ の下の、UUID でない名前・ファイルには触れない。画像が無くても、失敗しない")
    func skipsActiveAndForeign() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.deleteExpired() == 0, "screens/ が無くても、失敗しない")
        let now = Date()
        let active = try seed(store, daysAgo: 30, now: now)
        let screens = root.appendingPathComponent("screens", isDirectory: true)
        let foreign = screens.appendingPathComponent("not-a-session", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30 * 86_400)], ofItemAtPath: foreign.path)
        try Data([1]).write(to: screens.appendingPathComponent("loose.jpg"))
        #expect(store.deleteExpired(now: now, except: active) == 0)
        #expect(FileManager.default.fileExists(atPath: store.directory(sessionId: active).path) && FileManager.default.fileExists(atPath: foreign.path))
        #expect(store.deleteExpired(now: now) == 1, "実行中でなければ、30 日前のものは消える")
    }
}

/// 内容（暗い灰色）の周りに、白（または透明）の帯を持つ画像。上＝画像の上端、右＝画像の右端。
func makeBandedImage(width: Int = 1568, height: Int = 863, top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0, transparent: Bool = false) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if !transparent {
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    // CoreGraphics は、左下が原点。画像の上端は、y の大きいほう。
    context.setFillColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1)
    context.fill(CGRect(x: left, y: bottom, width: width - left - right, height: height - top - bottom))
    return context.makeImage()!
}

@Suite("描きかけの画像の帯の切り落としと、保存してよい状態の判断")
struct ScreenStabilityTests {
    @Test("片側だけの白い帯（フルスクリーンの動画の、上と右）は、描きかけの帯。透明な帯も同じ。反対側が内容の、下だけ・左だけの帯も")
    func detectsOneSidedBand() {
        #expect(ImageTools.hasUnrenderedBand(makeBandedImage(top: 45, right: 83)))
        #expect(ImageTools.hasUnrenderedBand(makeBandedImage(top: 45, right: 83, transparent: true)), "透明も、空白")
        #expect(ImageTools.hasUnrenderedBand(makeBandedImage(bottom: 60)))
        #expect(ImageTools.hasUnrenderedBand(makeBandedImage(left: 90)))
    }

    @Test("四方が白い余白の画面（書類・スライド）や、内容が端まである画面は、帯ではない")
    func normalScreens() {
        #expect(!ImageTools.hasUnrenderedBand(makeBandedImage(top: 70, bottom: 70, left: 90, right: 90)), "四方が白い余白")
        #expect(!ImageTools.hasUnrenderedBand(makeBandedImage()), "端まで内容")
        #expect(!ImageTools.hasUnrenderedBand(makeImage()), "単色の灰色")
        #expect(!ImageTools.hasUnrenderedBand(makeBandedImage(top: 6)), "細い帯（1 行分に満たない）は、無視する")
    }

    @Test("実際の画面の比率（上が高さの 5.2%、右が幅の 5.3%。格子の 1 マスより少し太いだけ）でも、帯を見つけて切り落とす")
    func findsBandsAtRealProportions() {
        let image = makeBandedImage(width: 2562, height: 1410, top: 73, right: 136)
        #expect(ImageTools.hasUnrenderedBand(image))
        let trimmed = ImageTools.trimmingUnrenderedBands(image)
        #expect(trimmed.width == 2562 - 136 && trimmed.height == 1410 - 73, "\(trimmed.width)x\(trimmed.height)")
    }

    @Test("帯だけを切り落とす：上 45・右 83 の帯が付いた画像は、内容の大きさ（1485×818）になり、内容の色は残る。透明な帯も、同じ")
    func trimsTheBands() throws {
        for transparent in [false, true] {
            let trimmed = ImageTools.trimmingUnrenderedBands(makeBandedImage(top: 45, right: 83, transparent: transparent))
            #expect(trimmed.width == 1568 - 83 && trimmed.height == 863 - 45, "transparent=\(transparent): \(trimmed.width)x\(trimmed.height)")
            // 切り落とし後の中央の画素は、内容の色（0.2, 0.3, 0.5 付近）。
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(trimmed, in: CGRect(x: -trimmed.width / 2, y: -trimmed.height / 2, width: trimmed.width, height: trimmed.height))
            #expect(abs(Int(pixel[0]) - 51) <= 3 && abs(Int(pixel[2]) - 128) <= 3, "\(pixel)")
        }
        let bottomLeft = ImageTools.trimmingUnrenderedBands(makeBandedImage(bottom: 60, left: 90))
        #expect(bottomLeft.width == 1568 - 90 && bottomLeft.height == 863 - 60, "下と左の帯も、同じ")
    }

    @Test("帯でない画像は、そのまま（四方が白い余白・端まで内容）。内容を失う誤判定は、元の画像に戻す（切り落とすと半分に満たない）")
    func leavesOtherImagesAlone() {
        let margins = makeBandedImage(top: 70, bottom: 70, left: 90, right: 90)
        #expect(ImageTools.trimmingUnrenderedBands(margins).width == margins.width && ImageTools.trimmingUnrenderedBands(margins).height == margins.height)
        let full = makeBandedImage()
        #expect(ImageTools.trimmingUnrenderedBands(full).width == full.width)
        let mostlyBlank = makeBandedImage(width: 400, height: 400, top: 250)
        #expect(ImageTools.trimmingUnrenderedBands(mostlyBlank).height == 400, "切り落とすと、高さが半分に満たない：元のまま")
        let whiteHeader = makeBandedImage(width: 1000, height: 800, top: 200)
        #expect(ImageTools.trimmingUnrenderedBands(whiteHeader).height == 800, "辺の 15% を超える空白（白い書類の上部など）は、帯でなく内容：切り落とさない")
    }

    @Test("大きさが変わったときは、待つ。続けて 2 回まで。そのあとは、保存する（大きさが変わり続ける窓でも、いつまでも、保存しなくならない）")
    func holdsThenSettles() {
        var stability = ScreenStability()
        func settled(_ width: Int, _ height: Int) -> Bool { stability.isSettled(width: width, height: height) }
        let results = [settled(1000, 600), settled(1000, 600), settled(1568, 863), settled(1568, 863), settled(1000, 600), settled(1568, 863), settled(1000, 600), settled(1568, 863)]
        // 最初・同じ：保存 → 変わった：待つ → 同じ：保存 → 変わり続ける：2 回待って、3 回目で保存 → また変わった：待つ
        #expect(results == [true, true, false, true, false, false, true, false])
    }
}

@Suite("LiveSession: フルスクリーンの動画の画像")
struct LiveSessionStabilityTests {
    @Test("大きさが変わった画像は、すぐには保存せず、次の確認で保存する。上と右に空白の帯がある画像は、帯を切り落として、保存する")
    func waitsAndTrims() async throws {
        let root = tempURL("stability")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScreenshotStore(root: root), screen = FakeScreen(), sink = RecordingSink(), fake = FakeInputs()
        let live = LiveSession(
            title: "t", speakers: [.others], inputs: fake.inputs, sink: sink, store: nil, tickInterval: .seconds(60),
            screen: screen.feed, screenshots: store, screenInterval: .milliseconds(15), screenMinGap: 0, notify: { _ in }
        )
        func directory() -> String { store.directory(sessionId: live.sessionId).path }
        func saved() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: directory()))?.count ?? 0 }
        func waitFor(_ count: Int) async throws { for _ in 0..<300 where saved() < count { try await Task.sleep(for: .milliseconds(10)) } }
        func pixelSize(_ name: String) throws -> (Int, Int) {
            let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: directory() + "/" + name) as CFURL, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
        }

        try await live.start()
        #expect(saved() == 1, "最初の 1 枚")
        let before = screen.calls
        screen.show(makeImage(width: 1568, height: 863, gray: 40, patch: (x: 100, y: 100, w: 800, h: 400, gray: 220)))
        try await waitFor(2)
        #expect(saved() == 2 && screen.calls - before >= 2, "大きさが変わった最初の確認では保存せず、次の確認で保存した")

        screen.show(makeBandedImage(width: 1568, height: 863, top: 45, right: 83))
        try await waitFor(3)
        #expect(saved() == 3)
        let (width, height) = try pixelSize("shot-0003.jpg")
        let ratio = Double(width) / Double(height)
        #expect(abs(ratio - Double(1568 - 83) / Double(863 - 45)) < 0.02, "帯を切り落とした内容の比率（約 1.815）で、保存された: \(width)x\(height)")
        _ = try await live.end(reason: .user)
    }
}
