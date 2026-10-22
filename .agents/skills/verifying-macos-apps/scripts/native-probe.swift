// Small probes for macOS UI checks that a project's own runner usually does not cover: window
// edge resizing, wheel scrolling, accessibility presses, and blur/transparency against a controlled
// backdrop. Each command is one observation; nothing here decides pass or fail for a requirement.
// It uses only system frameworks and is a reference implementation, not an automation framework.
//
// Build once (from the skill directory):  swiftc -O scripts/native-probe.swift -o /tmp/native-probe
// or run it directly:
//   swift scripts/native-probe.swift windows [--owner NAME]
//   swift scripts/native-probe.swift region-clear --rect X,Y,W,H --backdrop-pid PID [--allow-pid PID ...]
//   swift scripts/native-probe.swift drag  --window-id ID --pid PID --edge bottom|top|left|right|title --by PX [--dx PX]
//   swift scripts/native-probe.swift wheel --window-id ID --pid PID --dy PIXELS
//   swift scripts/native-probe.swift press --pid PID --title TEXT [--role AXCheckBox]
//   swift scripts/native-probe.swift backdrop [--seconds 60]   (prints its pid; covers the main display;
//                                                                run the compiled binary so the pid is the probe's)
//   swift scripts/native-probe.swift sharpness PNG
//
// `drag` and `wheel` only post an event after the front-most window under the pointer is the named
// window (so a window stacked above it cannot receive the input). They need Accessibility and
// event-posting access for the host that runs them and never change any OS setting.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct Win {
    var id: Int
    var pid: Int32
    var owner: String
    var title: String
    var x: Double, y: Double, w: Double, h: Double
    var onscreen: Bool
    var layer: Int
    var alpha: Double
    var frame: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// Windows from front to back, as CoreGraphics lists them (top-left origin, points).
func windows(onscreenOnly: Bool) -> [Win] {
    let options: CGWindowListOption = onscreenOnly ? [.optionOnScreenOnly] : [.optionAll]
    let list = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
    return list.compactMap { info in
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
              let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double,
              let id = info[kCGWindowNumber as String] as? Int else { return nil }
        return Win(
            id: id, pid: info[kCGWindowOwnerPID as String] as? Int32 ?? 0,
            owner: info[kCGWindowOwnerName as String] as? String ?? "",
            title: info[kCGWindowName as String] as? String ?? "", x: x, y: y, w: w, h: h,
            onscreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false,
            layer: info[kCGWindowLayer as String] as? Int ?? 0,
            alpha: info[kCGWindowAlpha as String] as? Double ?? 1)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("native-probe: " + message + "\n").utf8))
    exit(2)
}

func option(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func post(_ type: CGEventType, _ point: CGPoint) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    else { fail("cannot create a mouse event") }
    event.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.03)
}

func requireInputAccess() {
    guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
        fail("Accessibility and event-posting access are required for the host running this probe")
    }
}

/// The front-most on-screen window containing `point` must be `id`; otherwise another window
/// would receive the input.
func requireTopWindow(_ id: Int, at point: CGPoint) {
    guard let top = windows(onscreenOnly: true).first(where: { $0.frame.contains(point) && $0.owner != "Window Server" })
    else { fail("no window at \(point)") }
    if top.id != id { fail("window \(top.id) (\(top.owner)) is in front of \(id) at \(point); not sending input") }
}

func target(_ args: [String]) -> Win {
    guard let raw = option("--window-id", in: args), let id = Int(raw) else { fail("--window-id is required") }
    // The window must belong to the process you launched, not to another instance of the same app.
    guard let rawPid = option("--pid", in: args), let pid = Int32(rawPid) else { fail("--pid is required") }
    guard let found = windows(onscreenOnly: true).first(where: { $0.id == id }) else { fail("window \(id) is not on screen") }
    if found.pid != pid { fail("window \(id) belongs to pid \(found.pid), not \(pid); not sending input") }
    return found
}

func report(_ label: String, _ win: Win) {
    print("\(label): id=\(win.id) x=\(win.x) y=\(win.y) w=\(win.w) h=\(win.h)")
}

// MARK: commands

func commandWindows(_ args: [String]) {
    let owner = option("--owner", in: args)
    for win in windows(onscreenOnly: false) where owner == nil || win.owner == owner {
        print("id=\(win.id) pid=\(win.pid) owner=\(win.owner) onscreen=\(win.onscreen) x=\(win.x) y=\(win.y) w=\(win.w) h=\(win.h) title=\(win.title)")
    }
}

