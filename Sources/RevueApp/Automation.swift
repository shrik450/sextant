import AppKit

/// Drives the app from a script so behaviour can be verified without a human.
///
/// Real NSEvents go through the normal event path (menus, responders), and state dumps and
/// snapshots record what happened. A script is a sequence of these commands:
///
///     open <path> [rev]       open a repository window
///     wait                    wait for loads to finish
///     sleep <ms>
///     key <combo>             e.g. j, shift+tab, cmd+f, down, space, esc, return
///     type <text>
///     click <x> <y> [n]       window coords from top-left; n = click count
///     rclick <x> <y>
///     drag <x1> <y1> <x2> <y2>
///     scroll <dy>             scroll wheel lines over the diff (negative = up)
///     hscroll <dx>
///     snapshot <file.png>
///     dump <file.json>
///     appearance light|dark
///     resize <w> <h>
///     defaults <key> <value>
///     menu <title>            perform a menu item by title
///     log <text>
///     quit
@MainActor
final class Automation {
    let lines: [String]
    unowned let app: AppDelegate
    var window: RepoWindowController? {
        let key = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow ?? NSApp.mainWindow
        return app.controllers.first { $0.window === key } ?? app.controllers.last
    }

    init(scriptPath: String, app: AppDelegate) {
        self.app = app
        lines = ((try? String(contentsOfFile: scriptPath, encoding: .utf8)) ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func start() {
        Task {
            for line in lines where !line.isEmpty && !line.hasPrefix("#") {
                let t0 = Date()
                await run(line)
                log("> \(line)  [\(Int(Date().timeIntervalSince(t0) * 1000)) ms]")
            }
        }
    }

    private let logURL: URL? = ProcessInfo.processInfo.environment["REVUE_LOG"].map { URL(fileURLWithPath: $0) } ?? {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--log"), i + 1 < args.count { return URL(fileURLWithPath: args[i + 1]) }
        return nil
    }()

    func log(_ s: String) {
        print(s)
        guard let logURL else { return }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(Data((s + "\n").utf8))
            try? h.close()
        } else {
            try? Data((s + "\n").utf8).write(to: logURL)
        }
    }

    private func waitIdle() async {
        for _ in 0..<3 {
            try? await Task.sleep(for: .milliseconds(60))
            if let w = window, w.busy > 0 {
                await withCheckedContinuation { c in RepoWindowController.idleWaiters.append { c.resume() } }
            }
        }
        try? await Task.sleep(for: .milliseconds(80))
    }

    /// Makes the app active with a key window.
    ///
    /// Screen captures can steal activation, and inputs need the app to be active.
    private func ensureActive() async {
        guard let w = window?.window else { return }
        for _ in 0..<20 where !(NSApp.isActive && NSApp.keyWindow != nil) {
            NSApp.activate(ignoringOtherApps: true)
            (w.attachedSheet ?? w).makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func run(_ line: String) async {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts[0]
        let arg = parts.count > 1 ? parts[1] : ""
        let args = arg.split(separator: " ").map(String.init)
        switch cmd {
        case "open":
            await withCheckedContinuation { c in
                app.openRepo(path: args[0], spec: args.count > 1 ? args[1...].joined(separator: " ") : nil) { _ in c.resume() }
            }
            await waitIdle()
        case "wait": await waitIdle()
        case "sleep": try? await Task.sleep(for: .milliseconds(Int(arg) ?? 100))
        case "key":
            await ensureActive()
            sendKey(arg)
            await waitIdle()
        case "type":
            await ensureActive()
            for ch in arg { sendKey(String(ch)) }
            await waitIdle()
        case "click", "rclick":
            await ensureActive()
            guard args.count >= 2, let x = Double(args[0]), let y = Double(args[1]) else { return }
            click(NSPoint(x: x, y: y), count: args.count > 2 ? Int(args[2]) ?? 1 : 1, right: cmd == "rclick", flags: args.count > 3 && args[3] == "opt" ? .option : [])
            await waitIdle()
        case "drag":
            await ensureActive()
            guard args.count >= 4, let a = Double(args[0]), let b = Double(args[1]), let c = Double(args[2]), let d = Double(args[3]) else { return }
            drag(from: NSPoint(x: a, y: b), to: NSPoint(x: c, y: d))
            await waitIdle()
        case "scroll", "hscroll":
            guard let w = window, let n = Double(arg) else { return }
            if cmd == "scroll" {
                w.reader.scrollBy(lines: CGFloat(n))
            } else if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: Int32(-n), wheel3: 0), let ns = NSEvent(cgEvent: e) {
                w.reader.primary.enclosingScrollView?.scrollWheel(with: ns)
            }
            await waitIdle()
        case "snapshot":
            await ensureActive()
            CATransaction.flush()
            try? await Task.sleep(for: .milliseconds(400))
            await snapshot(to: arg)
        case "render":
            if let v = window?.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
            }
        case "dump":
            guard let w = window else { return }
            let data = try? JSONSerialization.data(withJSONObject: w.stateSnapshot(), options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: URL(fileURLWithPath: arg))
        case "appearance":
            NSApp.appearance = NSAppearance(named: arg == "dark" ? .darkAqua : .aqua)
            await waitIdle()
        case "resize":
            guard let w = window?.window, args.count == 2, let width = Double(args[0]), let h = Double(args[1]) else { return }
            var f = w.frame
            f.origin.y += f.height - h
            f.size = NSSize(width: width, height: h)
            w.setFrame(f, display: true)
            await waitIdle()
        case "defaults":
            guard args.count >= 2 else { return }
            let v = args[1...].joined(separator: " ")
            if let d = Double(v) { UserDefaults.standard.set(d, forKey: args[0]) } else { UserDefaults.standard.set(v, forKey: args[0]) }
            await waitIdle()
        case "menu":
            if let item = findMenuItem(arg, in: NSApp.mainMenu) {
                if let m = item.menu { m.update(); m.performActionForItem(at: m.index(of: item)) }
            } else {
                log("! no menu item \(arg)")
            }
            await waitIdle()
        case "bench":
            guard args.count >= 2, let n = Int(args[0]), let item = findMenuItem(args[1...].joined(separator: " "), in: NSApp.mainMenu), let m = item.menu else { return }
            var times: [Double] = []
            for _ in 0..<n {
                let t0 = Date()
                m.update()
                m.performActionForItem(at: m.index(of: item))
                for _ in 0..<5 {
                    await Task.yield()
                    if let w = window, w.busy > 0 {
                        await withCheckedContinuation { c in RepoWindowController.idleWaiters.append { c.resume() } }
                    }
                }
                window?.window?.displayIfNeeded()
                times.append(Date().timeIntervalSince(t0) * 1000)
            }
            let sorted = times.sorted()
            log(String(format: "BENCH %@: median %.1f ms, max %.1f ms over %d", args[1...].joined(separator: " "), sorted[sorted.count / 2], sorted.last!, n))
        case "log": log(arg)
        case "sh":
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", arg]
            p.environment = ProcessInfo.processInfo.environment.merging(["PATH": userPath()]) { _, b in b }
            try? p.run()
            p.waitUntilExit()
        case "quit": NSApp.terminate(nil)
        default: log("! unknown command \(cmd)")
        }
    }

    private func findMenuItem(_ title: String, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.title == title { return item }
            if let found = findMenuItem(title, in: item.submenu) { return found }
        }
        return nil
    }

