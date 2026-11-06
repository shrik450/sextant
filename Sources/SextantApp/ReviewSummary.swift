import AppKit
import SextantCore

/// What a window says about the review its focused pane shows, wherever its look shows it.
struct ReviewSummary {
    var repository: String
    /// What's reviewed, with the symbol for its kind and a longer description.
    var subject: (title: String, symbol: String, tooltip: String)
    /// The part of the review being read and how many files it has, or empty with no review.
    var scope: String
    /// The base the review is compared with, for subjects that have one.
    var base: BaseChoices?
    var reviewed: Int
    var total: Int
}

/// The base a review is compared with, and the branches it can change to.
struct BaseChoices {
    var current: String
    /// The base the subject gets unless the user picks another, if there is one.
    var usual: String?
    var local: [String]
    var remote: [String]

    /// Lists the choices in a pop-up button, with the current base selected and each branch's
    /// item carrying its name.
    @MainActor
    func fill(_ button: NSPopUpButton) {
        let menu = NSMenu()
        func header(_ t: String) {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(withTitle: t, action: nil, keyEquivalent: "").isEnabled = false
        }
        func items(_ names: [String]) {
            for n in names {
                let item = menu.addItem(withTitle: n, action: nil, keyEquivalent: "")
                item.representedObject = n
            }
        }
        let usual = usual.map { [$0] } ?? []
        let all = Set(usual + local + remote)
        items(usual + (all.contains(current) ? [] : [current]))
        if !local.isEmpty { header("Local Branches"); items(local) }
        if !remote.isEmpty { header("Remote Branches"); items(remote) }
        button.menu = menu
        button.select(menu.items.first { ($0.representedObject as? String) == current })
    }
}

extension RepoWindowController {
    /// The base a subject gets unless the user picks another.
    private var usualBase: String? {
        if let p = resolved?.pullRequest { return "origin/" + p.baseRefName }
        return repository.defaultBase
    }

    /// What the window says about the focused pane's review.
    var reviewSummary: ReviewSummary {
        let label = subjectLabel
        var base: BaseChoices?
        if let r = review, r.subject.hasBase {
            var own: String?
            if case .branch(let b) = r.subject { own = b }
            if case .worktree(let root) = r.subject { own = repository.worktree(at: root)?.branch }
            let names = repository.branches.filter { $0.name != own }
            base = BaseChoices(current: r.base ?? usualBase ?? "", usual: usualBase,
                               local: names.filter { !$0.isRemote }.map(\.name), remote: names.filter(\.isRemote).map(\.name))
        }
        return ReviewSummary(
            repository: repository.name,
            subject: (label.title, label.symbol, label.tooltip + "  (⇧⌘R)"),
            scope: review == nil ? "" : scopeLabel + (changes.isEmpty ? "" : "  ·  \(changes.count) file\(changes.count == 1 ? "" : "s")"),
            base: base,
            reviewed: changes.count(where: \.reviewed),
            total: changes.count)
    }

    /// Compares the review with the base chosen in the sender, a pop-up button of base choices.
    @objc func baseChosen(_ sender: Any?) {
        guard let base = (sender as? NSPopUpButton)?.selectedItem?.representedObject as? String, var r = review, r.base != base else { return }
        repository.remember(base: base, for: r.subject, usual: usualBase)
        r.base = base
        r.scope = .everything
        select(r)
    }

    @objc func chooseSubject(_ sender: Any?) { showPicker(sender) }

    /// Shows the picker under the review's subject, or over the code when the subject is out of
    /// view, or closes it if it's showing.
    func showPicker(_ sender: Any?) {
        if let p = picker, p.isShown { p.close(); return }
        let vc = SubjectPicker(repository: repository, current: review, here: home) { [weak self] r in
            self?.picker?.close()
            self?.select(r)
        }
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = vc
        picker = p
        if let anchor = frame.subjectAnchor {
            p.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else {
            let v = reader.view
            p.show(relativeTo: NSRect(x: v.bounds.midX, y: v.bounds.maxY - 40, width: 1, height: 1), of: v, preferredEdge: .minY)
        }
    }
}
