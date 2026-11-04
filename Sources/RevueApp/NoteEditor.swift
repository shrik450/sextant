import AppKit

/// The popover for writing or editing a note.
///
/// ⌘Return saves, and Esc cancels.
@MainActor
final class NoteEditor: NSViewController, NSTextViewDelegate {
    private let text = NSTextView()
    private let reference: String
    private let initial: String
    private let canDelete: Bool
    private let onSave: (String) -> Void
    private let onDelete: () -> Void
    weak var popover: NSPopover?

    init(reference: String, text: String, canDelete: Bool, onSave: @escaping (String) -> Void, onDelete: @escaping () -> Void = {}) {
        self.reference = reference
        initial = text
        self.canDelete = canDelete
        self.onSave = onSave
        self.onDelete = onDelete
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView()
        let label = NSTextField(labelWithString: reference)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingHead
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.string = initial
        text.font = .systemFont(ofSize: 13)
        text.isRichText = false
        text.allowsUndo = true
        text.delegate = self
        text.textContainerInset = NSSize(width: 4, height: 6)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = .command
        save.toolTip = "⌘Return"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        var buttons: [NSView] = []
        if canDelete {
            let delete = NSButton(title: "Delete", target: self, action: #selector(deleteNote))
            buttons.append(delete)
        }
        buttons += [NSView(), cancel, save]
        let row = NSStackView(views: buttons)
        row.spacing = 8
        for x in [label, scroll, row] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: v.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            scroll.heightAnchor.constraint(equalToConstant: 110),
            scroll.widthAnchor.constraint(equalToConstant: 380),
            row.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -12),
        ])
        view = v
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(text)
        text.selectAll(nil)
    }

    @objc private func save() {
        let s = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { onSave(s) } else if canDelete { onDelete() }
        popover?.close()
    }

    @objc private func cancel() { popover?.close() }

    @objc private func deleteNote() {
        onDelete()
        popover?.close()
    }

    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        return false
    }

    /// Shows the editor next to a rect in a view.
    func show(relativeTo rect: NSRect, of view: NSView) {
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = self
        popover = p
        p.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }
}
