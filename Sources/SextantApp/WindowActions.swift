import AppKit
import SextantCore

/// What the window says about its review: titles, labels and the inspector's card.
extension RepoWindowController {
    /// What’s being reviewed, as the window names it.
    var subjectLabel: (title: String, symbol: String, tooltip: String) {
        switch review?.subject {
        case .worktree(let root)?:
            let w = repository.worktree(at: root)
            return (w?.branch ?? root.name, "folder", "Worktree at \(abbreviateHome(root.path))")
        case .branch(let b)?:
            return (b, "arrow.triangle.branch", "Branch \(b)")
        case .pullRequest(let n)?:
            let title = resolved?.pullRequest?.title ?? repository.pullRequests?.first { $0.number == n }?.title
            return ("#\(n)" + (title.map { "  " + $0 } ?? ""), "arrow.triangle.pull", "Pull request #\(n)")
        case .commit(let c)?:
            return (String(c.prefix(7)) + (commitDetail.map { "  " + $0.summary } ?? ""), "smallcircle.filled.circle", "Commit \(c)")
        case .comparison(let a, let b, let since)?:
            return ("\(a)\(since ? "..." : "..")\(b)", "arrow.left.arrow.right", since ? "Changes on \(b) since it split from \(a)" : "Differences from \(a) to \(b)")
        case .stash(let s)?:
            let ref = repository.stashes.first { $0.oid == s }?.ref ?? String(s.prefix(7))
            return (ref, "tray", "Stash \(ref)")
        case nil:
            return ("Choose What to Review", "magnifyingglass", "Choose a worktree, pull request, branch or commit")
        }
    }

    /// The part of the review being read, such as "2 commits and uncommitted changes".
    var scopeLabel: String {
        guard let r = review else { return "" }
        let commits = resolved?.commits ?? []
        let n = commits.count
        func plural(_ k: Int, _ word: String) -> String { "\(k) \(word)\(k == 1 ? "" : "s")" }
        switch r.scope {
        case .uncommitted: return "Uncommitted changes"
        case .staged: return "Staged changes"
        case .unstaged: return "Unstaged changes"
        case .commits(let newest, let oldest):
            if newest == oldest {
                let c = commits.first { $0.oid == newest }
                return String(newest.prefix(7)) + (c.map { "  " + $0.subject } ?? "")
            }
            let a = commits.firstIndex { $0.oid == newest } ?? 0, b = commits.firstIndex { $0.oid == oldest } ?? 0
            return "\(abs(b - a) + 1) of \(plural(n, "commit"))"
        case .everything:
            switch r.subject {
            case .worktree: return n == 0 ? "Uncommitted changes" : "\(plural(n, "commit")) and uncommitted changes"
            case .branch, .pullRequest, .comparison: return plural(n, "commit") + (r.base.map { " since \($0)" } ?? "")
            case .commit: return commitDetail.map { "\($0.oid.prefix(7))  \($0.summary)" } ?? "Commit"
            case .stash(let s): return repository.stashes.first { $0.oid == s }?.subject ?? "Stash"
            }
        }
    }

    func updateTitle() {
        guard let window else { return }
        window.title = repository.name
        frame.show(reviewSummary)
    }