/// Is the rectangle safe to capture as a screen region (`screencapture -R`)? A region capture is the
/// composited screen, so it is only acceptable when (1) a window of the **backdrop** process covers
/// the whole rectangle (so the desktop and other apps cannot show through behind it), and (2) no
/// window of any process other than the backdrop and the allowed ones (your candidate) is stacked in front of the backdrop inside it.
/// Processes are given by PID, never by name: the user's own copy of the same app has the same name.
/// Exit 1 and say why otherwise - including when the backdrop has already exited.
func commandRegionClear(_ args: [String]) {
    guard let raw = option("--rect", in: args) else { fail("--rect x,y,w,h is required") }
    let numbers = raw.split(separator: ",").compactMap { Double($0) }
    guard numbers.count == 4 else { fail("--rect must be x,y,w,h") }
    let rect = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    guard let rawBackdrop = option("--backdrop-pid", in: args), let backdrop = Int32(rawBackdrop)
    else { fail("--backdrop-pid is required (the pid `backdrop` printed)") }
    var allowed = Set<Int32>([backdrop])
    var index = 0
    while index < args.count {
        if args[index] == "--allow-pid", index + 1 < args.count, let pid = Int32(args[index + 1]) { allowed.insert(pid) }
        index += 1
    }
    let onscreen = windows(onscreenOnly: true) // front to back
    // Everything behind the opaque backdrop window that covers the rectangle is hidden by it; only
    // windows in front of that backdrop window can show up in the capture. Use the real stacking
    // order, not window layers.
    let backdropIndex = onscreen.firstIndex { win in win.pid == backdrop && win.frame.contains(rect) }
    let covered = backdropIndex != nil
    let offenders = onscreen.prefix(backdropIndex ?? onscreen.count).filter { win in
        win.frame.intersects(rect) && !allowed.contains(win.pid) && win.w > 0 && win.h > 0 && win.alpha > 0
    }
    for win in offenders {
        print("intersects: id=\(win.id) pid=\(win.pid) owner=\(win.owner) x=\(win.x) y=\(win.y) w=\(win.w) h=\(win.h)")
    }
    if !covered { print("not covered: no on-screen window of backdrop pid \(backdrop) contains \(raw) (has the backdrop exited, or is it on another display?)") }
    if offenders.isEmpty && covered {
        print("clear: the backdrop covers \(raw) and no other window is in it")
    } else {
        exit(1)
    }
}

func commandDrag(_ args: [String]) {
    requireInputAccess()
    let win = target(args)
    guard let edge = option("--edge", in: args), let raw = option("--by", in: args), let by = Double(raw)
    else { fail("--edge and --by are required") }
    // One point inside the edge (the resize zone is a few points wide); the title bar for moves.
    var start: CGPoint
    var delta = CGPoint.zero
    switch edge {
    case "bottom": start = CGPoint(x: win.x + win.w / 2, y: win.y + win.h - 1); delta.y = by
    case "top": start = CGPoint(x: win.x + win.w / 2, y: win.y + 1); delta.y = by
    case "right": start = CGPoint(x: win.x + win.w - 1, y: win.y + win.h / 2); delta.x = by
    case "left": start = CGPoint(x: win.x + 1, y: win.y + win.h / 2); delta.x = by
    case "title": start = CGPoint(x: win.x + win.w / 2, y: win.y + 14); delta.y = by
    default: fail("--edge must be bottom, top, left, right or title")
    }
    delta.x += Double(option("--dx", in: args) ?? "0") ?? 0
    requireTopWindow(win.id, at: start)
    report("before", win)
    post(.mouseMoved, start)
    post(.leftMouseDown, start)
    let steps = 20
    for step in 1...steps {
        let fraction = Double(step) / Double(steps)
        post(.leftMouseDragged, CGPoint(x: start.x + delta.x * fraction, y: start.y + delta.y * fraction))
    }
    post(.leftMouseUp, CGPoint(x: start.x + delta.x, y: start.y + delta.y))
    Thread.sleep(forTimeInterval: 0.6)
    guard let after = windows(onscreenOnly: true).first(where: { $0.id == win.id }) else { fail("window disappeared") }
    report("after", after)
    // A window whose edge sits on the screen edge cannot be grabbed there: move it first (--edge title).
}

