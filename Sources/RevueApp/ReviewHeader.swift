import AppKit
import RevueCore

/// The top of the navigator, which says what the window reviews: the repository, the subject,
/// which opens the picker, the part of it being read, and the base it's compared with.
@MainActor
final class ReviewHeader: NSView {
    let repository = NSTextField(labelWithString: "")
    let subject = NSButton(title: "", target: nil, action: nil)
    let scope = NSTextField(labelWithString: "")
    let base = NSPopUpButton(frame: .zero, pullsDown: false)
    private let chooser = NSImageView(image: NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)!)
    private let baseRow: NSStackView

    override init(frame: NSRect) {
        let versus = NSTextField(labelWithString: "Compared with")
        baseRow = NSStackView(views: [versus, base])
        super.init(frame: frame)
        repository.font = .sectionLabel
        repository.textColor = .themed("fgMuted")
        repository.lineBreakMode = .byTruncatingTail
        subject.isBordered = false
        subject.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        subject.imagePosition = .imageLeading
        subject.imageHugsTitle = true
        subject.alignment = .left
        subject.lineBreakMode = .byTruncatingMiddle
        subject.symbolConfiguration = .init(textStyle: .body, scale: .medium)
        subject.contentTintColor = .themed("fg")
        subject.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subject.setAccessibilityLabel("Choose what to review")
        chooser.symbolConfiguration = .init(textStyle: .body, scale: .small)
        chooser.contentTintColor = .themed("fgMuted")
        chooser.setContentHuggingPriority(.required, for: .horizontal)
        chooser.setContentCompressionResistancePriority(.required, for: .horizontal)
        scope.font = .detail
        scope.textColor = .themed("fgMuted")
        scope.lineBreakMode = .byTruncatingTail
        scope.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        versus.font = .detail
        versus.textColor = .themed("fgMuted")
        versus.setContentHuggingPriority(.required, for: .horizontal)
        base.isBordered = false
        base.font = .detail
        base.lineBreakMode = .byTruncatingMiddle
        base.contentTintColor = .themed("fg")
        base.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        base.toolTip = "The branch this is compared with"
        base.setAccessibilityLabel("Compare with")
        baseRow.orientation = .horizontal
        baseRow.spacing = 2
        let subjectRow = NSStackView(views: [subject, chooser])
        subjectRow.orientation = .horizontal
        subjectRow.spacing = 4
        let column = NSStackView(views: [repository, subjectRow, scope, baseRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.setCustomSpacing(6, after: repository)
        column.setCustomSpacing(4, after: subjectRow)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            subjectRow.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            scope.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            baseRow.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSubject(title: String, symbol: String, tooltip: String) {
        subject.title = title
        subject.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        subject.toolTip = tooltip
    }

    /// Shows the base and the branches it can change to, or hides it for subjects without one.
    func setBase(_ current: String?, usual: [String], local: [String], remote: [String]) {
        baseRow.isHidden = current == nil
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

    /// Whether the base shows, which it does for subjects compared with a branch.
    var showsBase: Bool { !baseRow.isHidden }

    /// The base the user picked.
    var chosenBase: String? { base.selectedItem?.representedObject as? String }
}

extension RepoWindowController {
    var reviewHeader: ReviewHeader { navigator.reviewHeader }

    /// Connects the review header's controls to the window.
    func connectReviewHeader() {
        reviewHeader.subject.target = self
        reviewHeader.subject.action = #selector(chooseSubject(_:))
        reviewHeader.base.target = self
        reviewHeader.base.action = #selector(baseChosen(_:))
    }

    /// The base a subject gets unless the user picks another.
    private var usualBase: String? {
        if let p = resolved?.pullRequest { return "origin/" + p.baseRefName }
        return repository.defaultBase
    }

    /// Shows the repository, the focused pane's review and the part of it being read.
    func updateReviewHeader() {
        let h = reviewHeader
        h.repository.stringValue = repository.name
        h.scope.stringValue = review == nil ? "" : scopeLabel + (changes.isEmpty ? "" : "  ·  \(changes.count) file\(changes.count == 1 ? "" : "s")")
        h.scope.isHidden = h.scope.stringValue.isEmpty
        let label = subjectLabel
        h.setSubject(title: label.title, symbol: label.symbol, tooltip: label.tooltip + "  (⇧⌘R)")
        guard let r = review, r.subject.hasBase else {
            h.setBase(nil, usual: [], local: [], remote: [])
            return
        }
        var own: String?
        if case .branch(let b) = r.subject { own = b }
        if case .worktree(let root) = r.subject { own = repository.worktree(at: root)?.branch }
        let names = repository.branches.filter { $0.name != own }
        h.setBase(r.base ?? usualBase ?? "", usual: [usualBase].compactMap { $0 },
                  local: names.filter { !$0.isRemote }.map(\.name), remote: names.filter(\.isRemote).map(\.name))
    }

    @objc func baseChosen(_ sender: Any?) {
        guard let base = reviewHeader.chosenBase, var r = review, r.base != base else { return }
        repository.remember(base: base, for: r.subject, usual: usualBase)
        r.base = base
        r.scope = .everything
        select(r)
    }

    @objc func chooseSubject(_ sender: Any?) { showPicker(sender) }

    /// Shows the picker under the review's subject, or over the code when the navigator is
    /// hidden, or closes it if it's showing.
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
        let button = reviewHeader.subject
        if button.window != nil, !split.splitViewItems[0].isCollapsed {
            p.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        } else {
            let v = reader.view
            p.show(relativeTo: NSRect(x: v.bounds.midX, y: v.bounds.maxY - 40, width: 1, height: 1), of: v, preferredEdge: .minY)
        }
    }
}
