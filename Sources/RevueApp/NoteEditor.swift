import AppKit

/// The popover for writing or editing a note.
///
/// ⌘Return saves, and Esc cancels.
@MainActor
final class NoteEditor: NSViewController, NSTextViewDelegate {
    /// What a note is on, as the editor names it.
    struct Place {
        /// The file and line, such as "Reader.swift, line 12", or "Whole review".
        var title: String
        /// Where the file is, or what the review is of.
        var detail: String
        /// What the empty editor asks for.
        var prompt: String

        /// Names some lines of a file.
        static func lines(path: String, range: ClosedRange<Int>, old: Bool) -> Place {
            let name = (path as NSString).lastPathComponent
            let lines = range.count == 1 ? "line \(range.lowerBound)" : "lines \(range.lowerBound)–\(range.upperBound)"
            let folder = (path as NSString).deletingLastPathComponent
            return Place(title: "\(name), \(lines)" + (old ? " (removed)" : ""), detail: folder.isEmpty ? "Repository root" : folder,
                         prompt: range.count == 1 ? "Write a note on this line" : "Write a note on these lines")
        }

        /// Names a whole review.
        static func review(_ subject: String) -> Place { Place(title: "Whole review", detail: subject, prompt: "Write a note on the whole review") }
    }

    private let text = NSTextView()
    private let placeholder = NSTextField(labelWithString: "")
    private let place: Place
    private let initial: String
    private let canDelete: Bool
    private let onSave: (String) -> Void
    private let onDelete: () -> Void
    weak var popover: NSPopover?

    init(place: Place, text: String, canDelete: Bool, onSave: @escaping (String) -> Void, onDelete: @escaping () -> Void = {}) {
        self.place = place
        initial = text
        self.canDelete = canDelete
        self.onSave = onSave
        self.onDelete = onDelete
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView()
        let title = NSTextField(labelWithString: place.title)
        title.font = .preferredFont(forTextStyle: .headline)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSTextField(labelWithString: place.detail)
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingHead
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        text.string = initial
        text.font = .preferredFont(forTextStyle: .body)
        text.textColor = .labelColor
        text.drawsBackground = false
        text.isRichText = false
        text.allowsUndo = true
        text.delegate = self
        text.textContainerInset = NSSize(width: 6, height: 8)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel("Note")
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let box = NoteTextBox()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scroll)
        placeholder.stringValue = place.prompt
        placeholder.font = text.font
        placeholder.textColor = .placeholderTextColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.isHidden = !initial.isEmpty
        box.addSubview(placeholder)

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = .command
        save.bezelColor = .controlAccentColor
        save.toolTip = "Save (⌘Return)"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        var buttons: [NSView] = []
        if canDelete {
            let delete = NSButton(title: "Delete", target: self, action: #selector(deleteNote))
            delete.hasDestructiveAction = true
            buttons.append(delete)
        }
        buttons += [NSView(), cancel, save]
        let row = NSStackView(views: buttons)
        row.spacing = 12
        for b in [save, cancel] { b.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true }

        let heading = NSStackView(views: [title, detail])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 2
        for x in [heading, box, row] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: v.topAnchor, constant: 16),
            heading.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -20),
            title.widthAnchor.constraint(lessThanOrEqualTo: heading.widthAnchor),
            detail.widthAnchor.constraint(lessThanOrEqualTo: heading.widthAnchor),
            box.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            box.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            box.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -20),
            box.heightAnchor.constraint(equalToConstant: 120),
            box.widthAnchor.constraint(equalToConstant: 380),
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
            placeholder.topAnchor.constraint(equalTo: box.topAnchor, constant: 9),
            placeholder.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 7 + (text.textContainer?.lineFragmentPadding ?? 5)),
            row.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 16),
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -16),
        ])
        view = v
    }

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !text.string.isEmpty
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

    /// Shows the editor next to a rect in a view, on the given side of it.
    func show(relativeTo rect: NSRect, of view: NSView, edge: NSRectEdge = .maxY) {
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = self
        popover = p
        p.show(relativeTo: rect, of: view, preferredEdge: edge)
    }
}

/// The rounded, field-like well a note is written in.
final class NoteTextBox: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.06) : NSColor.textBackgroundColor).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