func commandWheel(_ args: [String]) {
    requireInputAccess()
    let win = target(args)
    guard let raw = option("--dy", in: args), let dy = Int32(raw) else { fail("--dy is required") }
    let center = CGPoint(x: win.x + win.w / 2, y: win.y + win.h / 2)
    requireTopWindow(win.id, at: center)
    for _ in 0..<6 {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)
        else { fail("cannot create a wheel event") }
        event.location = center
        event.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
    }
    print("wheel \(dy)x6 posted at \(center)")
}

func attribute(_ element: AXUIElement, _ name: String) -> Any? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func commandPress(_ args: [String]) {
    guard AXIsProcessTrusted() else { fail("Accessibility access is required") }
    guard let rawPid = option("--pid", in: args), let pid = pid_t(rawPid), let title = option("--title", in: args)
    else { fail("--pid and --title are required") }
    let role = option("--role", in: args) ?? "AXCheckBox"
    let app = AXUIElementCreateApplication(pid)
    func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > 16 { return nil }
        if (attribute(element, "AXRole") as? String) == role,
           (attribute(element, "AXTitle") as? String) == title || (attribute(element, "AXDescription") as? String) == title {
            return element
        }
        for child in (attribute(element, "AXChildren") as? [AXUIElement]) ?? [] {
            if let hit = find(child, depth: depth + 1) { return hit }
        }
        return nil
    }
    // The first AX query on a fresh app can see an empty tree while accessibility is switching on,
    // so retry for a bounded time instead of reading "not found" as absence.
    let deadline = Date().addingTimeInterval(5)
    repeat {
        for window in (attribute(app, "AXWindows") as? [AXUIElement]) ?? [] {
            if let hit = find(window, depth: 0) {
                let status = AXUIElementPerformAction(hit, kAXPressAction as CFString)
                print("pressed \(role) \"\(title)\": AXError=\(status.rawValue)")
                exit(status == .success ? 0 : 1)
            }
        }
        Thread.sleep(forTimeInterval: 0.25)
    } while Date() < deadline
    fail("no \(role) named \"\(title)\" within 5 seconds")
}

/// A full-screen window of 8-point black and white squares, owned by this process, kept behind the
/// windows under test: blur or transparency is then read from how the squares look through them.
func commandBackdrop(_ args: [String]) {
    let seconds = Double(option("--seconds", in: args) ?? "60") ?? 60
    print("backdrop pid=\(ProcessInfo.processInfo.processIdentifier)")
    fflush(stdout)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard let frame = NSScreen.main?.frame else { fail("no main screen") }
    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    // One level below normal windows, so it stays behind the window under test whatever the launch order.
    window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
    let image = NSImage(size: frame.size)
    image.lockFocus()
    for row in 0..<Int(frame.height / 8) {
        for column in 0..<Int(frame.width / 8) {
            ((row + column) % 2 == 0 ? NSColor.black : NSColor.white).setFill()
            NSRect(x: column * 8, y: row * 8, width: 8, height: 8).fill()
        }
    }
    image.unlockFocus()
    let view = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
    view.image = image
    window.contentView = view
    window.orderFrontRegardless()
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
    app.run()
}

/// Mean absolute difference of horizontally adjacent pixels over the centre of the image. A sharp
/// 8-point checker gives about 0.06 at 2x; a blurred one is near 0.
func commandSharpness(_ args: [String]) {
    guard let path = args.first, let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let image = NSBitmapImageRep(data: data) else { fail("a readable PNG path is required") }
    let width = image.pixelsWide, height = image.pixelsHigh
    var sum = 0.0, count = 0
    for y in stride(from: height / 4, to: height * 3 / 4, by: 3) {
        for x in (width / 4)..<(width * 3 / 4 - 1) {
            guard let a = image.colorAt(x: x, y: y), let b = image.colorAt(x: x + 1, y: y) else { continue }
            sum += abs(Double(a.redComponent - b.redComponent))
            count += 1
        }
    }
    guard count > 0 else { fail("image too small") }
    print(String(format: "mean |dx| = %.4f over %d px", sum / Double(count), count))
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("commands: windows, region-clear, drag, wheel, press, backdrop, sharpness (see the header of this file)")
}
let rest = Array(arguments.dropFirst())
switch command {
case "windows": commandWindows(rest)
case "region-clear": commandRegionClear(rest)
case "drag": commandDrag(rest)
case "wheel": commandWheel(rest)
case "press": commandPress(rest)
case "backdrop": commandBackdrop(rest)
case "sharpness": commandSharpness(rest)
default: fail("unknown command \(command)")
}
