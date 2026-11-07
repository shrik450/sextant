import AppKit
import SextantCore

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
///     panes <file.json>       dump each pane's rows, caret and folds
///     appearance light|dark
///     resize <w> <h>
///     defaults <key> <value>
///     menu <title>            perform a menu item by title
///     note <text>             add a note on the selected lines, as Add Note's editor saves it
///     nowait <command>        start a command and go on without waiting for the window to
///                             settle, so the next one runs while it works
///     log <text>
///     quit
///
/// And these, for the benchmarks in Tests/perf:
///
///     measure <n> key|scroll|menu|note <what>
///                             do something n times, logging the main thread's time for each
///                             and the time until the window settled
///     timeopen <path> [rev]   open, logging when the window, content and settled state came
///     mark <name>             log the time since launch, the footprint and the CPU time
///     settle <name>           wait for the window to settle, logging how long it took
///     stall <ms>              block the main thread, to check that the probe sees it
///     waitindex [timeout-ms]  wait for Go to Anything's definitions, logging how long it took
///     jumptype <text>         type into Go to Anything one key at a time, waiting for each
///                             key's results before the next
///     jumpburst <text>        type into Go to Anything without waiting, then wait for the
///                             results of the whole text
///     watch <file>|stop       record each change to the review's files, with when it was shown
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

    /// Keeps timers precise while the app runs behind others, so timings mean the same either way.
    private var activity: NSObjectProtocol?

    /// The script driving the app, if one is.
    private(set) static weak var running: Automation?

    /// Makes a window log a key that nothing handled, instead of sounding the alert, so a script
    /// running behind the windows in use stays silent and its log shows the refusal.
    private static func silenceUnhandledKeys() {
        let selector = #selector(NSResponder.noResponder(for:))
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return }
        let log: @convention(block) (NSWindow, Selector) -> Void = { _, event in
            guard event == #selector(NSResponder.keyDown(with:)) else { return }
            MainActor.assumeIsolated { Automation.running?.log("! beep: nothing handled a key") }
        }
        class_replaceMethod(NSWindow.self, selector, imp_implementationWithBlock(log), method_getTypeEncoding(method))
    }

    func start() {
        Self.running = self
        if app.inBackground { Self.silenceUnhandledKeys() }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Automation")
        Task {
            for line in lines where !line.isEmpty && !line.hasPrefix("#") {
                let t0 = Date()
                await run(line)
                log("> \(line)  [\(Int(Date().timeIntervalSince(t0) * 1000)) ms]")
            }
        }
    }

    private let logURL: URL? = ProcessInfo.processInfo.environment["SEXTANT_LOG"].map { URL(fileURLWithPath: $0) } ?? {
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
        guard !app.inBackground, let w = window?.window else { return }
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
        case "timeopen":
            let t0 = CACurrentMediaTime()
            await withCheckedContinuation { c in
                app.openRepo(path: args[0], spec: args.count > 1 ? args[1...].joined(separator: " ") : nil) { _ in c.resume() }
            }
            let windowed = CACurrentMediaTime() - t0
            var content: Double?
            while !(window.map { $0.busy == 0 && $0.reader.isSettled && !$0.reader.files.isEmpty } ?? false), CACurrentMediaTime() - t0 < 30 {
                if content == nil, window?.reader.files.isEmpty == false {
                    window?.window?.displayIfNeeded()
                    content = CACurrentMediaTime() - t0
                }
                try? await Task.sleep(for: .microseconds(250))
            }
            window?.window?.displayIfNeeded()
            log(String(format: "OPEN %@: window %.0f, content %.0f, settled %.0f ms, %d MB", arg, windowed * 1000, (content ?? .nan) * 1000, (CACurrentMediaTime() - t0) * 1000, physicalFootprint() / 1_048_576))
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
        case "hover":
            guard args.count >= 2, let x = Double(args[0]), let y = Double(args[1]) else { return }
            hover(NSPoint(x: x, y: y))
            await waitIdle()
        case "press", "release":
            guard args.count >= 2, let x = Double(args[0]), let y = Double(args[1]),
                  let content = window?.window?.contentView, let frame = content.superview else { return }
            var v = content.hitTest(frame.convert(windowPoint(NSPoint(x: x, y: y)), from: nil))
            while let view = v, !(view is NSButton) { v = view.superview }
            (v as? NSButton)?.highlight(cmd == "press")
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
        case "panes":
            guard let w = window else { return }
            let data = try? JSONSerialization.data(withJSONObject: ["panes": w.panesSnapshot()], options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: URL(fileURLWithPath: arg))
        case "appearance":
            NSApp.appearance = NSAppearance(named: arg == "dark" ? .darkAqua : .aqua)
            for w in NSApp.windows { w.contentView?.superview?.needsLayout = true }
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
            guard let item = findMenuItem(arg, in: NSApp.mainMenu), let action = item.action else {
                log("! no menu item \(arg)")
                return
            }
            if !(window?.window?.firstResponder?.tryToPerform(action, with: item) ?? false) {
                NSApp.sendAction(action, to: item.target, from: item)
            }
            await waitIdle()
        case "measure":
            guard args.count >= 3, let n = Int(args[0]) else { return }
            let kind = args[1], what = args[2...].joined(separator: " ")
            await ensureActive()
            var frame: [Double] = [], settled: [Double] = []
            for _ in 0..<n {
                let t0 = CACurrentMediaTime()
                if kind == "key" {
                    sendKey(what)
                } else if kind == "scroll", let d = Double(what) {
                    window?.reader.scrollBy(lines: CGFloat(d))
                } else if kind == "note" {
                    window?.noteOnSelection()?(what)
                } else if let item = findMenuItem(what, in: NSApp.mainMenu), let action = item.action {
                    if !(window?.window?.firstResponder?.tryToPerform(action, with: item) ?? false) {
                        NSApp.sendAction(action, to: item.target, from: item)
                    }
                }
                window?.reader.settleOccurrences()
                window?.window?.displayIfNeeded()
                frame.append((CACurrentMediaTime() - t0) * 1000)
                while !(window.map { $0.busy == 0 && $0.reader.isSettled } ?? true), CACurrentMediaTime() - t0 < 10 {
                    try? await Task.sleep(for: .microseconds(250))
                }
                window?.window?.displayIfNeeded()
                settled.append((CACurrentMediaTime() - t0) * 1000)
                try? await Task.sleep(for: .milliseconds(20))
            }
            func stats(_ v: [Double]) -> String {
                let s = v.sorted()
                return String(format: "median %.1f, p90 %.1f, max %.1f", s[s.count / 2], s[min(s.count - 1, s.count * 9 / 10)], s.last!)
            }
            log("MEASURE \(kind) \(what) ×\(n): frame \(stats(frame)) | settled \(stats(settled)) ms")
        case "mark":
            let now = Date().timeIntervalSince1970
            log(String(format: "MARK %@: %.0f ms since launch, %d MB, %.0f ms CPU, at %lld", arg, (now - processStart()) * 1000, physicalFootprint() / 1_048_576, cpuTime() * 1000, Int64(now * 1e9)))
        case "settle":
            let t0 = CACurrentMediaTime()
            while !(window.map { $0.busy == 0 && $0.reader.isSettled } ?? true), CACurrentMediaTime() - t0 < 10 {
                try? await Task.sleep(for: .microseconds(250))
            }
            window?.window?.displayIfNeeded()
            log(String(format: "SETTLE %@: %.0f ms", arg, (CACurrentMediaTime() - t0) * 1000))
        case "snapr":
            guard let w = window?.window, let screen = w.screen ?? NSScreen.screens.first else { return }
            CATransaction.flush()
            try? await Task.sleep(for: .milliseconds(400))
            let f = w.frame
            log("SNAPR \(Int(f.minX)),\(Int(screen.frame.maxY - f.maxY)),\(Int(f.width)),\(Int(f.height)) \(arg)")
            try? await Task.sleep(for: .milliseconds(1500))
        case "backdrop":
            setBackdrop(args)
            await waitIdle()
        case "note":
            if let save = window?.noteOnSelection() { save(arg) } else { log("! no lines to note") }
            await waitIdle()
        case "stall":
            usleep(useconds_t((Double(arg) ?? 0) * 1000))
        case "waitindex":
            let t0 = CACurrentMediaTime()
            let limit = (Double(arg) ?? 600_000) / 1000
            while let s = window?.session, s.definitions == nil || s.indexTask != nil, CACurrentMediaTime() - t0 < limit {
                try? await Task.sleep(for: .milliseconds(5))
            }
            log(String(format: "INDEXED %.0f ms, %d definitions, %d MB", (CACurrentMediaTime() - t0) * 1000, window?.session?.definitions?.count ?? -1, physicalFootprint() / 1_048_576))
        case "jumptype", "jumpburst":
            await typeIntoJump(arg, waitingForEachKey: cmd == "jumptype")
        case "watch":
            watching?.cancel()
            watching = arg == "stop" ? nil : watch(to: arg)
        case "nowait":
            Task { await run(arg) }
            try? await Task.sleep(for: .milliseconds(20))
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

    /// Finds a menu item by its title, or by its action's selector name, such as
    /// `toggleNavigatorColumn:`, for items whose titles change with what they toggle.
    private func findMenuItem(_ name: String, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.title == name || item.action.map(NSStringFromSelector) == name { return item }
            if let found = findMenuItem(name, in: item.submenu) { return found }
        }
        return nil
    }

    /// Types into the open Go to Anything bar and logs how long the results took.
    ///
    /// Waiting for each key logs a `JUMPKEY` line per key and a `JUMP` summary; otherwise every
    /// key is sent at once and one `JUMPBURST` line says when the whole text's results showed.
    private func typeIntoJump(_ text: String, waitingForEachKey: Bool) async {
        guard let panel = window?.jumpPanel, panel.isVisible else {
            log("! no jump panel")
            return
        }
        func waitForResults(since t0: Double) async -> Double {
            while panel.itemsQuery != panel.field.stringValue, CACurrentMediaTime() - t0 < 60 {
                try? await Task.sleep(for: .microseconds(250))
            }
            return (CACurrentMediaTime() - t0) * 1000
        }
        if !waitingForEachKey {
            let t0 = CACurrentMediaTime()
            for ch in text { sendKey(String(ch)) }
            log(String(format: "JUMPBURST %@: results %.1f ms", text, await waitForResults(since: t0)))
            return
        }
        var keys: [Double] = [], results: [Double] = []
        for ch in text {
            let t0 = CACurrentMediaTime()
            sendKey(String(ch))
            keys.append((CACurrentMediaTime() - t0) * 1000)
            results.append(await waitForResults(since: t0))
            log(String(format: "JUMPKEY %@: key %.1f, results %.1f ms", String(ch), keys.last!, results.last!))
        }
        func stats(_ v: [Double]) -> String {
            let s = v.sorted()
            return String(format: "median %.1f, p90 %.1f, max %.1f", s[s.count / 2], s[min(s.count - 1, s.count * 9 / 10)], s.last!)
        }
        guard !text.isEmpty else { return }
        log("JUMP \(text) ×\(text.count): key \(stats(keys)) | results \(stats(results)) ms")
    }

    private var watching: Task<Void, Never>?

    /// Records, every 10 ms, whether the focused review's files changed, so a benchmark can
    /// tell when the window first showed what git says.
    ///
    /// Each change appends `STATE <unix ns> <files> <added> <deleted> <base>` and then one
    /// `<path>\t<added>\t<deleted>` line per file, sorted by path.
    ///
    /// - Parameter path: The file to append to.
    /// - Returns: The task recording, to cancel when done.
    private func watch(to path: String) -> Task<Void, Never> {
        FileManager.default.createFile(atPath: path, contents: nil)
        let out = FileHandle(forWritingAtPath: path)
        return Task { [weak self] in
            var last: [String]?
            while !Task.isCancelled {
                if let w = self?.window, w.session?.isLoading == false {
                    let files = w.changes.map { "\($0.path)\t\($0.diff.additions)\t\($0.diff.deletions)" }.sorted()
                    if files != last {
                        last = files
                        let added = w.changes.reduce(0) { $0 + $1.diff.additions }
                        let deleted = w.changes.reduce(0) { $0 + $1.diff.deletions }
                        let header = "STATE \(Int64(Date().timeIntervalSince1970 * 1e9)) \(files.count) \(added) \(deleted) \(w.review?.base ?? "-")"
                        out?.write(Data(([header] + files).map { $0 + "\n" }.joined().utf8))
                    }
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            try? out?.close()
        }
    }

    private func sendKey(_ combo: String) {
        guard let w = (window?.jumpPanel?.isVisible == true ? window?.jumpPanel : nil) ?? NSApp.keyWindow.flatMap({ $0.isVisible ? $0 : nil }) ?? window?.window else { return }
        if w === window?.jumpPanel, !w.isKeyWindow { w.makeKey() }
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
                if w === window?.jumpPanel { w.sendEvent(e) } else { NSApp.sendEvent(e) }
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

    private var backdropWindow: NSWindow?

    /// Puts a window filled with a gradient right behind the test window, so behind-window
    /// materials have a known colour to blend, or removes it.
    ///
    /// - Parameter colors: The gradient's top and bottom colours in hex, or `off`.
    private func setBackdrop(_ colors: [String]) {
        guard let w = window?.window, colors.first != "off", let top = colors.first.flatMap(Theme.parse) else {
            backdropWindow?.orderOut(nil)
            backdropWindow = nil
            return
        }
        let bottom = colors.dropFirst().first.flatMap(Theme.parse) ?? top
        let frame = w.frame.insetBy(dx: -300, dy: -300)
        let b = backdropWindow ?? NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        b.isReleasedWhenClosed = false
        b.setFrame(frame, display: false)
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.frame = view.bounds
        gradient.colors = [top.cgColor, bottom.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        view.layer?.addSublayer(gradient)
        b.contentView = view
        b.order(.below, relativeTo: w.windowNumber)
        backdropWindow = b
    }

    private var hoveredAreas: [NSTrackingArea] = []

    /// Moves a pretend pointer to a point, without moving the real one.
    ///
    /// The views under the point whose own tracking areas contain it are told the pointer entered
    /// them, and those it has left are told it exited.
    ///
    /// - Parameter p: The point, from the top left of the window's content.
    private func hover(_ p: NSPoint) {
        guard let w = window?.window, let content = w.contentView, let frame = content.superview else { return }
        let loc = windowPoint(p)
        var chain: [NSView] = []
        var v = content.hitTest(frame.convert(loc, from: nil))
        while let view = v { chain.append(view); v = view.superview }
        let areas = chain.flatMap { view in
            view.trackingAreas.filter { a in
                a.owner as? NSView === view && (a.options.contains(.inVisibleRect) ? view.visibleRect : a.rect).contains(view.convert(loc, from: nil))
            }
        }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.enterExitEvent(with: type, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
        }
        let moved = NSEvent.mouseEvent(with: .mouseMoved, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
        for a in hoveredAreas where !areas.contains(where: { $0 === a }) {
            if let e = event(.mouseExited) { (a.owner as? NSView)?.mouseExited(with: e) }
        }
        for a in areas {
            let owner = a.owner as? NSView
            if !hoveredAreas.contains(where: { $0 === a }), let e = event(.mouseEntered) { owner?.mouseEntered(with: e) }
            if a.options.contains(.mouseMoved), let moved { owner?.mouseMoved(with: moved) }
        }
        hoveredAreas = areas
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

    /// Asks the harness, which holds Screen Recording permission, to capture the app's window
    /// by its number, so windows in front of it don't show.
    ///
    /// Waits for the file to appear before returning.
    private func snapshot(to path: String) async {
        let visibleKey = NSApp.keyWindow.flatMap { $0.isVisible ? $0 : nil }
        guard let w = visibleKey?.sheetParent ?? visibleKey ?? window?.window else { return }
        try? FileManager.default.removeItem(atPath: path)
        log("SNAP \(w.windowNumber) \(path)")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: path) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// What the window shows, as plain values, for scripts to check.
extension RepoWindowController {
    private var focusName: String {
        guard let r = window?.firstResponder else { return "" }
        let editing = (r as? NSTextView)?.delegate as? NSView
        switch editing ?? (r as? NSView) {
        case navigator.changes.outline: return "files"
        case navigator.changes.filter: return "filesFilter"
        case navigator.changes.commits: return "commits"
        case navigator.search.outline: return "search"
        case navigator.search.field: return "searchField"
        case inspector.notes.table: return "notes"
        case inspector.outline: return "inspector"
        default:
            if r is CodeView { return "reader" }
            if let picker = picker?.contentViewController as? SubjectPicker, editing === picker.field { return "picker" }
            return String(describing: type(of: r))
        }
    }

    private func describe(_ s: Subject?) -> String {
        switch s {
        case .worktree(let root)?: "worktree:\(root.path)"
        case .branch(let b)?: "branch:\(b)"
        case .pullRequest(let n)?: "pr:\(n)"
        case .commit(let c)?: "commit:\(c)"
        case .comparison(let a, let b, let since)?: "comparison:\(a)\(since ? "..." : "..")\(b)"
        case .stash(let s)?: "stash:\(s)"
        case nil: "none"
        }
    }

    private func describe(_ s: Scope?) -> String {
        switch s {
        case .everything?: "everything"
        case .uncommitted?: "uncommitted"
        case .staged?: "staged"
        case .unstaged?: "unstaged"
        case .commits(let n, let o)?: "commits:\(n.prefix(7))..\(o.prefix(7))"
        case nil: "none"
        }
    }

    private func describe(_ t: Target?) -> String {
        switch t {
        case .worktree(let since)?: "worktree:\(since?.prefix(7) ?? "HEAD")"
        case .staged?: "staged"
        case .unstaged?: "unstaged"
        case .commit(let c)?: "commit:\(c.prefix(7))"
        case .range(let b, let h)?: "range:\(b.prefix(7))..\(h.prefix(7))"
        case .stash(let s)?: "stash:\(s.prefix(7))"
        case nil: "none"
        }
    }

    /// The visible rows of an outline, indented by level.
    private func rows(of o: NSOutlineView, _ text: (Any) -> String) -> [String] {
        (0..<min(o.numberOfRows, 120)).compactMap { r in
            guard let item = o.item(atRow: r) else { return nil }
            let mark = o.selectedRowIndexes.contains(r) ? "> " : ""
            return mark + String(repeating: "  ", count: o.level(forRow: r)) + text(item)
        }
    }

    func stateSnapshot() -> [String: Any] {
        let focusString: String = switch focus {
        case .overview?: "overview"
        case .file(let p)?: "file:\(p)"
        case nil: ""
        }
        let loc = currentLocation()
        let summary = reviewSummary
        let tree = rows(of: navigator.changes.outline) { item in
            guard let i = item as? ChangesController.Item else { return "?" }
            switch i.kind {
            case .allChanges: return "All Changes \(i.reviewed)/\(i.changed)"
            case .folder: return "\(i.name)/ \(i.reviewed)/\(i.changed)"
            case .folded: return "⋯ \(i.changed) unchanged"
            case .file: return (i.showsFolder ? i.path : i.name) + (i.file.map { " [\(statusLetter($0.diff.change.status).0)\($0.reviewed ? " ✓" : "")]" } ?? "")
            }
        }
        let inspectorRows = rows(of: inspector.outline) { item in
            guard let e = item as? Inspector.Entry else { return "?" }
            switch e.kind {
            case .section(let t): return "# \(t)"
            case .symbol(let s): return "\(s.name) \(s.change)"
            case .change(let k, let enclosing, let read): return "change @\(k.run.newLine + 1) +\(k.run.additions) -\(k.run.deletions)" + (enclosing.map { " in \($0)" } ?? "") + (read ? " read" : "")
            case .file(let f, _): return f.path
            case .card(let text): return "card: " + text.string.replacingOccurrences(of: "\n", with: " | ")
            case .message(let m): return "(\(m))"
            }
        }
        let inspectorCells: [String] = (0..<min(inspector.outline.numberOfRows, 120)).map { r in
            (inspector.outline.view(atColumn: 0, row: r, makeIfNecessary: false) as? NSTableCellView)?.textField?.stringValue ?? "-"
        }
        let scopes: [String] = navigator.changes.scopeRows.enumerated().map { i, r in
            let mark = navigator.changes.commits.selectedRowIndexes.contains(i) ? "> " : ""
            switch r {
            case .everything(let t, _): return mark + t
            case .uncommitted(let n, let failure): return mark + "Uncommitted " + (failure == nil ? "\(n)" : "failed")
            case .commit(let c): return mark + "\(c.shortOid) \(c.subject)"
            }
        }
        var pickerRows: [String] = []
        if let p = picker, p.isShown, let vc = p.contentViewController as? SubjectPicker {
            pickerRows = vc.rows.enumerated().map { i, r in
                let mark = vc.table.selectedRow == i ? "> " : ""
                switch r {
                case .section(let s): return "# " + s
                case .worktree(let w): return mark + "worktree \(w.name) \(w.branch ?? "")"
                case .pullRequest(let pr): return mark + "pr #\(pr.number) \(pr.headRefName)"
                case .branch(let b): return mark + "branch \(b.name)"
                case .commit(let c): return mark + "commit \(c.shortOid) \(c.subject)"
                case .stash(let s): return mark + "stash \(s.ref)"
                case .typed(let t, _): return mark + "typed \(t)"
                }
            }
        }
        let caretText: String = reader.caret.map { p in
            guard reader.files.indices.contains(p.file), let l = reader.sideLine(at: p) else { return "" }
            let f = reader.files[p.file].file
            let (n, old) = (l.number, l.old)
            let code = reader.activeCode
            let col = code.selectedRange().location - code.charRange(ofRow: reader.caretRow ?? 0).location
            return "\(f.path):\(n)\(old ? " (old)" : ""):\(col + 1)"
        } ?? ""
        return [
            "repo": repository.commonDir.path,
            "home": home?.path ?? "",
            "subject": describe(review?.subject),
            "base": review?.base ?? "",
            "scope": describe(review?.scope),
            "target": describe(target),
            "subjectTitle": summary.subject.title,
            "baseShown": summary.base != nil,
            "baseTitle": summary.base?.current ?? "",
            "subtitle": summary.scope,
            "title": window?.title ?? "",
            "error": lastError ?? "",
            "split": reader.split,
            "columns": reader.primary.side == 1 ? 2 : 1,
            "focus": focusString,
            "top": loc.map { "\($0.top.number)\($0.top.old ? " (old)" : "")" } ?? "",
            "caret": caretText,
            "selection": NSStringFromRange(reader.activeCode.selectedRange()) + " row \(reader.caretRow ?? -1) of \(reader.activeCode.rows.count) len \(reader.activeCode.textStorage?.length ?? 0)",
            "currentChange": currentChange.map { changes[$0].path } ?? "",
            "isWhole": focusedFile?.text.isWhole ?? false,
            "rows": reader.primary.rows.count,
            "firstResponder": focusName,
            "windowFrame": NSStringFromRect(window?.frame ?? .zero),
            "isKey": window?.isKeyWindow ?? false,
            "navigatorCollapsed": !isShown(.navigator),
            "inspectorCollapsed": !isShown(.inspector),
            "files": changes.map { ["path": $0.path, "status": String($0.diff.change.status), "reviewed": $0.reviewed, "add": $0.diff.additions, "del": $0.diff.deletions] },
            "scopes": scopes,
            "tree": tree,
            "inspector": inspectorRows,
            "inspectorCells": inspectorCells,
            "picker": pickerRows,
            "navigatorTab": "\(navigator.tab)",
            "searchStatus": navigator.search.summary,
            "notes": reviewNotes.map { ["title": $0.title, "text": $0.text] },
            "statusFailures": repository.statusFailures.keys.map(\.path).sorted(),
            "caretColumn": reader.caretColumn ?? -1,
            "caretWord": reader.wordAtCaret ?? "",
            "selectionRows": reader.selection?.lines.count ?? 0,
            "uses": reader.activeCode.uses.count,
            "jumpLabels": reader.activeCode.jumpLabels.map(\.label),
            "read": reader.caretRun.map { c in c.text.keyedRuns.map { repository.reviews.isRead($0.key, in: c.file.diff.change) } } ?? [],
            "panes": panes.map(\.title),
            "focusedPane": focusedPane,
            "jump": jumpPanel?.isVisible == true ? (jumpPanel?.items ?? []).map { $0.title + " | " + $0.detail } : [],
            "blame": reader.blame != nil,
            "selectedText": reader.selectedText ?? "",
            "paneHeader": reader.header.components,
            "symbol": reader.header.symbols.isHidden ? "" : reader.header.symbols.titleOfSelectedItem ?? "",
            "visibleRows": visibleRowsInWindow(),
            "fontSize": Appearance.shared.font.pointSize,
            "footprintMB": physicalFootprint() / 1_048_576,
            "indexing": session?.indexing.map { "\($0.done)/\($0.total)" } ?? "",
        ]
    }

    /// Returns the visible reader rows with window coordinates (top-left origin), for scripted clicks.
    func visibleRowsInWindow() -> [[String: Any]] {
        guard let cv = window?.contentView else { return [] }
        let code = reader.primary
        var out: [[String: Any]] = []
        code.visibleRows(in: code.visibleRect) { r, frag in
            guard out.count < 80 else { return }
            let row = code.rows[r]
            let kind: String = switch row.kind {
            case .line: {
                let l = code.files[row.file].text.lines[row.line]
                let sign = l.kind == .added ? "+" : l.kind == .deleted ? "-" : " "
                return "\(sign)\(l.kind == .deleted ? l.oldNo : l.newNo) \(l.text.prefix(40))"
            }()
            case .filler: "filler"
            case .fold(let range): "fold \(range.count)"
            case .gap: "gap"
            case .header: "header \(code.files[row.file].file.path)"
            case .notice(let s): "notice \(s)"
            case .note: "note"
            }
            let rect = code.convert(frag, to: nil)
            out.append(["kind": kind, "y": cv.bounds.height - rect.midY, "x": rect.minX + 40])
        }
        return out
    }

    /// Describes what each pane shows, row by row, for checking panes against each other.
    ///
    /// A line row reads as its sign, number and text, from the file line the pane's colours,
    /// numbers and commands use; a row whose text on screen differs adds `| shown:` and that text,
    /// and counts as mismatched.
    func panesSnapshot() -> [[String: Any]] {
        panes.enumerated().map { i, p in
            let reader = p.reader, code = reader.primary
            let text = (code.textStorage?.string ?? "") as NSString
            var rows: [String] = [], mismatched = 0, folds = 0, gaps = 0
            for (r, row) in code.rows.enumerated() {
                switch row.kind {
                case .line:
                    let l = code.files[row.file].text.lines[row.line]
                    let sign = l.kind == .added ? "+" : l.kind == .deleted ? "-" : " "
                    let shown = text.substring(with: code.charRange(ofRow: r))
                    var described = "\(sign)\(l.kind == .deleted ? l.oldNo : l.newNo) \(l.text)"
                    if shown != displayText(l.text) {
                        mismatched += 1
                        described += " | shown: \(shown)"
                    }
                    rows.append(described)
                case .filler: rows.append("filler")
                case .fold(let range):
                    folds += 1
                    rows.append("fold \(range.count)")
                case .gap(let n):
                    gaps += 1
                    rows.append("gap \(n)")
                case .header: rows.append("header \(code.files[row.file].file.path)")
                case .notice(let s): rows.append("notice \(s)")
                case .note(let id): rows.append("note \(notes.notes.first { $0.id == id }?.text ?? "?")")
                }
            }
            let caret: String = reader.caret.map { c in
                let path = reader.files[c.file].file.path
                return reader.sideLine(at: c).map { lineReference(path: path, lines: $0.number...$0.number, old: $0.old) } ?? path
            } ?? ""
            return [
                "title": p.title,
                "focused": i == focusedPane,
                "caret": caret,
                "columns": code.side == 1 ? 2 : 1,
                "showAll": reader.showAll,
                "mismatched": mismatched,
                "folds": folds,
                "gaps": gaps,
                "rows": Array(rows.prefix(600)),
            ]
        }
    }
}

/// Returns the app's physical memory footprint in bytes, as Activity Monitor counts it.
func physicalFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : -1
}

/// Returns when this process started, in seconds since 1970.
func processStart() -> Double {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    sysctl(&mib, 4, &info, &size, nil, 0)
    let t = info.kp_proc.p_un.__p_starttime
    return Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000
}

/// Returns the CPU time this process has used, user and system, in seconds.
func cpuTime() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}
