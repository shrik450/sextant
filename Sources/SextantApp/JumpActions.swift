import AppKit
import SextantCore

extension RepoWindowController {
    /// Opens the jump bar, to go to a file, definition, line or command by typing.
    @objc func goToAnything(_ sender: Any?) {
        guard let window else { return }
        jumpCommands = enabledCommands(in: NSApp.mainMenu)
        let panel = jumpPanel ?? makeJumpPanel()
        jumpPanel = panel
        if let s = session { indexDefinitions(s) }
        panel.show(over: window)
    }

    private func makeJumpPanel() -> JumpPanel {
        let panel = JumpPanel(look: look)
        panel.find = { [weak self] text in await self?.jumpItems(for: text) ?? [] }
        panel.progress = { [weak self] in
            guard let (done, total) = self?.session?.indexing else { return nil }
            return "Finding definitions: \(done) of \(total) files"
        }
        panel.onChoose = { [weak self] item, beside in self?.jump(to: item, beside: beside) }
        return panel
    }

    /// Indexes a review's definitions once, telling the jump bar as they come in.
    func indexDefinitions(_ s: Session) {
        guard s.definitions == nil, s.indexTask == nil, let snapshot = s.target?.snapshot else { return }
        let git = s.resolved?.git ?? repository.git
        let index = repository.definitions
        s.indexTask = Task(priority: .utility) { [weak self, weak s] in
            let found = try? await index.definitions(in: snapshot, git: git) { done, total in
                Task { @MainActor in
                    guard let s, s.indexTask != nil else { return }
                    s.indexing = done < total ? (done, total) : nil
                    self?.jumpPanel?.progressChanged(foundMore: false)
                }
            }
            guard let s, !Task.isCancelled else { return }
            s.definitions = found?.filter(\.inOutline) ?? []
            s.indexing = nil
            s.indexTask = nil
            if self?.session === s { self?.jumpPanel?.progressChanged(foundMore: true) }
        }
    }

    /// Drops a review's definitions after its files may have changed, indexing again if the
    /// jump bar is open.
    func forgetDefinitions(_ s: Session) {
        s.indexTask?.cancel()
        s.indexTask = nil
        s.indexing = nil
        s.definitions = nil
        if jumpPanel?.isVisible == true, session === s { indexDefinitions(s) }
    }

    /// Finds what a jump query names in the focused pane's review, best first.
    func jumpItems(for text: String) async -> [JumpItem] {
        let limit = 60
        switch parseJumpQuery(text) {
        case .anything(let q) where q.isEmpty:
            return changes.prefix(limit).map { fileItem($0.path, changed: true) }
        case .anything(let q), .definitions(let q):
            let onlyDefinitions = if case .definitions = parseJumpQuery(text) { true } else { false }
            let files = onlyDefinitions ? [] : session?.snapshotFiles ?? []
            let changed = Set(changes.map(\.path))
            let defs = session?.definitions ?? []
            let ranked = await Task.detached(priority: .userInitiated) {
                rankJump(q, files: files, changed: changed, definitions: defs, limit: limit)
            }.value
            return ranked.map { m in
                switch m {
                case .file(let p): fileItem(p, changed: changed.contains(p))
                case .definition(let d): definitionItem(d)
                }
            }
        case .fileDefinitions(let q):
            guard let f = focusedFile else { return [] }
            let defs = reader.header.definitions
            let ranked = q.isEmpty ? defs : defs
                .compactMap { d in fuzzyScore(q, candidate: d.name, name: d.name).map { ($0, d) } }
                .sorted { $0.0 > $1.0 }.map(\.1)
            return ranked.prefix(limit).map { definitionItem(LocatedDefinition(name: $0.name, kind: $0.kind, path: f.path, line: $0.nameLine + 1, inOutline: true)) }
        case .line(let n):
            guard let f = focusedFile else { return [] }
            guard let n else { return [] }
            return [JumpItem(target: .line(path: f.path, line: n), title: "Line \(n)", detail: f.path,
                             image: NSImage(systemSymbolName: "arrow.right.to.line", accessibilityDescription: nil))]
        case .commands(let q):
            let ranked = q.isEmpty ? jumpCommands : jumpCommands
                .compactMap { c in fuzzyScore(q, candidate: c.path, name: c.item.title).map { ($0, c) } }
                .sorted { $0.0 > $1.0 }.map(\.1)
            return ranked.prefix(limit).map { c in
                JumpItem(target: .command(c.item), title: c.item.title, detail: c.path + shortcut(c.item),
                         image: NSImage(systemSymbolName: "command", accessibilityDescription: nil))
            }
        }
    }

