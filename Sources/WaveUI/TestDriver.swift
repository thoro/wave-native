// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — TEST-ONLY UI driver. When WAVE_NATIVE_TEST_SOCK is set, listens on that
// unix socket and injects synthetic key/mouse events into the key window (routed
// through the normal responder chain, so the real keyDown/mouseDown paths run) and
// can snapshot the window to a PNG. This is the headless equivalent of a human
// driving the app — used to reproduce/verify input + render behavior without
// Accessibility/Screen-Recording permission. Newline-delimited commands:
//
//   type <text>            send <text> as individual key events (no trailing CR)
//   enter                  send Return (CR)
//   ctrl <char>            send Control-<char> (e.g. `ctrl c`)
//   key <name>             up|down|left|right|tab|esc|backspace|home|end
//   paste <text>           put <text> on the pasteboard, then Cmd-V
//   click <x> <y>          left click at window point (top-left origin)
//   drag <x1> <y1> <x2> <y2>  left drag (posted through the event queue)
//   dragd <x1> <y1> <x2> <y2>  left drag, direct-dispatched to the hit view
//   scroll <dy>            scroll wheel (positive = up)
//   shot <path>            render the key window to a PNG at <path>
//
// Send via: printf 'type echo hi\nenter\nshot /tmp/x.png\n' | nc -U <sock>

#if canImport(AppKit)
import AppKit

@MainActor
public final class TestDriver {
    private let path: String

    public init(path: String) { self.path = path }

    public func start() {
        let p = path
        Thread.detachNewThread { TestDriver.serve(path: p) }
    }

