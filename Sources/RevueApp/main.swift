import AppKit
import RevueCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var controllers: [RepoWindowController] = []
    private var settingsWindow: NSWindow?
    var automation: Automation?
    /// Whether automation runs without taking focus, behind the windows of the app in use.
    var inBackground = false

    lazy var gitPath: String = {
        if let p = ProcessInfo.processInfo.environment["REVUE_GIT"], FileManager.default.isExecutableFile(atPath: p) { return p }
        if let p = Bundle.main.object(forInfoDictionaryKey: "RevueGitPath") as? String, FileManager.default.isExecutableFile(atPath: p) { return p }
        for dir in userPath().split(separator: ":") {
            let p = "\(dir)/git"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "/usr/bin/git"
    }()

    func applicationWillFinishLaunching(_ notification: Notification) {
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
            if url.scheme == "revue" {
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
                let loc = try await Git.locate(url.hasDirectoryPath || isDirectory(url) ? url : url.deletingLastPathComponent(), executable: gitPath)
                if let existing = controllers.first(where: { $0.repository.commonDir.standardizedFileURL == loc.commonDir.standardizedFileURL }) {
                    existing.showWindow(nil)
                    existing.window?.makeKeyAndOrderFront(nil)
                    if let spec { await existing.open(spec: spec, in: loc.root) } else { existing.openWork(in: loc.root) }
                    if !inBackground { NSApp.activate() }
                    completion?(existing)
                    return
                }
                let repository = Repository(commonDir: loc.commonDir, gitPath: gitPath)
                let git = repository.git
                let opening = Task.detached { await Repository.open(spec, in: loc.root, git: git, commonDir: loc.commonDir) }
                let wc = RepoWindowController(repository: repository, home: loc.root)
                controllers.append(wc)
                wc.showWindow(nil)
                wc.window?.makeKeyAndOrderFront(nil)
                wc.reader.focus()
                if inBackground { wc.window?.orderBack(nil) } else { NSApp.activate() }
                wc.start(spec: spec, opening: opening)
                NSDocumentController.shared.noteNewRecentDocumentURL(loc.root)
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
        func item(_ m: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], tag: Int = 0) {
            let shifted = mods.contains(.shift) && key.count == 1 && key.first!.isLetter
            let i = NSMenuItem(title: title, action: action, keyEquivalent: shifted ? key.uppercased() : key)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
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

        _ = menu("Revue") { m in
            item(m, "About Revue", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", [])
            m.addItem(.separator())
            item(m, "Settings…", #selector(showSettings(_:)), ",")
            m.addItem(.separator())
            let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
            services.submenu = NSMenu()
            NSApp.servicesMenu = services.submenu
            m.addItem(services)
            m.addItem(.separator())
            item(m, "Hide Revue", #selector(NSApplication.hide(_:)), "h")
            item(m, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            item(m, "Show All", #selector(NSApplication.unhideAllApplications(_:)), "", [])
            m.addItem(.separator())
            item(m, "Quit Revue", #selector(NSApplication.terminate(_:)), "q")
        }
        typealias W = RepoWindowController
        _ = menu("File") { m in
            item(m, "Open…", #selector(openDocument(_:)), "o")
            let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
            let rm = NSMenu(title: "Open Recent")
            rm.perform(NSSelectorFromString("_setMenuName:"), with: "NSRecentDocumentsMenu")
            rm.addItem(NSMenuItem(title: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: ""))
            recent.submenu = rm
            m.addItem(recent)
            m.addItem(.separator())
            item(m, "Close Pane", #selector(W.closePane(_:)), "w")
            item(m, "Close Other Panes", #selector(W.closeOtherPanes(_:)), "w", [.command, .option])
            m.addItem(.separator())
            item(m, "Open in Editor", #selector(W.openCurrentInEditor(_:)), "e", [])
            item(m, "Refresh", #selector(W.refreshAction(_:)), "r")
        }
        _ = menu("Edit") { m in
            item(m, "Copy", #selector(NSText.copy(_:)), "c")
            item(m, "Copy Reference", #selector(W.copyReference(_:)), "c", [.command, .option])
            item(m, "Copy Reference with Code", #selector(W.copyReferenceWithCode(_:)), "c", [.command, .option, .shift])
            item(m, "Copy Symbol Name", #selector(W.copySymbol(_:)), "c", [.command, .control, .shift])
            item(m, "Copy Path", #selector(W.copyCurrentPath(_:)), "")
            item(m, "Select All", #selector(NSText.selectAll(_:)), "a")
            m.addItem(.separator())
            let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
            let fm = NSMenu(title: "Find")
            item(fm, "Find…", #selector(NSResponder.performTextFinderAction(_:)), "f", tag: NSTextFinder.Action.showFindInterface.rawValue)
            item(fm, "Find Next", #selector(NSResponder.performTextFinderAction(_:)), "g", tag: NSTextFinder.Action.nextMatch.rawValue)
            item(fm, "Find Previous", #selector(NSResponder.performTextFinderAction(_:)), "g", [.command, .shift], tag: NSTextFinder.Action.previousMatch.rawValue)
            item(fm, "Use Selection for Find", #selector(NSResponder.performTextFinderAction(_:)), "e", tag: NSTextFinder.Action.setSearchString.rawValue)
            fm.addItem(.separator())
            item(fm, "Find in Files…", #selector(W.findInRepository(_:)), "f", [.command, .shift])
            item(fm, "Find File…", #selector(W.focusFilter(_:)), "f", [.command, .option])
            find.submenu = fm
            m.addItem(find)
        }
        _ = menu("View") { m in
            item(m, "Changes", #selector(W.showChangesTab(_:)), "1")
            item(m, "Find", #selector(W.showFindTab(_:)), "2")
            m.addItem(.separator())
            item(m, "Unified", #selector(W.showUnified(_:)), "1", [.command, .control])
            item(m, "Side by Side", #selector(W.showSideBySide(_:)), "2", [.command, .control])
            item(m, "Show Unchanged Lines", #selector(W.toggleShowAll(_:)), "f", [])
            item(m, "Show Nearby Unchanged Lines", #selector(W.showNearbyUnchanged(_:)), "o", [])
            alternate(m, "o", [.command, .option])
            item(m, "Show Unchanged Files", #selector(W.toggleUnchangedFiles(_:)), "u", [.command, .control])
            item(m, "Wrap Lines", #selector(W.toggleWrap(_:)), "w", [.command, .control, .shift])
            item(m, "Blame", #selector(W.toggleBlame(_:)), "b", [.shift])
            alternate(m, "b", [.command, .option])
            m.addItem(.separator())
            item(m, "Show Navigator", #selector(NSSplitViewController.toggleSidebar(_:)), "0")
            item(m, "Show Inspector", #selector(NSSplitViewController.toggleInspector(_:)), "0", [.command, .option])
            m.addItem(.separator())
            item(m, "Bigger", #selector(W.biggerFont(_:)), "+")
            item(m, "Bigger", #selector(W.biggerFont(_:)), "=")
            m.items.last?.isHidden = true
            m.items.last?.allowsKeyEquivalentWhenHidden = true
            item(m, "Smaller", #selector(W.smallerFont(_:)), "-")
            item(m, "Actual Size", #selector(W.actualSizeFont(_:)), "0", [.command, .control])
            m.addItem(.separator())
        }
        _ = menu("Go") { m in
            item(m, "Previous Pane", #selector(W.previousPane(_:)), "[")
            alternate(m, "[", [])
            alternate(m, "o", [.control])
            item(m, "Next Pane", #selector(W.nextPane(_:)), "]")
            alternate(m, "]", [])
            alternate(m, "i", [.control])
            m.addItem(.separator())
            item(m, "Choose What to Review…", #selector(W.chooseSubject(_:)), "r", [.command, .shift])
            item(m, "Go to Anything…", #selector(W.goToAnything(_:)), "k")
            alternate(m, "o", [.command, .shift])
            item(m, "Go to Line…", #selector(W.goToLine(_:)), "l")
            item(m, "Jump to Text…", #selector(W.jumpToText(_:)), "s", [])
            m.addItem(.separator())
            item(m, "Peek Definition", #selector(W.peekDefinition(_:)), "p", [])
            alternate(m, "j", [.command, .option])
            item(m, "Jump to Definition", #selector(W.jumpToDefinitionAction(_:)), "d", [])
            alternate(m, "j", [.command, .control])
            item(m, "Find References", #selector(W.findReferencesAction(_:)), "d", [.shift])
            alternate(m, "f", [.command, .control, .shift])
            item(m, "Highlight Uses", #selector(W.highlightUses(_:)), "*", [])
            item(m, "Next Use", #selector(W.nextUse(_:)), "n", [])
            item(m, "Previous Use", #selector(W.previousUse(_:)), "n", [.shift])
            m.addItem(.separator())
            item(m, "Definitions", #selector(W.showSymbols(_:)), "6", [.control])
            item(m, "Next Definition", #selector(W.nextDefinition(_:)), down, [.control, .option])
            item(m, "Previous Definition", #selector(W.previousDefinition(_:)), up, [.control, .option])
            item(m, "File History", #selector(W.showFileHistory(_:)), "h", [.command, .control])
            m.addItem(.separator())
            item(m, "All Changes", #selector(W.showAllChanges(_:)), "a", [.command, .shift])
            item(m, "Next Change", #selector(W.nextChange(_:)), "j", [.shift])
            alternate(m, down, [.command, .option])
            item(m, "Previous Change", #selector(W.previousChange(_:)), "k", [.shift])
            alternate(m, up, [.command, .option])
            item(m, "Next File", #selector(W.nextFile(_:)), "l", [.shift])
            alternate(m, right, [.command, .option])
            item(m, "Previous File", #selector(W.previousFile(_:)), "h", [.shift])
            alternate(m, left, [.command, .option])
            item(m, "Next Unreviewed File", #selector(W.nextUnreviewed(_:)), "u", [])
            alternate(m, "u", [.command, .option])
            m.addItem(.separator())
            item(m, "All Commits", #selector(W.showWholeReview(_:)), "a", [.command, .control])
            item(m, "Uncommitted Changes", #selector(W.showUncommitted(_:)), "u", [.command, .shift])
            item(m, "Older Commit", #selector(W.olderCommit(_:)), down, [.command, .control])
            item(m, "Newer Commit", #selector(W.newerCommit(_:)), up, [.command, .control])
            m.addItem(.separator())
            item(m, "Navigator", #selector(W.focusNavigator(_:)), "1", [.command, .option])
            item(m, "Reader", #selector(W.focusReader(_:)), "2", [.command, .option])
            item(m, "Inspector", #selector(W.focusInspector(_:)), "3", [.command, .option])
        }
        _ = menu("Review") { m in
            item(m, "Mark Change as Read", #selector(W.toggleChangeRead(_:)), "r", [])
            alternate(m, "r", [.command, .option])
            item(m, "Mark File as Reviewed", #selector(W.toggleReviewedAction(_:)), "r", [.shift])
            alternate(m, "r", [.command, .control])
            item(m, "Mark All as Reviewed", #selector(W.markAllReviewed(_:)), "")
            item(m, "Mark All as Not Reviewed", #selector(W.markAllNotReviewed(_:)), "")
            m.addItem(.separator())
            item(m, "Add Note", #selector(W.addNote(_:)), "c", [])
            alternate(m, "n", [.command, .option])
            item(m, "Add Note on Whole Review", #selector(W.addReviewNote(_:)), "c", [.shift])
            alternate(m, "n", [.command, .option, .shift])
            item(m, "Copy Notes as Markdown", #selector(W.copyAllNotes(_:)), "")
        }
        let window = menu("Window") { m in
            item(m, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            item(m, "Zoom", #selector(NSWindow.performZoom(_:)), "", [])
            m.addItem(.separator())
            item(m, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "", [])
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