    private func fileItem(_ path: String, changed: Bool) -> JumpItem {
        let name = (path as NSString).lastPathComponent
        let folder = (path as NSString).deletingLastPathComponent
        return JumpItem(target: .file(path), title: name, detail: (changed ? "Changed · " : "") + folder, image: fileIcon(path))
    }

    private func definitionItem(_ d: LocatedDefinition) -> JumpItem {
        JumpItem(target: .line(path: d.path, line: d.line), title: d.name, detail: "\(d.kind) · \(d.path):\(d.line)",
                 image: NSImage(systemSymbolName: symbolImage(d.kind), accessibilityDescription: d.kind))
    }

    /// Goes to a jump result in the focused pane, or in a new pane beside it.
    func jump(to item: JumpItem, beside: Bool) {
        window?.makeKeyAndOrderFront(nil)
        switch item.target {
        case .file(let path):
            if beside { branch() }
            open(path)
        case .line(let path, let line):
            if beside { branch() }
            if focus == .file(path), let f = focusedFile, let i = f.index(ofLine: line) {
                reader.land(onLine: i)
            } else {
                open(path, at: .line(SideLine(number: line, old: false)))
            }
        case .command(let menuItem):
            reader.focus()
            guard let action = menuItem.action, let target = commandTarget(for: menuItem) else { return }
            NSApp.sendAction(action, to: target, from: menuItem)
        }
    }

    /// The menu commands that can run in this window now, with the menus they're in.
    ///
    /// Commands are checked against this window's responders rather than whichever window
    /// is key, since the jump bar takes the keyboard once it opens.
    private func enabledCommands(in menu: NSMenu?, path: String = "") -> [(path: String, item: NSMenuItem)] {
        var out: [(String, NSMenuItem)] = []
        for item in menu?.items ?? [] where !item.isSeparatorItem && !item.isHidden && !item.isAlternate {
            if let sub = item.submenu {
                if item.title == "Sextant" || sub.title == "NSRecentDocumentsMenu" { continue }
                out += enabledCommands(in: sub, path: path.isEmpty ? item.title : path + " › " + item.title)
            } else if item.action != #selector(goToAnything(_:)), !item.title.isEmpty, commandTarget(for: item) != nil {
                out.append((path, item))
            }
        }
        return out
    }

    /// The responder that would run a menu item's command in this window, if it's enabled.
    private func commandTarget(for item: NSMenuItem) -> AnyObject? {
        guard let action = item.action else { return nil }
        let target: AnyObject? = item.target ?? responders().first { $0.responds(to: action) }
        guard let target else { return nil }
        if let v = target as? NSMenuItemValidation { return v.validateMenuItem(item) ? target : nil }
        if let v = target as? NSUserInterfaceValidations { return v.validateUserInterfaceItem(item) ? target : nil }
        return target
    }

    /// This window's responder chain, then its delegate, the app and the app's delegate.
    private func responders() -> [NSObject] {
        var chain: [NSObject] = []
        var r: NSResponder? = window?.firstResponder
        while let next = r {
            chain.append(next)
            r = next.nextResponder
        }
        if let w = window, !chain.contains(w) { chain.append(w) }
        if !chain.contains(self) { chain.append(self) }
        if let d = window?.delegate as? NSObject, !chain.contains(d) { chain.append(d) }
        chain.append(NSApp)
        if let d = NSApp.delegate as? NSObject { chain.append(d) }
        return chain
    }

    private func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let m = item.keyEquivalentModifierMask
        var s = "  "
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) || item.keyEquivalent != item.keyEquivalent.lowercased() { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        let names: [String: String] = ["\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→", "\r": "↩", "\u{1B}": "⎋", " ": "Space"]
        return s + (names[item.keyEquivalent] ?? item.keyEquivalent.uppercased())
    }
}