    private func sendKey(_ combo: String) {
        guard let w = NSApp.keyWindow ?? window?.window else { return }
        var flags: NSEvent.ModifierFlags = []
        var key = combo
        let parts = combo.split(separator: "+").map(String.init)
        if parts.count > 1 {
            key = parts.last!
            for m in parts.dropLast() {
                switch m {
                case "cmd": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "opt", "alt": flags.insert(.option)
                case "ctrl": flags.insert(.control)
                default: break
                }
            }
        }
        let special: [String: (Int, UInt16)] = [
            "down": (NSDownArrowFunctionKey, 125), "up": (NSUpArrowFunctionKey, 126),
            "left": (NSLeftArrowFunctionKey, 123), "right": (NSRightArrowFunctionKey, 124),
            "pagedown": (NSPageDownFunctionKey, 121), "pageup": (NSPageUpFunctionKey, 116),
            "home": (NSHomeFunctionKey, 115), "end": (NSEndFunctionKey, 119),
        ]
        var chars: String
        var code: UInt16 = 0
        if let s = special[key] {
            chars = String(Character(UnicodeScalar(s.0)!))
            code = s.1
            flags.insert(.function)
            if key == "up" || key == "down" || key == "left" || key == "right" { flags.insert(.numericPad) }
        } else {
            switch key {
            case "space": chars = " "; code = 49
            case "esc": chars = "\u{1b}"; code = 53
            case "return": chars = "\r"; code = 36
            case "tab": chars = flags.contains(.shift) ? "\u{19}" : "\t"; code = 48
            case "delete": chars = "\u{7f}"; code = 51
            default:
                chars = key
                code = keyCodes[key.lowercased()] ?? 0
            }
        }
        let shown = flags.contains(.shift) && chars.count == 1 && chars.first!.isLetter ? chars.uppercased() : chars
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: shown, charactersIgnoringModifiers: shown,
                                        isARepeat: false, keyCode: code) {
                NSApp.sendEvent(e)
            }
        }
    }

    private let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50, "+": 24,
    ]

    private func windowPoint(_ p: NSPoint) -> NSPoint {
        guard let w = window?.window, let cv = w.contentView else { return p }
        return NSPoint(x: p.x, y: cv.bounds.height - p.y)
    }

    private func click(_ p: NSPoint, count: Int, right: Bool, flags: NSEvent.ModifierFlags) {
        guard let w = window?.window else { return }
        let loc = windowPoint(p)
        for n in 1...count {
            let down: NSEvent.EventType = right ? .rightMouseDown : .leftMouseDown
            let up: NSEvent.EventType = right ? .rightMouseUp : .leftMouseUp
            func event(_ t: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: t, location: loc, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 1)
            }
            guard let d = event(down), let u = event(up) else { continue }
            if right, let v = w.contentView?.hitTest(loc), let menu = v.menu(for: d) {
                log("context menu: " + menu.items.map(\.title).joined(separator: " | "))
                continue
            }
            NSApp.postEvent(u, atStart: false)
            w.sendEvent(d)
        }
    }

    private func drag(from a: NSPoint, to b: NSPoint) {
        guard let w = window?.window else { return }
        let la = windowPoint(a), lb = windowPoint(b)
        func ev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let e = ev(.leftMouseDown, la) { w.sendEvent(e) }
        for i in 1...8 {
            let t = CGFloat(i) / 8
            if let e = ev(.leftMouseDragged, NSPoint(x: la.x + (lb.x - la.x) * t, y: la.y + (lb.y - la.y) * t)) { w.sendEvent(e) }
        }
        if let e = ev(.leftMouseUp, lb) { w.sendEvent(e) }
    }

    /// Asks the harness, which holds Screen Recording permission, to capture the app's window.
    ///
    /// Waits for the file to appear before returning.
    private func snapshot(to path: String) async {
        guard let w = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow ?? window?.window else { return }
        try? FileManager.default.removeItem(atPath: path)
        let f = w.frame
        let screenH = NSScreen.screens.first?.frame.height ?? f.maxY
        log("SNAP \(Int(f.minX)),\(Int(screenH - f.maxY)),\(Int(f.width)),\(Int(f.height)) \(path)")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: path) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
