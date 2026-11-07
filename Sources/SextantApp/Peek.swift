import AppKit
import SextantCore

/// A popover showing a name's definition beside the code that uses it, so a question about the
/// code can be answered without leaving it.
///
/// Tab and Shift-Tab go through the definitions when there are several, Return or `p` opens the
/// one shown, Esc closes, and any other key closes the popover and goes to the reader.
@MainActor
final class Peek: NSViewController {
    private let word: String
    private let definitions: [GrepMatch]
    private let snapshot: Snapshot
    private let git: Git
    private let analysis: ContentAnalysis
    private let style: Style
    private var index = 0
    private let header = NSTextField(labelWithString: "")
    private let text = NSTextView()
    private weak var popover: NSPopover?
    var onOpen: ((GrepMatch) -> Void)?
    var onKey: ((NSEvent) -> Void)?

    init(word: String, definitions: [GrepMatch], snapshot: Snapshot, git: Git, analysis: ContentAnalysis, style: Style) {
        self.word = word
        self.definitions = definitions
        self.snapshot = snapshot
        self.git = git
        self.analysis = analysis
        self.style = style
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = PeekView()
        v.peek = self
        header.font = .systemFont(ofSize: 11, weight: .medium)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingHead
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.isEditable = false
        text.isSelectable = false
        text.drawsBackground = true
        text.backgroundColor = style.theme.canvas
        text.textContainerInset = NSSize(width: 8, height: 6)
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.isHorizontallyResizable = true
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        for x in [header, scroll] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 620),
            scroll.heightAnchor.constraint(equalToConstant: definitions.isEmpty ? 0 : style.lineHeight * 16 + 12),
        ])
        view = v
        show(0)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(view)
    }

    /// Shows the popover next to a rect in a view.
    func show(relativeTo rect: NSRect, of view: NSView) {
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = self
        popover = p
        p.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    private func show(_ i: Int) {
        guard !definitions.isEmpty else {
            header.stringValue = "No definition of ‘\(word)’ found"
            return
        }
        index = (i + definitions.count) % definitions.count
        let d = definitions[index]
        header.stringValue = "\(d.path):\(d.line)" + (definitions.count > 1 ? "   \(index + 1) of \(definitions.count) · Tab for the next" : "")
        let snapshot = self.snapshot, git = self.git, analysis = self.analysis, style = self.style
        Task {
            guard let data = await git.contents(of: d.path, in: snapshot) else { return }
            let (all, tokens) = await Peek.read(data, path: d.path, analysis: analysis)
            let start = min(max(0, d.line - 4), all.count)
            let shown = start..<min(all.count, start + 40)
            guard index < definitions.count, definitions[index] == d else { return }
            text.textStorage?.setAttributedString(Peek.render(Array(all[shown]), tokens: tokens.map { Array($0[shown]) }, focus: d.line - 1 - start, style: style))
            text.scrollToBeginningOfDocument(nil)
        }
    }

    /// Returns the lines of a whole file, and the tokens of each when its admission lets it be
    /// analyzed, so code under a long comment is coloured as the comment leaves it.
    @concurrent nonisolated private static func read(_ data: Data, path: String, analysis: ContentAnalysis) async -> (lines: [String], tokens: [[Token]]?) {
        let oid = blobID(of: data)
        let lines = AdmittedLines(data).lines
        guard Admissions.shared.measure(data, oid: oid).analyzes, let language = SyntaxRuntime.shared?.language(forPath: path) else { return (lines, nil) }
        return (lines, await analysis.analysis(of: lines, oid: oid, language: language, definitions: false).tokens)
    }

    private static func render(_ lines: [String], tokens: [[Token]]?, focus: Int, style: Style) -> NSAttributedString {
        let t = style.theme
        let out = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            let s = NSMutableAttributedString(string: line + "\n", attributes: [.font: style.font, .foregroundColor: t.fg, .paragraphStyle: style.paragraph()])
            for tok in tokens?[i] ?? [] where NSMaxRange(tok.range) <= (line as NSString).length {
                s.addAttribute(.foregroundColor, value: t.syntax(tok.kind), range: tok.range)
            }
            if i == focus { s.addAttribute(.backgroundColor, value: t.color("attention").withAlphaComponent(0.18), range: NSRange(location: 0, length: s.length)) }
            out.append(s)
        }
        return out
    }

    fileprivate func handle(_ event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 48: show(index + (shift ? -1 : 1))
        case 53: popover?.close()
        case 36, 76: open()
        default:
            if event.charactersIgnoringModifiers == "p", event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty { open(); return }
            popover?.close()
            onKey?(event)
        }
    }

    private func open() {
        popover?.close()
        if definitions.indices.contains(index) { onOpen?(definitions[index]) }
    }
}

private final class PeekView: NSView {
    weak var peek: Peek?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { peek?.handle(event) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        peek?.handle(event)
        return true
    }
}