    private nonisolated static func serve(path: String) {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: src, count: min(strlen(src) + 1, 104)))
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); return }

        while true {
            let cfd = accept(fd, nil, nil)
            if cfd < 0 { continue }
            var buf = [UInt8](repeating: 0, count: 65536)
            var pending = ""
            while true {
                let n = read(cfd, &buf, buf.count)
                if n <= 0 { break }
                pending += String(decoding: buf[0..<n], as: UTF8.self)
                while let nl = pending.firstIndex(of: "\n") {
                    let cmd = String(pending[pending.startIndex..<nl])
                    pending = String(pending[pending.index(after: nl)...])
                    DispatchQueue.main.async { TestDriver.run(cmd) }
                }
            }
            close(cfd)
        }
    }

    // MARK: - Command execution (main actor)

    private static func run(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let space = trimmed.firstIndex(of: " ")
        let verb = String(space.map { trimmed[trimmed.startIndex..<$0] } ?? Substring(trimmed))
        let arg = space.map { String(trimmed[trimmed.index(after: $0)...]) } ?? ""
        if verb == "winfo" {
            // Diagnostics only -- must work even with no key window (that absence is
            // often exactly what is being debugged).
            let lines = NSApp.windows.map { w in
                "\(type(of: w)) visible=\(w.isVisible) key=\(w.isKeyWindow) main=\(w.isMainWindow) " +
                "sheet=\(w.attachedSheet != nil) isSheet=\(w.isSheet) frame=\(w.frame) title=\(w.title)"
            }
            try? lines.joined(separator: "\n").write(
                toFile: arg.trimmingCharacters(in: .whitespaces), atomically: true, encoding: .utf8)
            return
        }
        guard let window = keyWindow() else { return }
        if verb == "resp" {
            // Diagnostics: dump the firstResponder and its superview chain, so focus
            // bookkeeping can be verified without guessing from screenshots.
            var lines: [String] = ["firstResponder=\(String(describing: window.firstResponder))"]
            var v = window.firstResponder as? NSView
            while let cur = v {
                lines.append("\(type(of: cur)) frame=\(cur.frame)")
                v = cur.superview
            }
            try? lines.joined(separator: "\n").write(
                toFile: arg.trimmingCharacters(in: .whitespaces), atomically: true, encoding: .utf8)
            return
        }

        switch verb {
        case "type":
            for ch in arg { sendKey(String(ch), window: window) }
        case "enter":
            sendKey("\r", window: window, keyCode: 36)
        case "ctrl":
            sendKey(arg, window: window, flags: .control)
        case "cmd":
            sendKey(arg, window: window, flags: .command)
        case "cmdshift":
            sendKey(arg, window: window, flags: [.command, .shift])
        case "key":
            sendNamed(arg, window: window)
        case "paste":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(arg, forType: .string)
            sendKey("v", window: window, flags: .command)
        case "click":
            let p = points(arg, window)
            if p.count >= 1 { mouse(.leftMouseDown, p[0], window); mouse(.leftMouseUp, p[0], window) }
        case "hit":
            // Diagnostics: `hit <x> <y> <path>` writes the hit-test view and its
            // superview chain at the point, so blind coordinate clicking can be
            // debugged instead of guessed at.
            let parts = arg.split(separator: " ")
            guard parts.count >= 3, let x = Double(parts[0]), let y = Double(parts[1]) else { return }
            let chain = ViewDump.hitChain(in: window, contentPoint: NSPoint(x: x, y: y))
            try? chain.joined(separator: "\n").write(
                toFile: String(parts[2]), atomically: true, encoding: .utf8)
        case "perfclick":
            // Programmatic click for NSControl targets (widget-bar buttons): a
            // synthesized mouseDown enters NSButton's tracking loop, which wedges on
            // driver events; performClick fires the action directly.
            let p = points(arg, window)
            if let loc = p.first, let content = window.contentView,
               let control = content.hitTest(hitPoint(loc, content)) as? NSControl {
                control.performClick(nil)
            }
        case "dblclick":
            let p = points(arg, window)
            if p.count >= 1 {
                mouse(.leftMouseDown, p[0], window); mouse(.leftMouseUp, p[0], window)
                mouse(.leftMouseDown, p[0], window, clickCount: 2); mouse(.leftMouseUp, p[0], window, clickCount: 2)
            }
        case "tripleclick":
            let p = points(arg, window)
            if p.count >= 1 {
                mouse(.leftMouseDown, p[0], window); mouse(.leftMouseUp, p[0], window)
                mouse(.leftMouseDown, p[0], window, clickCount: 2); mouse(.leftMouseUp, p[0], window, clickCount: 2)
                mouse(.leftMouseDown, p[0], window, clickCount: 3); mouse(.leftMouseUp, p[0], window, clickCount: 3)
            }
        case "shiftclick":
            let p = points(arg, window)
            if p.count >= 1 {
                mouse(.leftMouseDown, p[0], window, flags: .shift)
                mouse(.leftMouseUp, p[0], window, flags: .shift)
            }
        case "shiftkey":
            sendNamed(arg, window: window, flags: .shift)
        case "cmdoptkey":
            sendNamed(arg, window: window, flags: [.command, .option])
        case "optkey":
            sendNamed(arg, window: window, flags: .option)
        case "drag":
            let p = points(arg, window)
            if p.count >= 2 { postDrag(from: p[0], to: p[1], window) }
        case "dragd":
            // Direct-dispatch drag (same path as `click`): exercises view-local
            // mouseDown/mouseDragged/mouseUp selection without the event queue,
            // which drops posted gestures in headless/non-key windows.
            let p = points(arg, window)
            if p.count >= 2 {
                mouse(.leftMouseDown, p[0], window)
                let steps = 8
                for i in 1...steps {
                    let t = CGFloat(i) / CGFloat(steps)
                    let mid = NSPoint(
                        x: p[0].x + (p[1].x - p[0].x) * t,
                        y: p[0].y + (p[1].y - p[0].y) * t)
                    mouse(.leftMouseDragged, mid, window)
                }
                mouse(.leftMouseUp, p[1], window)
            }
        case "scroll":
            scroll(Double(arg) ?? 0, window)
        case "shot":
            shot(arg, window)
        case "closewin":
            // Red traffic-light close: performClose runs the windowShouldClose veto,
            // unlike close() which bypasses it.
            window.performClose(nil)
        case "sheet":
            // Press a button on the window's attached alert sheet by title (e.g.
            // "sheet Close" / "sheet Cancel"). performClick is programmatic, so it
            // avoids NSButton's mouse-tracking loop (which wedges on synthesized
            // events, same class as header drags).
            if let sheet = window.attachedSheet {
                let want = arg.trimmingCharacters(in: .whitespaces)
                if let button = firstButton(titled: want, in: sheet.contentView) {
                    button.performClick(nil)
                }
            }
        default:
            break
        }
    }

    private static func keyWindow() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
    }

    private static func sendKey(_ chars: String, window: NSWindow, flags: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0) {
        guard let e = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: keyCode) else { return }
        // Cmd-modified keys are key-equivalents: NSApp only dispatches those to the
        // KEY window, which a headless test window may not be. Drive performKeyEquivalent
        // straight down the view tree so it's deterministic; plain keys go via keyDown.
        if flags.contains(.command) {
            // Mirror real dispatch: view tree first, then the menu bar (Cmd-,
            // Settings, Edit-menu items) — window.performKeyEquivalent alone
            // never consults the main menu.
            if !window.performKeyEquivalent(with: e) {
                _ = NSApp.mainMenu?.performKeyEquivalent(with: e)
            }
        } else {
            NSApp.sendEvent(e)
        }
    }

    private static func sendNamed(_ name: String, window: NSWindow, flags: NSEvent.ModifierFlags = []) {
        // Map to the private-use function-key unichars the real keys produce.
        let map: [String: (Int, UInt16)] = [
            "up": (NSUpArrowFunctionKey, 126), "down": (NSDownArrowFunctionKey, 125),
            "left": (NSLeftArrowFunctionKey, 123), "right": (NSRightArrowFunctionKey, 124),
            "home": (NSHomeFunctionKey, 115), "end": (NSEndFunctionKey, 119),
            "pageup": (NSPageUpFunctionKey, 116), "pagedown": (NSPageDownFunctionKey, 121),
        ]
        if let (u, code) = map[name], let scalar = Unicode.Scalar(u) {
            sendKey(String(scalar), window: window, flags: flags, keyCode: code)
            return
        }
        switch name {
        // Real hardware Shift+Tab delivers NSBackTabCharacter (0x19), not "\t";
        // mirror that so driver runs exercise the same encoder path.
        case "tab" where flags.contains(.shift):
            sendKey("\u{19}", window: window, flags: flags, keyCode: 48)
        case "tab": sendKey("\t", window: window, flags: flags, keyCode: 48)
        case "esc": sendKey("\u{1b}", window: window, flags: flags, keyCode: 53)
        case "backspace": sendKey("\u{7f}", window: window, flags: flags, keyCode: 51)
        default: break
        }
    }

    /// `NSView.hitTest(_:)` takes the point in the view's SUPERVIEW's coordinate
    /// space. Converting into the content view's own (flipped) space instead flips
    /// every hit vertically — clicks meant for the tab bar land on the pane below.
    private static func hitPoint(_ windowLoc: NSPoint, _ content: NSView) -> NSPoint {
        guard let superview = content.superview else { return windowLoc }
        return superview.convert(windowLoc, from: nil)
    }

    private static func points(_ arg: String, _ window: NSWindow) -> [NSPoint] {
        let nums = arg.split(separator: " ").compactMap { Double($0) }
        guard let content = window.contentView else { return [] }
        var out: [NSPoint] = []
        var i = 0
        while i + 1 < nums.count {
            // Caller uses top-left origin. A flipped content view already has a top-left
            // origin, so pass y straight through; only an unflipped view needs the
            // bottom-left inversion. (Getting this wrong lands every click at the wrong
            // height.) Then convert to window coords for the event.
            let y = content.isFlipped ? nums[i + 1] : content.bounds.height - nums[i + 1]
            out.append(content.convert(NSPoint(x: nums[i], y: y), to: nil))
            i += 2
        }
        return out
    }

    /// Drive a drag gesture. The splitter/drag-drop handlers run their own
    /// window.nextEvent tracking loops, which dequeue from the event QUEUE — so the
    /// down + interpolated drags + up must be POSTED (not sendEvent'd) so the loop
    /// can consume them while mouseDown blocks the main thread.
    private static func postDrag(from: NSPoint, to: NSPoint, _ window: NSWindow) {
        postMouse(.leftMouseDown, from, window)
        let steps = 10
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            postMouse(.leftMouseDragged, NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), window)
        }
        postMouse(.leftMouseUp, to, window)
    }

    private static func postMouse(_ type: NSEvent.EventType, _ loc: NSPoint, _ window: NSWindow) {
        guard let e = NSEvent.mouseEvent(
            with: type, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return }
        NSApp.postEvent(e, atStart: false)
    }

    /// The view that received the last synthesized mouseDown; ups/drags of the
    /// same gesture go to it (AppKit semantics), not a fresh hit-test.
    private static weak var mouseTarget: NSView?

    private static func mouse(
        _ type: NSEvent.EventType, _ loc: NSPoint, _ window: NSWindow,
        clickCount: Int = 1, flags: NSEvent.ModifierFlags = []
    ) {
        guard let e = NSEvent.mouseEvent(
            with: type, location: loc, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1) else { return }
        // window.sendEvent does not reliably route synthesized mouse events in a
        // headless (never-key) window, so dispatch straight to the hit view.
        if type == .leftMouseDown {
            mouseTarget = window.contentView.flatMap { $0.hitTest(hitPoint(loc, $0)) }
        }
        guard let target = mouseTarget else { return }
        switch type {
        case .leftMouseDown: target.mouseDown(with: e)
        case .leftMouseDragged: target.mouseDragged(with: e)
        case .leftMouseUp: target.mouseUp(with: e)
        default: break
        }
    }

    private static func scroll(_ dy: Double, _ window: NSWindow) {
        guard let responder = window.firstResponder as? NSView else { return }
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(dy), wheel2: 0, wheel3: 0),
              let ns = NSEvent(cgEvent: e) else { return }
        responder.scrollWheel(with: ns)
    }

    private static func firstButton(titled title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title.caseInsensitiveCompare(title) == .orderedSame {
            return button
        }
        for sub in view.subviews {
            if let found = firstButton(titled: title, in: sub) { return found }
        }
        return nil
    }

    private static func shot(_ path: String, _ window: NSWindow) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif
