import AppKit
import RevueCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var controllers: [RepoWindowController] = []
    private var settingsWindow: NSWindow?
    var automation: Automation?

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

    func openRepo(path: String, spec: String?, completion: ((RepoWindowController?) -> Void)? = nil) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        Task {
            do {
                let loc = try await Git.locate(url.hasDirectoryPath || isDirectory(url) ? url : url.deletingLastPathComponent(), executable: gitPath)
                if let existing = controllers.first(where: { $0.repo.root.standardizedFileURL == loc.root.standardizedFileURL }) {
                    existing.showWindow(nil)
                    existing.window?.makeKeyAndOrderFront(nil)
                    if let spec { await existing.open(spec: spec) }
                    NSApp.activate()
                    completion?(existing)
                    return
                }
                let wc = RepoWindowController(repo: Repo(location: loc, gitPath: gitPath))
                controllers.append(wc)
                wc.showWindow(nil)
                wc.window?.makeKeyAndOrderFront(nil)
                wc.reader.focus()
                NSApp.activate()
                wc.start(spec: spec)
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
        UserDefaults.standard.set(controllers.map(\.repo.root.path), forKey: "openRepos")
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

    func validateMenuItem(_ item: NSMenuItem) -> Bool { true }

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
        let arrowDown = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        let arrowUp = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))

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
            item(m, "Close", #selector(NSWindow.performClose(_:)), "w")
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
            item(fm, "Find in Repository…", #selector(W.findInRepository(_:)), "f", [.command, .shift])
            item(fm, "Find References", #selector(W.findReferencesAction(_:)), "f", [.command, .control, .shift])
            item(fm, "Filter", #selector(W.focusFilter(_:)), "f", [.command, .option])
            find.submenu = fm
            m.addItem(find)
        }
        _ = menu("View") { m in
            item(m, "Changes", #selector(W.showChangesTab(_:)), "1")
            item(m, "Files", #selector(W.showFilesTab(_:)), "2")
            item(m, "Search", #selector(W.showSearchTab(_:)), "3")
            item(m, "Notes", #selector(W.showNotesTab(_:)), "4")
            m.addItem(.separator())
            item(m, "Unified", #selector(W.showUnified(_:)), "1", [.command, .control])
            item(m, "Side by Side", #selector(W.showSideBySide(_:)), "2", [.command, .control])
            item(m, "Show Unchanged Lines", #selector(W.toggleShowAll(_:)), "f", [])
            item(m, "Wrap Lines", #selector(W.toggleWrap(_:)), "w", [.command, .control, .shift])
            item(m, "Blame", #selector(W.toggleBlame(_:)), "b", [.command, .option])
            m.addItem(.separator())
            item(m, "Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control])
            item(m, "Hide Navigator", #selector(W.toggleNavigator(_:)), "n", [.command, .control])
            m.addItem(.separator())
            item(m, "Bigger", #selector(W.biggerFont(_:)), "+")
            item(m, "Bigger", #selector(W.biggerFont(_:)), "=")
            m.items.last?.isHidden = true
            m.items.last?.allowsKeyEquivalentWhenHidden = true
            item(m, "Smaller", #selector(W.smallerFont(_:)), "-")
            item(m, "Actual Size", #selector(W.actualSizeFont(_:)), "0")
            m.addItem(.separator())
        }
        _ = menu("Go") { m in
            item(m, "Back", #selector(W.goBack(_:)), "[")
            item(m, "Forward", #selector(W.goForward(_:)), "]")
            m.addItem(.separator())
            item(m, "Open Quickly…", #selector(W.openQuickly(_:)), "o", [.command, .shift])
            item(m, "Go to Line…", #selector(W.goToLine(_:)), "l")
            item(m, "Jump to Definition", #selector(W.jumpToDefinitionAction(_:)), "j", [.command, .control])
            item(m, "Symbols", #selector(W.showSymbols(_:)), "6", [.control])
            item(m, "File History", #selector(W.showFileHistory(_:)), "h", [.command, .control])
            m.addItem(.separator())
            item(m, "All Changes", #selector(W.showAllChanges(_:)), "a", [.command, .shift])
            item(m, "Next Change", #selector(W.nextChange(_:)), "j", [])
            item(m, "Previous Change", #selector(W.previousChange(_:)), "k", [])
            item(m, "Next File", #selector(W.nextFile(_:)), "n", [])
            item(m, "Previous File", #selector(W.previousFile(_:)), "p", [])
            item(m, "Next Unreviewed File", #selector(W.nextUnreviewed(_:)), "u", [])
            m.addItem(.separator())
            item(m, "Uncommitted Changes", #selector(W.showUncommitted(_:)), "u", [.command, .shift])
            item(m, "Current Branch", #selector(W.showBranch(_:)), "b", [.command, .shift])
            item(m, "Revision…", #selector(W.goToRevision(_:)), "r", [.command, .shift])
            item(m, "Older Commit", #selector(W.olderCommit(_:)), arrowDown, [.command])
            item(m, "Newer Commit", #selector(W.newerCommit(_:)), arrowUp, [.command])
            m.addItem(.separator())
            item(m, "History", #selector(W.focusSidebar(_:)), "1", [.command, .option])
            item(m, "Navigator", #selector(W.focusNavigator(_:)), "2", [.command, .option])
            item(m, "Reader", #selector(W.focusReader(_:)), "3", [.command, .option])
        }
        _ = menu("Review") { m in
            item(m, "Mark as Reviewed", #selector(W.toggleReviewedAction(_:)), "r", [])
            item(m, "Mark All as Reviewed", #selector(W.markAllReviewed(_:)), "r", [.command, .option])
            item(m, "Mark All as Not Reviewed", #selector(W.markAllNotReviewed(_:)), "r", [.command, .option, .shift])
            m.addItem(.separator())
            item(m, "Add Note", #selector(W.addNote(_:)), "c", [])
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
