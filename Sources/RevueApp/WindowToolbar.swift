import AppKit
import RevueCore

/// The toolbar's subject control: what's being reviewed, which opens the picker, and the base it's
/// compared with.
@MainActor
final class SubjectControl: NSStackView {
    let subject = NSButton(title: "", target: nil, action: nil)
    let versus = NSTextField(labelWithString: "vs")
    let base = NSPopUpButton(frame: .zero, pullsDown: false)

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        subject.bezelStyle = .toolbar
        subject.imagePosition = .imageLeading
        subject.imageHugsTitle = true
        subject.lineBreakMode = .byTruncatingMiddle
        subject.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subject.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        subject.setAccessibilityLabel("Choose what to review")
        versus.textColor = .secondaryLabelColor
        versus.font = .systemFont(ofSize: 12)
        base.bezelStyle = .toolbar
        base.lineBreakMode = .byTruncatingMiddle
        base.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        base.setContentHuggingPriority(.required, for: .horizontal)
        base.toolTip = "The branch this is compared with"
        base.setAccessibilityLabel("Compare with")
        for v in [subject, versus, base] { addArrangedSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSubject(title: String, symbol: String, tooltip: String) {
        subject.title = title
        subject.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        subject.toolTip = tooltip
    }

    /// Shows the base and the branches it can change to, or hides it for subjects without one.
    func setBase(_ current: String?, usual: [String], local: [String], remote: [String]) {
        let shown = current != nil
        versus.isHidden = !shown
        base.isHidden = !shown
        guard let current else { return }
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
        let all = Set(usual + local + remote)
        items(usual + (all.contains(current) ? [] : [current]))
        if !local.isEmpty { header("Local Branches"); items(local) }
        if !remote.isEmpty { header("Remote Branches"); items(remote) }
        base.menu = menu
        base.select(menu.items.first { ($0.representedObject as? String) == current })
    }

    /// The base the user picked.
    var chosenBase: String? { base.selectedItem?.representedObject as? String }
}

extension RepoWindowController: NSToolbarDelegate {
    static let navID = NSToolbarItem.Identifier("nav")
    static let subjectID = NSToolbarItem.Identifier("subject")
    static let diffModeID = NSToolbarItem.Identifier("diffMode")
    static let reviewID = NSToolbarItem.Identifier("review")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, RepoWindowController.navID, .flexibleSpace, RepoWindowController.subjectID, .flexibleSpace,
         RepoWindowController.diffModeID, RepoWindowController.reviewID, .inspectorTrackingSeparator, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case RepoWindowController.navID:
            let g = NSToolbarItemGroup(itemIdentifier: id,
                                       images: [NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous Pane")!,
                                                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next Pane")!],
                                       selectionMode: .momentary, labels: ["Previous Pane", "Next Pane"], target: self, action: #selector(navClicked(_:)))
            g.subitems[0].toolTip = "Previous Pane (⌘[)"
            g.subitems[1].toolTip = "Next Pane (⌘])"
            g.subitems.forEach { $0.autovalidates = false }
            navGroup = g
            updateNavButtons()
            return g
        case RepoWindowController.subjectID:
            let item = NSToolbarItem(itemIdentifier: id)
            let control = SubjectControl()
            control.subject.target = self
            control.subject.action = #selector(chooseSubject(_:))
            control.base.target = self
            control.base.action = #selector(baseChosen(_:))
            item.view = control
            item.label = "Review"
            item.visibilityPriority = .high
            subjectControl = control
            updateSubjectControl()
            return item
        case RepoWindowController.diffModeID:
            let g = NSToolbarItemGroup(itemIdentifier: id,
                                       images: [NSImage(systemSymbolName: "text.justify.leading", accessibilityDescription: "Unified")!,
                                                NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Side by Side")!],
                                       selectionMode: .selectOne, labels: ["Unified", "Side by Side"], target: self, action: #selector(modeChanged(_:)))
            g.selectedIndex = reader.split ? 1 : 0
            g.subitems[0].toolTip = "Unified (⌃⌘1)"
            g.subitems[1].toolTip = "Side by Side (⌃⌘2)"
            modeGroup = g
            return g
        case RepoWindowController.reviewID:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Reviewed")
            item.label = "Reviewed"
            item.target = self
            item.action = #selector(toggleReviewedAction(_:))
            item.toolTip = "Mark as Reviewed (R)"
            reviewItem = item
            return item
        default:
            return nil
        }
    }

    @objc private func navClicked(_ sender: NSToolbarItemGroup) {
        sender.selectedIndex == 0 ? previousPane(nil) : nextPane(nil)
    }

    @objc private func modeChanged(_ sender: NSToolbarItemGroup) { setSplit(sender.selectedIndex == 1) }

    /// The base a subject gets unless the user picks another.
    private var usualBase: String? {
        if let p = resolved?.pullRequest { return "origin/" + p.baseRefName }
        return repository.defaultBase
    }

    func updateSubjectControl() {
        guard let c = subjectControl else { return }
        let label = subjectLabel
        c.setSubject(title: label.title, symbol: label.symbol, tooltip: label.tooltip + "  (⇧⌘R)")
        guard let r = review, r.subject.hasBase else {
            c.setBase(nil, usual: [], local: [], remote: [])
            return
        }
        var own: String?
        if case .branch(let b) = r.subject { own = b }
        if case .worktree(let root) = r.subject { own = repository.worktree(at: root)?.branch }
        let names = repository.branches.filter { $0.name != own }
        c.setBase(r.base ?? usualBase ?? "", usual: [usualBase].compactMap { $0 },
                  local: names.filter { !$0.isRemote }.map(\.name), remote: names.filter(\.isRemote).map(\.name))
    }

    @objc func baseChosen(_ sender: Any?) {
        guard let base = subjectControl?.chosenBase, var r = review, r.base != base else { return }
        repository.remember(base: base, for: r.subject, usual: usualBase)
        r.base = base
        r.scope = .everything
        select(r)
    }

    @objc func chooseSubject(_ sender: Any?) { showPicker(sender) }

    /// Shows the picker under the subject control, or closes it if it's showing.
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
        if let button = subjectControl?.subject, button.window != nil, window?.toolbar?.isVisible == true {
            p.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        } else {
            let v = reader.view
            p.show(relativeTo: NSRect(x: v.bounds.midX, y: v.bounds.maxY - 40, width: 1, height: 1), of: v, preferredEdge: .minY)
        }
    }
}