    /// What the inspector says about the review: its commit, pull request, branch or worktree,
    /// and the blame of the caret's line.
    func card() -> (title: String, text: NSAttributedString)? {
        guard let res = resolved else { return nil }
        let s = NSMutableAttributedString()
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.row.pointSize, weight: .semibold), .foregroundColor: NSColor.themed("fg")]
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.row, .foregroundColor: NSColor.themed("fg")]
        let meta: [NSAttributedString.Key: Any] = [.font: NSFont.detail, .foregroundColor: NSColor.themed("fgMuted")]
        let mono: [NSAttributedString.Key: Any] = [.font: NSFont.detailCode, .foregroundColor: NSColor.themed("fgMuted")]
        func add(_ text: String, _ attrs: [NSAttributedString.Key: Any]) {
            if s.length > 0 { s.append(NSAttributedString(string: "\n", attributes: attrs)) }
            s.append(NSAttributedString(string: text, attributes: attrs))
        }
        let date = { (d: Date) in d.formatted(date: .abbreviated, time: .shortened) }
        let n = res.commits.count
        let title: String
        if let d = commitDetail {
            if case .stash = res.target { title = "Stash" } else { title = "Commit" }
            add(d.summary, bold)
            if !d.body.isEmpty { add(d.body, body) }
            add("\(d.author)  ·  \(date(d.authorDate))", meta)
            add(d.oid, mono)
        } else {
            switch res.review.subject {
            case .pullRequest(let num):
                title = "Pull Request"
                let p = res.pullRequest
                add("#\(num)  \(p?.title ?? "")", bold)
                if let p { add("\(p.author.login) wants to merge \(p.headRefName) into \(p.baseRefName)" + (p.isDraft ? "  ·  Draft" : ""), meta) }
                add("\(n) commit\(n == 1 ? "" : "s")" + (res.review.base.map { " since \($0)" } ?? ""), meta)
            case .worktree(let root):
                title = "Worktree"
                let w = res.worktree
                add(w?.branch ?? "Detached at \(w?.head?.prefix(7) ?? "nothing")", bold)
                add(abbreviateHome(root.path), meta)
                add("\(n) commit\(n == 1 ? "" : "s")" + (res.review.base.map { " since \($0)" } ?? ""), meta)
                if let failure = repository.statusFailures[root] {
                    add("Couldn’t read what isn’t committed: \(failure)", meta)
                } else {
                    let u = repository.uncommitted[root] ?? 0
                    add("\(u) uncommitted file\(u == 1 ? "" : "s")", meta)
                }
            case .branch(let b):
                title = "Branch"
                add(b, bold)
                if let br = repository.branches.first(where: { $0.name == b }), let ahead = br.ahead, let behind = br.behind, repository.defaultBase == res.review.base {
                    add("\(ahead) ahead, \(behind) behind \(res.review.base ?? "")", meta)
                } else {
                    add("\(n) commit\(n == 1 ? "" : "s")" + (res.review.base.map { " since \($0)" } ?? ""), meta)
                }
                if let w = repository.worktree(onBranch: b) { add("Checked out at \(abbreviateHome(w.root.path))", meta) }
            case .comparison(let a, let b, let since):
                title = "Comparison"
                add("\(a)\(since ? "..." : "..")\(b)", bold)
                add("\(n) commit\(n == 1 ? "" : "s")", meta)
            default:
                return nil
            }
            if let mb = res.mergeBase { add("Base \(mb.prefix(7))", mono) }
        }
        if blameOn, let f = focusedFile?.text, let caret = reader.caret, f.lines.indices.contains(caret.line), f.lines[caret.line].kind != .deleted,
           let c = reader.blame?.commit(forLine: f.lines[caret.line].newNo - 1) {
            add("", meta)
            add("Line \(f.lines[caret.line].newNo)", bold)
            if c.isUncommitted {
                add("Not committed yet", meta)
            } else {
                add(c.summary, body)
                add("\(c.author)  ·  \(date(c.date))  ·  \(c.oid.prefix(7))", meta)
            }
        }
        return (title, s)
    }
}

/// Menu commands, context menus and the actions behind them.
extension RepoWindowController: NSMenuItemValidation {
    func add(_ m: NSMenu, _ title: String, _ sel: Selector, _ obj: Any? = nil) {
        let item = m.addItem(withTitle: title, action: sel, keyEquivalent: "")
        item.target = self
        item.representedObject = obj
    }

