import AppKit
import RevueCore

/// A one-field sheet, such as Go to Revision or Go to Line.
///
/// The sheet offers suggestions and shows errors inline. Return goes, and Esc cancels.
@MainActor
final class RevisionSheet: NSWindowController, NSComboBoxDelegate, NSWindowDelegate {
    let field = NSComboBox()
    let error = NSTextField(labelWithString: "")
    let go = NSButton(title: "Go", target: nil, action: nil)
    let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let resolve: (String) async -> String?
    private var completion: ((String?) -> Void)?

    /// Creates a sheet that hands what the user enters to `resolve`.
    ///
    /// - Parameter resolve: Returns an error message, or nil if the entry was accepted.
    init(title titleText: String = "Go to Revision", placeholder: String = "HEAD~3, v1.0..v1.1, main...feature, staged", suggestions: [String], initial: String, resolve: @escaping (String) async -> String?) {
        self.resolve = resolve
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 140), styleMask: [.titled], backing: .buffered, defer: true)
        super.init(window: panel)

        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        field.placeholderString = placeholder
        field.addItems(withObjectValues: suggestions)
        field.numberOfVisibleItems = 12
        field.completes = true
        field.stringValue = initial
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        error.textColor = .systemRed
        error.font = .systemFont(ofSize: 11)
        error.lineBreakMode = .byTruncatingTail
        go.keyEquivalent = "\r"
        go.target = self
        go.action = #selector(submit)
        cancel.keyEquivalent = "\u{1b}"
        cancel.target = self
        cancel.action = #selector(dismiss)

        let buttons = NSStackView(views: [error, NSView(), cancel, go])
        buttons.spacing = 8
        let stack = NSStackView(views: [title, field, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: field.widthAnchor),
            go.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
        ])
        panel.initialFirstResponder = field
        panel.contentView!.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: 420, height: stack.fittingSize.height))
    }

    required init?(coder: NSCoder) { fatalError() }

    func present(on parent: NSWindow, completion: @escaping (String?) -> Void) {
        self.completion = completion
        parent.beginSheet(window!)
        window?.makeFirstResponder(field)
    }

    @objc func submit() {
        let spec = field.stringValue.trimmingCharacters(in: .whitespaces)
        go.isEnabled = false
        Task {
            let err = await resolve(spec)
            go.isEnabled = true
            if let err {
                error.stringValue = err
                window?.makeFirstResponder(field)
            } else {
                finish(spec)
            }
        }
    }

    @objc func dismiss() { finish(nil) }

    private func finish(_ value: String?) {
        guard let w = window, let parent = w.sheetParent else { return }
        parent.endSheet(w)
        completion?(value)
        completion = nil
    }

    func controlTextDidChange(_ obj: Notification) { error.stringValue = "" }
}
