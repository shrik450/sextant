import AppKit
import SextantCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var controllers: [RepoWindowController] = []
    private var settingsWindow: NSWindow?
    var automation: Automation?
    /// Whether automation runs without taking focus, behind the windows of the app in use.
    var inBackground = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = UserTools.path
        NSApp.mainMenu = buildMainMenu()
        _ = Appearance.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--automation"), i + 1 < args.count {
            inBackground = args.contains("--background")
            automation = Automation(scriptPath: args[i + 1], app: self)
            automation?.start()
            return
        }
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            openRepo(path: args[i + 1], spec: i + 2 < args.count ? args[i + 2] : nil)
            return
        }
        let isDefault = (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool) ?? true
        if isDefault {
            let saved = UserDefaults.standard.stringArray(forKey: "openRepos") ?? []
            if saved.isEmpty {
                openDocument(nil)
            } else {
                for p in saved { openRepo(path: p, spec: nil) }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if controllers.isEmpty { openDocument(nil) } else { controllers.first?.showWindow(nil) }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "sextant" {
                let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let q = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
                guard let path = q["path"] else { continue }
                openRepo(path: path, spec: q["rev"].flatMap { $0.isEmpty ? nil : $0 })
            } else if url.isFileURL {
                openRepo(path: url.path, spec: nil)
            }
        }
    }

    /// Opens the repository containing a path, reviewing a revision or all the work in that
    /// checkout.
    ///
    /// A repository has one window, whichever worktree it's opened from; opening another of its
    /// worktrees reviews that one in the same window.
    func openRepo(path: String, spec: String?, completion: ((RepoWindowController?) -> Void)? = nil) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        Task {
            do {
                let gitPath = await UserTools.git.value
                let loc = try await Git.locate(url.hasDirectoryPath || isDirectory(url) ? url : url.deletingLastPathComponent(), executable: gitPath)
                if let existing = controllers.first(where: { $0.repository.commonDir == loc.commonDir }) {
                    existing.window?.raise()
                    await existing.openAgain(spec: spec, in: loc.root)
                    if !inBackground { NSApp.activate() }
                    completion?(existing)
                    return
                }
                let repository = Repository(commonDir: loc.commonDir, gitPath: gitPath)
                let git = repository.git
                let opening = Task.detached { await Repository.open(spec, in: loc.root, git: git, commonDir: loc.commonDir) }
                let wc = RepoWindowController(repository: repository, home: loc.root)
                controllers.append(wc)
                wc.window?.raise()
                wc.reader.focus()
                if !inBackground { NSApp.activate() }
                wc.start(spec: spec, opening: opening)
                NSDocumentController.shared.noteNewRecentDocumentURL(loc.root.url)
                saveOpenRepos()
                completion?(wc)
            } catch {
                let a = NSAlert()
                a.messageText = "Couldn’t open \(url.lastPathComponent)"
                a.informativeText = error.localizedDescription
                a.runModal()
                completion?(nil)
            }
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    func windowClosed(_ wc: RepoWindowController) {
        controllers.removeAll { $0 === wc }
        if !isTerminating { saveOpenRepos() }
    }

    private var isTerminating = false
    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        saveOpenRepos()
    }

    private func saveOpenRepos() {
        guard automation == nil else { return }
        UserDefaults.standard.set(controllers.compactMap { $0.home?.path }, forKey: "openRepos")
    }

    @objc func openDocument(_ sender: Any?) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Review"
        p.message = "Choose a git repository"
        if p.runModal() == .OK, let url = p.url { openRepo(path: url.path, spec: nil) }
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: SettingsViewController())
            w.title = "Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func reloadThemes(_ sender: Any?) { Appearance.shared.reloadThemes() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(closePane(_:)) ? NSApp.keyWindow != nil : true
    }

    /// Closes the key window when it has no panes of its own, such as Settings.
    @objc func closePane(_ sender: Any?) { NSApp.keyWindow?.performClose(sender) }

    func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        func menu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenu {
            let m = NSMenu(title: title)
            build(m)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = m
            main.addItem(item)
            return m
        }
        func item(_ m: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], tag: Int = 0, symbol: String? = nil) {
            let shifted = mods.contains(.shift) && key.count == 1 && key.first!.isLetter
            let i = NSMenuItem(title: title, action: action, keyEquivalent: shifted ? key.uppercased() : key)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            i.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            m.addItem(i)
        }
        /// Adds a hidden second shortcut for the item above, such as a Mac-style key beside a letter key.
        func alternate(_ m: NSMenu, _ key: String, _ mods: NSEvent.ModifierFlags) {
            guard let above = m.items.last else { return }
            item(m, above.title, above.action, key, mods, tag: above.tag)
            m.items.last?.isHidden = true
            m.items.last?.allowsKeyEquivalentWhenHidden = true
        }
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))

        _ = menu("Sextant") { m in
            item(m, "About Sextant", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", [], symbol: "info.circle")
            m.addItem(.separator())
            item(m, "Settings…", #selector(showSettings(_:)), ",", symbol: "gearshape")
            m.addItem(.separator())
            let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
            services.submenu = NSMenu()
            NSApp.servicesMenu = services.submenu
            m.addItem(services)
            m.addItem(.separator())
            item(m, "Hide Sextant", #selector(NSApplication.hide(_:)), "h", symbol: "eye.slash")
            item(m, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            item(m, "Show All", #selector(NSApplication.unhideAllApplications(_:)), "", [])
            m.addItem(.separator())
            item(m, "Quit Sextant", #selector(NSApplication.terminate(_:)), "q", symbol: "power")
        }
        typealias W = RepoWindowController
        _ = menu("File") { m in
            item(m, "Open…", #selector(openDocument(_:)), "o", symbol: "folder")
            let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
            let rm = NSMenu(title: "Open Recent")
            rm.perform(NSSelectorFromString("_setMenuName:"), with: "NSRecentDocumentsMenu")
            rm.addItem(NSMenuItem(title: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: ""))
            recent.submenu = rm
            recent.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
            m.addItem(recent)
            m.addItem(.separator())
            item(m, "Close Pane", #selector(W.closePane(_:)), "w", symbol: "xmark")
            item(m, "Close Other Panes", #selector(W.closeOtherPanes(_:)), "w", [.command, .option], symbol: "xmark.square")
            m.addItem(.separator())
            item(m, "Open in Editor", #selector(W.openCurrentInEditor(_:)), "e", [], symbol: "square.and.pencil")
            item(m, "Refresh", #selector(W.refreshAction(_:)), "r", symbol: "arrow.clockwise")
        }
        _ = menu("Edit") { m in
            item(m, "Undo", Selector(("undo:")), "z", symbol: "arrow.uturn.backward")
            item(m, "Redo", Selector(("redo:")), "z", [.command, .shift], symbol: "arrow.uturn.forward")
            m.addItem(.separator())
            item(m, "Cut", #selector(NSText.cut(_:)), "x", symbol: "scissors")
            item(m, "Copy", #selector(NSText.copy(_:)), "c", symbol: "doc.on.doc")
            item(m, "Copy Reference", #selector(W.copyReference(_:)), "c", [.command, .option], symbol: "link")
            item(m, "Copy Reference with Code", #selector(W.copyReferenceWithCode(_:)), "c", [.command, .option, .shift], symbol: "chevron.left.forwardslash.chevron.right")
            item(m, "Copy Symbol Name", #selector(W.copySymbol(_:)), "c", [.command, .control, .shift], symbol: "curlybraces")
            item(m, "Copy Symbol with Reference", #selector(W.copySymbolWithReference(_:)), "y", symbol: "link.badge.plus")
            item(m, "Copy Path", #selector(W.copyCurrentPath(_:)), "", symbol: "doc.text")
            item(m, "Paste", #selector(NSText.paste(_:)), "v", symbol: "doc.on.clipboard")
            item(m, "Select All", #selector(NSText.selectAll(_:)), "a", symbol: "checkmark.rectangle.stack")
            m.addItem(.separator())
            let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
            let fm = NSMenu(title: "Find")
            item(fm, "Find…", #selector(NSResponder.performTextFinderAction(_:)), "f", tag: NSTextFinder.Action.showFindInterface.rawValue, symbol: "magnifyingglass")
            item(fm, "Find Next", #selector(NSResponder.performTextFinderAction(_:)), "g", tag: NSTextFinder.Action.nextMatch.rawValue, symbol: "chevron.down")
            item(fm, "Find Previous", #selector(NSResponder.performTextFinderAction(_:)), "g", [.command, .shift], tag: NSTextFinder.Action.previousMatch.rawValue, symbol: "chevron.up")
            item(fm, "Use Selection for Find", #selector(NSResponder.performTextFinderAction(_:)), "e", tag: NSTextFinder.Action.setSearchString.rawValue, symbol: "text.magnifyingglass")
            fm.addItem(.separator())
            item(fm, "Find in Files…", #selector(W.findInRepository(_:)), "f", [.command, .shift], symbol: "text.page.badge.magnifyingglass")
            item(fm, "Find File…", #selector(W.focusFilter(_:)), "f", [.command, .option], symbol: "doc.text.magnifyingglass")
            find.submenu = fm
            find.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            m.addItem(find)
        }
        _ = menu("View") { m in
            item(m, "Changes", #selector(W.showChangesTab(_:)), "1", symbol: "list.bullet.indent")
            item(m, "Find", #selector(W.showFindTab(_:)), "2", symbol: "magnifyingglass")
            m.addItem(.separator())
            item(m, "Unified", #selector(W.showUnified(_:)), "1", [.command, .control], symbol: "text.justify.leading")
            item(m, "Side by Side", #selector(W.showSideBySide(_:)), "2", [.command, .control], symbol: "rectangle.split.2x1")
            item(m, "Show Unchanged Lines", #selector(W.toggleShowAll(_:)), "f", [], symbol: "eye")
            item(m, "Show Nearby Unchanged Lines", #selector(W.showNearbyUnchanged(_:)), "o", [], symbol: "arrow.up.and.down.text.horizontal")
            alternate(m, "o", [.command, .option])
            item(m, "Show Unchanged Files", #selector(W.toggleUnchangedFiles(_:)), "u", [.command, .control], symbol: "folder")
            item(m, "Wrap Lines", #selector(W.toggleWrap(_:)), "w", [.command, .control, .shift], symbol: "text.append")
            item(m, "Blame", #selector(W.toggleBlame(_:)), "b", [.shift], symbol: "person.text.rectangle")
            alternate(m, "b", [.command, .option])
            m.addItem(.separator())
            item(m, "Show Navigator", #selector(W.toggleNavigatorColumn(_:)), "0", symbol: "sidebar.left")
            item(m, "Show Inspector", #selector(W.toggleInspectorColumn(_:)), "0", [.command, .option], symbol: "sidebar.right")
            item(m, "Zoom Pane", #selector(W.toggleZoomPane(_:)), "\r", [.command, .shift], symbol: "arrow.up.left.and.arrow.down.right")
            m.addItem(.separator())
            item(m, "Bigger", #selector(W.biggerFont(_:)), "+", symbol: "textformat.size.larger")
            item(m, "Bigger", #selector(W.biggerFont(_:)), "=", symbol: "textformat.size.larger")
            m.items.last?.isHidden = true
            m.items.last?.allowsKeyEquivalentWhenHidden = true
            item(m, "Smaller", #selector(W.smallerFont(_:)), "-", symbol: "textformat.size.smaller")
            item(m, "Actual Size", #selector(W.actualSizeFont(_:)), "0", [.command, .control], symbol: "textformat.size")
            m.addItem(.separator())
        }
        _ = menu("Go") { m in
            item(m, "Previous Pane", #selector(W.previousPane(_:)), "[", symbol: "chevron.backward")
            alternate(m, "[", [])
            alternate(m, "o", [.control])
            item(m, "Next Pane", #selector(W.nextPane(_:)), "]", symbol: "chevron.forward")
            alternate(m, "]", [])
            alternate(m, "i", [.control])
            m.addItem(.separator())
            item(m, "Choose What to Review…", #selector(W.chooseSubject(_:)), "r", [.command, .shift], symbol: "arrow.triangle.branch")
            item(m, "Go to Anything…", #selector(W.goToAnything(_:)), "k", symbol: "magnifyingglass")
            alternate(m, "o", [.command, .shift])
            item(m, "Go to Line…", #selector(W.goToLine(_:)), "l", symbol: "number")
            item(m, "Jump to Text…", #selector(W.jumpToText(_:)), "s", [], symbol: "character.cursor.ibeam")
            m.addItem(.separator())
            item(m, "Peek Definition", #selector(W.peekDefinition(_:)), "p", [], symbol: "eye")
            alternate(m, "j", [.command, .option])
            item(m, "Jump to Definition", #selector(W.jumpToDefinitionAction(_:)), "d", [], symbol: "arrow.turn.down.right")
            alternate(m, "j", [.command, .control])
            item(m, "Find References", #selector(W.findReferencesAction(_:)), "d", [.shift], symbol: "arrow.triangle.pull")
            alternate(m, "f", [.command, .control, .shift])
            item(m, "Highlight Uses", #selector(W.highlightUses(_:)), "*", [], symbol: "highlighter")
            item(m, "Next Use", #selector(W.nextUse(_:)), "n", [], symbol: "arrow.down")
            item(m, "Previous Use", #selector(W.previousUse(_:)), "n", [.shift], symbol: "arrow.up")
            m.addItem(.separator())
            item(m, "Definitions", #selector(W.showSymbols(_:)), "6", [.control], symbol: "list.bullet")
            item(m, "Next Definition", #selector(W.nextDefinition(_:)), down, [.control, .option], symbol: "chevron.down")
            item(m, "Previous Definition", #selector(W.previousDefinition(_:)), up, [.control, .option], symbol: "chevron.up")
            item(m, "File History", #selector(W.showFileHistory(_:)), "h", [.command, .control], symbol: "clock.arrow.circlepath")
            m.addItem(.separator())
            item(m, "All Changes", #selector(W.showAllChanges(_:)), "a", [.command, .shift], symbol: "square.stack")
            item(m, "Next Change", #selector(W.nextChange(_:)), "j", [.shift], symbol: "arrow.down")
            alternate(m, down, [.command, .option])
            item(m, "Previous Change", #selector(W.previousChange(_:)), "k", [.shift], symbol: "arrow.up")
            alternate(m, up, [.command, .option])
            item(m, "Next File", #selector(W.nextFile(_:)), "l", [.shift], symbol: "arrow.forward")
            alternate(m, right, [.command, .option])
            item(m, "Previous File", #selector(W.previousFile(_:)), "h", [.shift], symbol: "arrow.backward")
            alternate(m, left, [.command, .option])
            item(m, "Next Unreviewed File", #selector(W.nextUnreviewed(_:)), "u", [], symbol: "circle.dashed")
            alternate(m, "u", [.command, .option])
            m.addItem(.separator())
            item(m, "All Commits", #selector(W.showWholeReview(_:)), "a", [.command, .control], symbol: "square.stack.3d.up")
            item(m, "Uncommitted Changes", #selector(W.showUncommitted(_:)), "u", [.command, .shift], symbol: "pencil.and.list.clipboard")
            item(m, "Older Commit", #selector(W.olderCommit(_:)), down, [.command, .control], symbol: "arrow.down.circle")
            item(m, "Newer Commit", #selector(W.newerCommit(_:)), up, [.command, .control], symbol: "arrow.up.circle")
            m.addItem(.separator())
            item(m, "Navigator", #selector(W.focusNavigator(_:)), "1", [.command, .option], symbol: "sidebar.left")
            item(m, "Reader", #selector(W.focusReader(_:)), "2", [.command, .option], symbol: "doc.plaintext")
            item(m, "Inspector", #selector(W.focusInspector(_:)), "3", [.command, .option], symbol: "sidebar.right")
        }
        _ = menu("Review") { m in
            item(m, "Mark Change as Read", #selector(W.toggleChangeRead(_:)), "r", [], symbol: "checkmark")
            alternate(m, "r", [.command, .option])
            item(m, "Mark File as Reviewed", #selector(W.toggleReviewedAction(_:)), "r", [.shift], symbol: "checkmark.circle")
            alternate(m, "r", [.command, .control])
            item(m, "Mark All as Reviewed", #selector(W.markAllReviewed(_:)), "", symbol: "checkmark.circle.fill")
            item(m, "Mark All as Not Reviewed", #selector(W.markAllNotReviewed(_:)), "", symbol: "circle")
            m.addItem(.separator())
            item(m, "Add Note", #selector(W.addNote(_:)), "c", [], symbol: "text.bubble")
            alternate(m, "n", [.command, .option])
            item(m, "Add Note on Whole Review", #selector(W.addReviewNote(_:)), "c", [.shift], symbol: "text.bubble.fill")
            alternate(m, "n", [.command, .option, .shift])
            item(m, "Copy Notes as Markdown", #selector(W.copyAllNotes(_:)), "c", [.command, .shift], symbol: "doc.on.clipboard")
        }
        let window = menu("Window") { m in
            item(m, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", symbol: "minus.rectangle")
            item(m, "Zoom", #selector(NSWindow.performZoom(_:)), "", [], symbol: "arrow.up.left.and.arrow.down.right")
            m.addItem(.separator())
            item(m, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "", [], symbol: "macwindow.on.rectangle")
        }
        NSApp.windowsMenu = window
        let help = menu("Help") { _ in }
        NSApp.helpMenu = help
        return main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

extension NSApplication {
    /// Whether the app was started behind the windows in use (`--background`), as benchmarks
    /// start it, so it must never bring a window forward or sound the alert.
    var runsBehind: Bool { (delegate as? AppDelegate)?.inBackground == true }
}

extension NSWindow {
    /// Makes the window key and brings it forward, or, when the app runs behind, makes it key
    /// where it is, putting it behind the windows in use if it isn't shown yet.
    func raise() {
        guard NSApp.runsBehind else { return makeKeyAndOrderFront(nil) }
        if !isVisible { orderBack(nil) }
        makeKey()
    }
}

/// Sounds the alert for a command that can't be done, or, while a script drives the app behind
/// the windows in use, logs it instead.
@MainActor
func beep() {
    if NSApp.runsBehind, let automation = Automation.running { automation.log("! beep") } else { NSSound.beep() }
}