    @objc func copyString(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        copy(s)
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func navigatorFileMenu(_ paths: [String]) -> NSMenu? {
        let m = NSMenu()
        let files = changes.filter { paths.contains($0.path) }
        let reviewed = !files.isEmpty && files.allSatisfy(\.reviewed)
        add(m, reviewed ? "Mark as Not Reviewed" : "Mark as Reviewed", #selector(menuToggleReviewed(_:)), paths)
        m.addItem(.separator())
        if paths.count == 1 {
            fileItems(m, path: paths[0])
        } else {
            add(m, "Copy Paths", #selector(copyString(_:)), paths.joined(separator: "\n"))
        }
        return m
    }

    func navigatorCommitMenu(_ commit: Commit) -> NSMenu? {
        let m = NSMenu()
        add(m, "Copy Commit Hash", #selector(copyString(_:)), commit.oid)
        add(m, "Mark Commit as Reviewed", #selector(markCommit(_:)), [commit.oid, true] as [Any])
        add(m, "Mark Commit as Not Reviewed", #selector(markCommit(_:)), [commit.oid, false] as [Any])
        m.addItem(.separator())
        add(m, "Review This Commit on Its Own", #selector(reviewCommit(_:)), commit.oid)
        return m
    }

    @objc func markCommit(_ sender: NSMenuItem) {
        guard let arr = sender.representedObject as? [Any], let oid = arr[0] as? String, let v = arr[1] as? Bool,
              let c = resolved?.commits.first(where: { $0.oid == oid }), let review else { return }
        repository.reviews.set(c.changes, reviewed: v, in: review)
    }

    @objc func reviewCommit(_ sender: NSMenuItem) {
        guard let oid = sender.representedObject as? String else { return }
        select(Review(subject: .commit(oid)))
    }

    private func fileItems(_ m: NSMenu, path: String) {
        add(m, "Open in Editor", #selector(menuOpenInEditor(_:)), [path, 0] as [Any])
        add(m, "Reveal in Finder", #selector(menuReveal(_:)), path)
        add(m, "Copy Path", #selector(copyString(_:)), path)
    }

    @objc func menuToggleReviewed(_ sender: NSMenuItem) {
        guard let paths = sender.representedObject as? [String] else { return }
        toggleReviewed(paths, advance: false)
    }

    @objc func menuOpenInEditor(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? [Any], let path = a[0] as? String else { return }
        openInEditor(path: path, line: a[1] as? Int ?? 0)
    }

    /// The checkout that files open from: the reviewed worktree, or the one on the reviewed branch.
    var checkout: CanonicalPath? {
        review.flatMap { repository.checkout(for: $0.subject, pullRequest: resolved?.pullRequest) } ?? home
    }

    @objc func menuReveal(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, let root = checkout else { return }
        let url = root.url.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            beep()
        }
    }

    /// Opens a file of the checkout in the user's editor, which may differ from the revision read.
    func openInEditor(path: String, line: Int) {
        guard let root = checkout else { beep(); return }
        let url = root.url.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { beep(); return }
        if let cmd = UserDefaults.standard.string(forKey: "editorCommand"), !cmd.trimmingCharacters(in: .whitespaces).isEmpty {
            let full = cmd.replacingOccurrences(of: "{file}", with: shellQuote(url.path)).replacingOccurrences(of: "{line}", with: String(max(1, line)))
            Task {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", full]
                p.currentDirectoryURL = root.url
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = await UserTools.path.value
                p.environment = env
                do { try p.run() } catch { showError(error) }
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Finds a name's uses and definitions in the snapshot the review reads.
    private func lookUp(_ word: String, in t: Target) async throws -> (matches: [GrepMatch], definitions: [GrepMatch]) {
        try await repository.definitions.lookUp(word, in: t.snapshot, git: git)
    }

    /// Sorts definitions nearest first: the same file, then files sharing the most directories.
    private func nearest(_ defs: [GrepMatch], to path: String?) -> [GrepMatch] {
        guard let path else { return defs.sorted { ($0.path, $0.line) < ($1.path, $1.line) } }
        let here = path.split(separator: "/")
        func closeness(_ p: String) -> Int {
            if p == path { return Int.max }
            return zip(here, p.split(separator: "/")).prefix { $0 == $1 }.count
        }
        return defs.sorted { a, b in
            let ca = closeness(a.path), cb = closeness(b.path)
            return ca != cb ? ca > cb : (a.path, a.line) < (b.path, b.line)
        }
    }

    /// Goes to a name's definition, offering a menu at the caret when there are several, and
    /// listing every use in Find when there are none.
    func jumpToDefinition(_ word: String, from path: String?) {
        guard let t = target else { return }
        definitionTask?.cancel()
        busy += 1
        definitionTask = Task {
            defer { busy -= 1 }
            guard let (matches, definitions) = try? await lookUp(word, in: t), !Task.isCancelled else { return }
            let defs = nearest(definitions, to: path)
            if defs.count == 1 {
                openBeside(defs[0].path, line: defs[0].line)
            } else if defs.isEmpty {
                findTask?.cancel()
                revealNavigator(.find)
                navigator.search.begin(word, word: true)
                navigator.search.show(Array(matches.prefix(5000)), title: word, capped: matches.count > 5000)
                navigator.search.summary = "No definition found. " + navigator.search.summary
                takeKeyboardToResults()
            } else {
                showDefinitionsMenu(defs, word: word)
            }
        }
    }

    private func showDefinitionsMenu(_ defs: [GrepMatch], word: String) {
        let m = NSMenu(title: "Definitions of \(word)")
        m.addItem(withTitle: "\(defs.count) Definitions of \(word)", action: nil, keyEquivalent: "").isEnabled = false
        for d in defs.prefix(40) {
            let item = m.addItem(withTitle: "", action: #selector(openDefinition(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [d.path, d.line] as [Any]
            item.image = fileIcon(d.path)
            let s = NSMutableAttributedString(string: "\((d.path as NSString).lastPathComponent):\(d.line)  ", attributes: [.font: NSFont.menuFont(ofSize: 13)])
            s.append(NSAttributedString(string: d.text.trimmingCharacters(in: .whitespaces).prefix(60) + "", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = s
            item.toolTip = d.path
        }
        let code = reader.activeCode
        var at = NSPoint(x: code.visibleRect.minX + 40, y: code.visibleRect.minY + 40)
        if let r = reader.caretRow, let lm = code.layoutManager, let tc = code.textContainer {
            let glyph = lm.glyphIndexForCharacter(at: code.selectedRange().location)
            let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 0), in: tc)
            at = NSPoint(x: rect.minX + code.textContainerOrigin.x, y: code.rect(ofRow: r).maxY + 2)
        }
        m.popUp(positioning: m.items.count > 1 ? m.items[1] : nil, at: at, in: code)
    }

    @objc func openDefinition(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? [Any], let path = a[0] as? String, let line = a[1] as? Int else { return }
        openBeside(path, line: line)
    }

    func findReferences(_ word: String) {
        guard let t = target else { return }
        revealNavigator(.find)
        navigator.search.begin(word, word: true)
        findTask?.cancel()
        busy += 1
        findTask = Task {
            defer { busy -= 1 }
            guard let (matches, definitions) = try? await lookUp(word, in: t), !Task.isCancelled else { return }
            let defLines = Dictionary(grouping: definitions, by: \.path).mapValues { Set($0.map(\.line)) }
            navigator.search.show(Array(matches.prefix(5000)), title: word, definitions: defLines, capped: matches.count > 5000)
            takeKeyboardToResults()
        }
    }

    /// Moves the keyboard from the code to search results it asked for, unless it has since
    /// gone somewhere else.
    private func takeKeyboardToResults() {
        guard window?.firstResponder is CodeView else { return }
        navigator.search.focusResults()
    }

    /// Goes to a definition in the file being read.
    func goToDefinition(_ s: Symbol) {
        guard let f = focusedFile?.text, let i = f.index(ofLine: s.nameLine + 1) else { return }
        reader.land(onLine: i)
    }

    /// Opens a line of a file in a new pane beside the focused one.
    func openBeside(_ path: String, line: Int) {
        branch()
        open(path, at: .line(SideLine(number: line, old: false)))
    }

    func revealNavigator(_ tab: Navigator.Tab, focus: Bool = false) {
        setShown(.navigator, true)
        navigator.show(tab, focus: focus)
    }

    func loadBlame(_ f: FileState) {
        guard let t = target, !f.diff.change.isDeleted, !f.diff.isBinary else { return }
        let path = f.path
        let git = self.git
        busy += 1
        Task {
            defer { busy -= 1 }
            let b = try? await git.blame(path, in: t.snapshot)
            guard blameOn, target == t, focusedFile?.file === f else { return }
            reader.blame = b
            inspector.updateCard(card())
        }
    }

    @objc func toggleBlame(_ sender: Any?) {
        blameOn.toggle()
        if blameOn, let f = focusedFile?.file { loadBlame(f) } else { reader.blame = nil; inspector.updateCard(card()) }
    }

    /// Lists the commits that touched the focused file, newest first.
    ///
    /// Choosing one reads the file at that commit.
    @objc func showFileHistory(_ sender: Any?) {
        guard let f = focusedFile?.file, let t = target else { beep(); return }
        let from: String = switch t.snapshot {
        case .commit(let c): c
        default: "HEAD"
        }
        let path = f.path
        let git = self.git
        busy += 1
        Task {
            defer { busy -= 1 }
            let commits = (try? await git.history(of: path, from: from, count: 100)) ?? []
            let m = NSMenu()
            m.addItem(withTitle: "History of \((path as NSString).lastPathComponent)", action: nil, keyEquivalent: "").isEnabled = false
            if commits.isEmpty { m.addItem(withTitle: "No commits", action: nil, keyEquivalent: "").isEnabled = false }
            for c in commits {
                let item = m.addItem(withTitle: "", action: #selector(openHistoryCommit(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [c.oid, path]
                let s = NSMutableAttributedString(string: c.shortOid + "  ", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
                s.append(NSAttributedString(string: c.subject.count > 70 ? c.subject.prefix(69) + "…" : c.subject, attributes: [.font: NSFont.menuFont(ofSize: 13)]))
                s.append(NSAttributedString(string: "  " + compactDate(c.date) + "  " + c.author, attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
                item.attributedTitle = s
                if case .commit(let cur) = t, cur == c.oid { item.state = .on }
            }
            let bar = reader.header
            m.popUp(positioning: nil, at: NSPoint(x: 8, y: bar.isFlipped ? bar.bounds.maxY : bar.bounds.minY), in: bar)
        }
    }

    @objc func openHistoryCommit(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? [String], a.count == 2 else { return }
        let line = currentLocation()?.top ?? SideLine(number: 1, old: false)
        let r = Review(subject: .commit(a[0]))
        select(r, then: Location(review: r, place: .file(a[1]), top: line, caret: nil), in: branch())
    }

    func readerMenu(file: Int?, line: Int?) -> NSMenu? {
        let m = NSMenu()
        if line != nil {
            add(m, "Copy Reference", #selector(copyReference(_:)))
            add(m, "Copy Reference with Code", #selector(copyReferenceWithCode(_:)))
            add(m, "Add Note", #selector(addNote(_:)))
            if let w = reader.wordAtCaret, w.count < 100 {
                m.addItem(.separator())
                add(m, "Jump to Definition", #selector(jumpToDefinitionAction(_:)))
                add(m, "Find References", #selector(findReferencesAction(_:)))
            }
            m.addItem(.separator())
        }
        if let file, reader.files.indices.contains(file) {
            let f = reader.files[file].file
            if f.isChange {
                add(m, f.reviewed ? "Mark as Not Reviewed" : "Mark as Reviewed", #selector(menuToggleReviewed(_:)), [f.path])
                m.addItem(.separator())
            }
            let n = line.flatMap { reader.sideLine(at: ReaderPosition(file: file, line: $0))?.number } ?? 0
            add(m, "Open in Editor", #selector(menuOpenInEditor(_:)), [f.path, n] as [Any])
            add(m, "Reveal in Finder", #selector(menuReveal(_:)), f.path)
        }
        return m
    }

    /// The selected lines, or the line at the caret.
    private var selectedReference: (path: String, lines: ClosedRange<Int>, old: Bool, code: [String], file: Int, line: Int)? {
        guard let sel = reader.selection, reader.files.indices.contains(sel.file), let last = sel.lines.last else { return nil }
        let f = reader.files[sel.file]
        guard let r = f.text.reference(sel.lines, old: reader.selectionIsOld) else { return nil }
        return (f.file.path, r.lines, r.old, r.code, sel.file, last)
    }

    @objc func copyReference(_ sender: Any?) {
        guard let r = selectedReference else { beep(); return }
        copy(lineReference(path: r.path, lines: r.lines, old: r.old))
    }

    @objc func copyReferenceWithCode(_ sender: Any?) {
        guard let r = selectedReference else { beep(); return }
        let lang = SyntaxRuntime.shared?.language(forPath: r.path)?.name ?? ""
        copy("`\(lineReference(path: r.path, lines: r.lines, old: r.old))`\n```\(lang)\n\(r.code.joined(separator: "\n"))\n```\n")
    }

    /// The name of the symbol at the caret, or of the definition around the selected lines.
    private var symbolAtCaret: String? {
        if let w = reader.wordAtCaret, w.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "$" }) {
            return w
        }
        guard let r = selectedReference, !r.old else { return nil }
        return reader.header.enclosing(line: r.lines.lowerBound - 1)?.name
    }

    /// Copies the name of the symbol at the caret, or of the definition around it.
    @objc func copySymbol(_ sender: Any?) {
        guard let s = symbolAtCaret else { beep(); return }
        copy(s)
    }

    /// Copies the symbol at the caret with where it is, as `` `name` (path:line) ``.
    @objc func copySymbolWithReference(_ sender: Any?) {
        guard let s = symbolAtCaret, let r = selectedReference else { beep(); return }
        copy("`\(s)` (\(lineReference(path: r.path, lines: r.lines, old: r.old)))")
    }

    @objc func addNote(_ sender: Any?) {
        guard let save = noteOnSelection(), let r = selectedReference, let (rect, view) = reader.rect(file: r.file, line: r.line) else { beep(); return }
        let editor = NoteEditor(place: .lines(path: r.path, range: r.lines, old: r.old), text: "", canDelete: false, onSave: save)
        editor.show(relativeTo: rect, of: view)
    }

    /// Returns what adds a note with the given text on the lines selected now, or nil when no
    /// lines are selected.
    func noteOnSelection() -> ((String) -> Void)? {
        guard let subject = review?.subject, let r = selectedReference else { return nil }
        return { [weak self] text in
            self?.notes.add(Note(subject: subject.key, lines: Note.Lines(path: r.path, range: r.lines, old: r.old, code: r.code), text: text))
        }
    }

    /// Writes a note on the whole review, which heads the notes when they're copied.
    @objc func addReviewNote(_ sender: Any?) {
        guard let subject = review?.subject else { beep(); return }
        setShown(.inspector, true, animated: false)
        let pane = inspector.notes.view
        let editor = NoteEditor(place: .review(subjectLabel.title), text: "", canDelete: false) { [weak self] text in
            self?.notes.add(Note(subject: subject.key, lines: nil, text: text))
        }
        editor.show(relativeTo: NSRect(x: 0, y: pane.bounds.maxY - 28, width: pane.bounds.width, height: 28), of: pane, edge: .minX)
    }

    /// Opens the editor for a note, beside the note in the reader or wherever `anchor` says.
    func editNote(_ id: UUID, relativeTo anchor: (NSRect, NSView)? = nil) {
        guard let note = notes.notes.first(where: { $0.id == id }), let (rect, view) = anchor ?? reader.rect(ofNote: id) else { return }
        let editor = NoteEditor(place: note.lines.map { .lines(path: $0.path, range: $0.range, old: $0.old) } ?? .review(subjectLabel.title), text: note.text, canDelete: true, onSave: { [weak self] text in
            var n = note
            n.text = text
            self?.notes.update(n)
        }, onDelete: { [weak self] in self?.notes.remove([id]) })
        editor.show(relativeTo: rect, of: view, edge: anchor == nil ? .maxY : .minX)
    }

    @objc func copyAllNotes(_ sender: Any?) { notesPaneCopy(nil) }

    /// Moves to the next change in the file, stopping at its end.
    @objc func nextChange(_ sender: Any?) {
        if !reader.nextChange(1) { beep() }
    }

    @objc func previousChange(_ sender: Any?) {
        if !reader.nextChange(-1) { beep() }
    }

    /// Marks the run of changes at the caret read, then moves to the next unread one in the file,
    /// or marks it unread if it was read.
    ///
    /// Reading the last unread run marks the file reviewed.
    @objc func toggleChangeRead(_ sender: Any?) {
        guard let (f, text, run) = reader.caretRun, let review else { beep(); return }
        let reviews = repository.reviews
        let read = !reviews.isRead(run.key, in: f.diff.change)
        reviews.setRead(run.key, in: f.diff.change, all: text.keyedRuns.map(\.key), to: read, in: review)
        guard read, let fi = reader.files.firstIndex(where: { $0.text === text }) else { return }
        let unread = text.keyedRuns.filter { !reviews.isRead($0.key, in: f.diff.change) }
        if let next = unread.first(where: { $0.run.lines.lowerBound > run.run.lines.lowerBound }) ?? unread.first {
            reader.land(onLine: next.run.lines.lowerBound, file: fi)
        }
    }

    /// Shows the definition of the name at the caret in a popover, without leaving the file.
    @objc func peekDefinition(_ sender: Any?) {
        guard let t = target, let word = reader.wordAtCaret, let anchor = reader.caretAnchor else { beep(); return }
        let from = reader.selection.map { reader.files[$0.file].file.path }
        definitionTask?.cancel()
        busy += 1
        definitionTask = Task {
            defer { busy -= 1 }
            guard let (_, definitions) = try? await lookUp(word, in: t), !Task.isCancelled else { return }
            let defs = nearest(definitions, to: from)
            let git = self.git
            let peek = Peek(word: word, definitions: defs, snapshot: t.snapshot, git: git, analysis: repository.analysis, style: reader.activeCode.style)
            peek.onOpen = { [weak self] d in self?.openBeside(d.path, line: d.line) }
            peek.onKey = { [weak self] event in self?.reader.activeCode.keyDown(with: event) }
            peek.show(relativeTo: anchor.0, of: anchor.1)
        }
    }

    @objc func jumpToText(_ sender: Any?) {
        guard !reader.files.isEmpty else { beep(); return }
        reader.startJump()
    }

    @objc func highlightUses(_ sender: Any?) { if !reader.highlightUses() { beep() } }
    @objc func nextUse(_ sender: Any?) { if !reader.stepUse(1) { beep() } }
    @objc func previousUse(_ sender: Any?) { if !reader.stepUse(-1) { beep() } }

    @objc func showNearbyUnchanged(_ sender: Any?) { if !reader.unfoldNearest() { beep() } }

    @objc func nextFile(_ sender: Any?) {
        if case .overview? = focus { if !reader.nextFile(1) { beep() }; return }
        stepFile(1, anchor: .firstChange)
    }

    @objc func previousFile(_ sender: Any?) {
        if case .overview? = focus { if !reader.nextFile(-1) { beep() }; return }
        stepFile(-1, anchor: .firstChange)
    }

    private func stepFile(_ dir: Int, anchor: Anchor) {
        guard case .file(let p)? = focus else { beep(); return }
        let cur = changes.firstIndex { $0.path == p }
        let next: Int? = if let cur { cur + dir } else { dir > 0 ? 0 : changes.count - 1 }
        guard let next, changes.indices.contains(next) else { beep(); return }
        open(changes[next].path, at: anchor)
    }

    @objc func nextDefinition(_ sender: Any?) { if !reader.stepDefinition(1, changedOnly: inspector.changedOnly) { beep() } }
    @objc func previousDefinition(_ sender: Any?) { if !reader.stepDefinition(-1, changedOnly: inspector.changedOnly) { beep() } }

    @objc func olderCommit(_ sender: Any?) { if !navigator.changes.stepCommit(1) { beep() } }
    @objc func newerCommit(_ sender: Any?) { if !navigator.changes.stepCommit(-1) { beep() } }
    @objc func showWholeReview(_ sender: Any?) { navigatorSelectScope(.everything) }
    @objc func showUncommitted(_ sender: Any?) { navigatorSelectScope(.uncommitted) }

    @objc func showAllChanges(_ sender: Any?) { showOverview() }

    /// The changed files a command acts on: those selected in the file tree while it has focus,
    /// else the one being read.
    private var actionPaths: [String] {
        if window?.firstResponder === navigator.changes.outline {
            let selected = navigator.changes.selectedPaths
            if !selected.isEmpty { return selected }
        }
        return currentChange.map { [changes[$0].path] } ?? []
    }

    @objc func toggleReviewedAction(_ sender: Any?) {
        let paths = actionPaths
        guard !paths.isEmpty else { beep(); return }
        toggleReviewed(paths, advance: window?.firstResponder !== navigator.changes.outline)
    }

    @objc func markAllReviewed(_ sender: Any?) {
        guard !changes.isEmpty, let review else { return }
        repository.reviews.set(changes, reviewed: true, in: review)
    }

    @objc func markAllNotReviewed(_ sender: Any?) {
        guard !changes.isEmpty, let review else { return }
        repository.reviews.set(changes, reviewed: false, in: review)
    }

    @objc func nextUnreviewed(_ sender: Any?) {
        let cur = currentChange ?? -1
        guard let next = changes.indices.first(where: { $0 > cur && !changes[$0].reviewed }) ?? changes.indices.first(where: { !changes[$0].reviewed }) else {
            beep()
            return
        }
        if case .overview? = focus { reader.scrollToFile(next) } else { open(changes[next].path) }
    }

    @objc func toggleShowAll(_ sender: Any?) {
        reader.showAll.toggle()
        reader.reload(keepPosition: true)
    }

    @objc func toggleWrap(_ sender: Any?) {
        reader.wraps.toggle()
        UserDefaults.standard.set(reader.wraps, forKey: "wrapLines")
        reader.reload(keepPosition: true)
    }

    @objc func toggleUnchangedFiles(_ sender: Any?) { navigator.changes.showsUnchanged.toggle() }

    func setSplit(_ on: Bool) {
        reader.split = on
        reader.reload(keepPosition: true)
        UserDefaults.standard.set(on ? "split" : "unified", forKey: "diffMode")
        reader.header.setPane(split: on, beside: panes.count > 1, zoomed: strip.isZoomed)
    }

    @objc func showUnified(_ sender: Any?) { setSplit(false) }
    @objc func showSideBySide(_ sender: Any?) { setSplit(true) }
    @objc func refreshAction(_ sender: Any?) { refresh() }

    @objc func showChangesTab(_ sender: Any?) { revealNavigator(.changes, focus: true) }
    @objc func showFindTab(_ sender: Any?) { revealNavigator(.find, focus: true) }

    /// Puts the keyboard in the file tree's filter.
    private func focusFileFilter() {
        revealNavigator(.changes)
        window?.makeFirstResponder(navigator.changes.filter)
        navigator.changes.filter.selectText(nil)
    }

    @objc func findInRepository(_ sender: Any?) {
        let selected = reader.isFocused ? reader.selectedText : nil
        revealNavigator(.find, focus: true)
        if let s = selected, !s.contains("\n"), s.count < 200 {
            navigator.search.field.stringValue = s
            navigator.search.run()
        }
        navigator.search.field.selectText(nil)
    }

    @objc func jumpToDefinitionAction(_ sender: Any?) {
        guard let w = reader.wordAtCaret else { beep(); return }
        jumpToDefinition(w, from: reader.selection.map { reader.files[$0.file].file.path })
    }

    @objc func findReferencesAction(_ sender: Any?) {
        guard let w = reader.wordAtCaret else { beep(); return }
        findReferences(w)
    }

    @objc func showSymbols(_ sender: Any?) { reader.header.showSymbolMenu() }

    @objc func focusNavigator(_ sender: Any?) {
        setShown(.navigator, true, animated: false)
        window?.makeFirstResponder(navigator.focusView)
    }

    @objc func focusReader(_ sender: Any?) { reader.focus() }

    @objc func focusInspector(_ sender: Any?) {
        setShown(.inspector, true, animated: false)
        window?.makeFirstResponder(inspector.outline)
    }

    @objc func focusFilter(_ sender: Any?) {
        if navigator.tab == .find {
            revealNavigator(.find)
            window?.makeFirstResponder(navigator.search.field)
        } else {
            focusFileFilter()
        }
    }

    @objc func openCurrentInEditor(_ sender: Any?) {
        guard let path = focusedFile?.file.path ?? actionPaths.first else { beep(); return }
        let line = selectedReference.map { $0.old ? 0 : $0.lines.lowerBound } ?? 0
        openInEditor(path: path, line: line)
    }

    @objc func copyCurrentPath(_ sender: Any?) {
        let paths = focusedFile.map { [$0.file.path] } ?? actionPaths
        guard !paths.isEmpty else { beep(); return }
        copy(paths.joined(separator: "\n"))
    }

    @objc func goToLine(_ sender: Any?) {
        guard let window, sheet == nil, let f = focusedFile?.text, !f.lines.isEmpty else { beep(); return }
        let old = f.positions.lastNew == 0
        let last = max(1, old ? f.positions.lastOld : f.positions.lastNew)
        let s = RevisionSheet(title: "Go to Line", placeholder: "1–\(last)", suggestions: [], initial: "") { [weak self] text in
            guard let self, let n = Int(text.trimmingCharacters(in: .whitespaces)), n >= 1 else { return "Enter a line number" }
            self.open(f.path, at: .line(SideLine(number: min(n, last), old: old)))
            return nil
        }
        sheet = s
        s.present(on: window) { [weak self] _ in self?.sheet = nil }
    }

    override func performTextFinderAction(_ sender: Any?) {
        reader.performFind(sender)
    }

    @objc func biggerFont(_ sender: Any?) { Appearance.shared.adjustFontSize(1) }
    @objc func smallerFont(_ sender: Any?) { Appearance.shared.adjustFontSize(-1) }
    @objc func actualSizeFont(_ sender: Any?) { Appearance.shared.resetFontSize() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.keyEquivalentModifierMask.subtracting(.shift).isEmpty, !item.keyEquivalent.isEmpty,
           let text = window?.firstResponder as? NSTextView, text.isEditable {
            return false
        }
        let reading = focusedFile != nil
        let commitRows = navigator.changes.scopeRows.contains { if case .commit = $0 { true } else { false } }
        switch item.action {
        case #selector(showUnified(_:)): item.state = reader.split ? .off : .on
        case #selector(showSideBySide(_:)): item.state = reader.split ? .on : .off
        case #selector(toggleNavigatorColumn(_:)): item.title = isShown(.navigator) ? "Hide Navigator" : "Show Navigator"
        case #selector(toggleInspectorColumn(_:)): item.title = isShown(.inspector) ? "Hide Inspector" : "Show Inspector"
        case #selector(toggleWrap(_:)): item.state = reader.wraps ? .on : .off
        case #selector(toggleShowAll(_:)): item.state = reader.showAll ? .on : .off
        case #selector(toggleUnchangedFiles(_:)): item.state = navigator.changes.showsUnchanged ? .on : .off
        case #selector(toggleBlame(_:)):
            item.state = blameOn ? .on : .off
            return reading
        case #selector(toggleReviewedAction(_:)):
            let paths = actionPaths
            let files = changes.filter { paths.contains($0.path) }
            item.title = !files.isEmpty && files.allSatisfy(\.reviewed) ? "Mark File as Not Reviewed" : "Mark File as Reviewed"
            return !files.isEmpty
        case #selector(previousPane(_:)): return focusedPane > 0
        case #selector(nextPane(_:)): return focusedPane < panes.count - 1
        case #selector(closeOtherPanes(_:)): return panes.count > 1
        case #selector(toggleZoomPane(_:)):
            item.state = strip.isZoomed ? .on : .off
            return panes.count > 1
        case #selector(goToLine(_:)), #selector(showFileHistory(_:)), #selector(showSymbols(_:)), #selector(nextDefinition(_:)), #selector(previousDefinition(_:)):
            return reading
        case #selector(copyReference(_:)), #selector(copyReferenceWithCode(_:)), #selector(addNote(_:)): return reader.selection != nil
        case #selector(jumpToDefinitionAction(_:)), #selector(findReferencesAction(_:)), #selector(copySymbol(_:)): return reader.wordAtCaret != nil
        case #selector(copySymbolWithReference(_:)): return symbolAtCaret != nil && selectedReference != nil
        case #selector(copyAllNotes(_:)): return !reviewNotes.isEmpty
        case #selector(addReviewNote(_:)): return review != nil
        case #selector(toggleChangeRead(_:)):
            guard let (f, _, run) = reader.caretRun else { return false }
            item.title = repository.reviews.isRead(run.key, in: f.diff.change) ? "Mark Change as Unread" : "Mark Change as Read"
            return true
        case #selector(peekDefinition(_:)): return reader.wordAtCaret != nil
        case #selector(jumpToText(_:)), #selector(showNearbyUnchanged(_:)): return !reader.files.isEmpty
        case #selector(highlightUses(_:)): return reader.wordAtCaret != nil
        case #selector(nextUse(_:)), #selector(previousUse(_:)): return reader.usesWord != nil
        case #selector(olderCommit(_:)), #selector(newerCommit(_:)): return commitRows
        case #selector(showWholeReview(_:)): return review.map { $0.scope != .everything } ?? false
        case #selector(showUncommitted(_:)):
            if case .worktree? = review?.subject { return review?.scope != .uncommitted }
            return false
        case #selector(nextChange(_:)), #selector(previousChange(_:)), #selector(nextFile(_:)), #selector(previousFile(_:)),
             #selector(markAllReviewed(_:)), #selector(markAllNotReviewed(_:)), #selector(nextUnreviewed(_:)), #selector(showAllChanges(_:)):
            return !changes.isEmpty
        case #selector(openCurrentInEditor(_:)), #selector(copyCurrentPath(_:)): return reading || currentChange != nil
        default: break
        }
        return true
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Where the user's tools are: the PATH to launch them on, and the git and GitHub CLI the app
/// runs.
///
/// A GUI app opened from the Dock or with `open` inherits only the system's directories, where
/// `/usr/bin/git` may be a stub for tools that aren't installed. So the login shell's PATH comes
/// first. Reading it runs the shell's startup files, so each is found once, off the main actor,
/// and the app starts reading the PATH at launch. A git the app is told to run never waits for
/// the shell.
enum UserTools {
    static let path = Task.detached(priority: .userInitiated) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let known = ["\(home)/.nix-profile/bin", "/etc/profiles/per-user/\(NSUserName())/bin", "/run/current-system/sw/bin", "/nix/var/nix/profiles/default/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let shell = getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) }
        return searchPath(shell: shell.flatMap { readLoginShellPath(shell: $0) }, known: known, inherited: ProcessInfo.processInfo.environment["PATH"])
    }

    static let git = Task.detached(priority: .userInitiated) {
        let told = [ProcessInfo.processInfo.environment["SEXTANT_GIT"], Bundle.main.object(forInfoDictionaryKey: "SextantGitPath") as? String]
        if let git = told.compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return git }
        return executable(named: "git", in: await path.value) ?? "/usr/bin/git"
    }

    static let gh = Task.detached(priority: .utility) { executable(named: "gh", in: await path.value) }
}
