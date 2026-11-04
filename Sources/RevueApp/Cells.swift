import AppKit
import UniformTypeIdentifiers
import RevueCore

/// Returns the arrow key a list treats `j` or `k` as, the way the reader moves its caret with
/// them, or the event itself for any other key.
private func listArrow(for event: NSEvent) -> NSEvent {
    guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
          let key = event.charactersIgnoringModifiers, key == "j" || key == "k" else { return event }
    let arrow = String(Character(UnicodeScalar(key == "j" ? NSDownArrowFunctionKey : NSUpArrowFunctionKey)!))
    return NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow, modifierFlags: [.function, .numericPad], timestamp: event.timestamp,
                            windowNumber: event.windowNumber, context: nil, characters: arrow, charactersIgnoringModifiers: arrow,
                            isARepeat: event.isARepeat, keyCode: key == "j" ? 125 : 126) ?? event
}

/// A table view that reports space, Return and delete presses, steps with `j` and `k`, and lets
/// bare-key menu shortcuts through.
final class KeyTableView: NSTableView {
    var onSpace: (() -> Void)?
    var onDelete: (() -> Void)?
    var onReturn: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        if plain, event.charactersIgnoringModifiers == " ", let onSpace { onSpace(); return }
        if plain, let onDelete, event.keyCode == 51 || event.keyCode == 117 { onDelete(); return }
        if plain, let onReturn, event.keyCode == 36 || event.keyCode == 76 { onReturn(); return }
        super.keyDown(with: listArrow(for: event))
    }
}

/// An outline view that reports space and Return presses, steps with `j` and `k`, and lets
/// bare-key menu shortcuts through.
final class KeyOutlineView: NSOutlineView {
    var onSpace: (() -> Void)?
    var onReturn: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        if plain, event.charactersIgnoringModifiers == " ", let onSpace { onSpace(); return }
        if plain, let onReturn, event.keyCode == 36 || event.keyCode == 76 { onReturn(); return }
        super.keyDown(with: listArrow(for: event))
    }
}

/// A row of the file tree: a change with its review button, a file, a folder, folded files, or
/// All Changes.
@MainActor
final class TreeCell: NSTableCellView {
    enum Content {
        case change(FileState, showsFolder: Bool)
        case file(String, showsFolder: Bool)
        case folder(String, reviewed: Int, changed: Int)
        case folded(Int)
        case allChanges(reviewed: Int, changed: Int)
    }

    static let id = NSUserInterfaceItemIdentifier("TreeCell")
    let glyph = NSButton()
    let name = NSTextField(labelWithString: "")
    let dir = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")
    var onToggle: (() -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = TreeCell.id
        glyph.isBordered = false
        glyph.imagePosition = .imageOnly
        glyph.imageScaling = .scaleProportionallyDown
        glyph.target = self
        glyph.action = #selector(toggle)
        glyph.setButtonType(.momentaryChange)
        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: 13)
        dir.lineBreakMode = .byTruncatingHead
        dir.font = .systemFont(ofSize: 11)
        dir.textColor = .secondaryLabelColor
        badge.alignment = .right
        for v in [glyph, name, dir, badge] as [NSView] { addSubview(v) }
        textField = name
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Lays out the row by hand so the name gets its space first, and the folder only shows when
    /// a meaningful amount of it fits.
    override func layout() {
        super.layout()
        let h = bounds.height
        glyph.frame = NSRect(x: 0, y: (h - 18) / 2, width: 18, height: 18)
        badge.sizeToFit()
        let bw = badge.stringValue.isEmpty ? 0 : max(16, badge.frame.width)
        badge.frame = NSRect(x: bounds.width - 4 - bw, y: (h - badge.frame.height) / 2, width: bw, height: badge.frame.height)
        let x0: CGFloat = 23
        let right = (bw > 0 ? badge.frame.minX : bounds.width) - 6
        name.sizeToFit()
        name.frame = NSRect(x: x0, y: (h - name.frame.height) / 2, width: min(name.frame.width, max(0, right - x0)), height: name.frame.height)
        dir.sizeToFit()
        let dirX = name.frame.maxX + 6
        let dirW = min(dir.frame.width, right - dirX)
        dir.isHidden = dir.stringValue.isEmpty || dirW < min(dir.frame.width, 48)
        dir.frame = NSRect(x: dirX, y: name.frame.minY + name.baselineOffsetFromBottom - dir.baselineOffsetFromBottom, width: max(0, dirW), height: dir.frame.height)
    }

    @objc private func toggle() { onToggle?() }

    private static let symbolSize = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)

    private func symbol(_ name: String, _ colors: [NSColor]) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(TreeCell.symbolSize.applying(.init(paletteColors: colors)))
    }

    private func count(_ reviewed: Int, _ changed: Int) {
        badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        badge.stringValue = changed > 0 ? "\(reviewed)/\(changed)" : ""
        badge.textColor = changed > 0 && reviewed == changed ? .systemGreen : .secondaryLabelColor
        badge.toolTip = changed > 0 ? "\(reviewed) of \(changed) changed files reviewed" : nil
    }

    func configure(_ content: Content) {
        glyph.isEnabled = false
        glyph.setAccessibilityLabel(nil)
        name.textColor = .labelColor
        name.font = .systemFont(ofSize: 13)
        dir.stringValue = ""
        badge.stringValue = ""
        badge.toolTip = nil
        toolTip = nil
        switch content {
        case .change(let f, let showsFolder):
            let path = f.path as NSString
            name.stringValue = path.lastPathComponent
            dir.stringValue = showsFolder ? path.deletingLastPathComponent : ""
            toolTip = f.diff.change.isRename ? "\(f.diff.change.oldPath) → \(f.path)" : f.path
            glyph.isEnabled = true
            glyph.image = f.reviewed ? symbol("checkmark.circle.fill", [.white, .controlAccentColor]) : symbol("circle", [.tertiaryLabelColor])
            glyph.setAccessibilityLabel(f.reviewed ? "Mark as not reviewed" : "Mark as reviewed")
            name.textColor = f.reviewed ? .secondaryLabelColor : .labelColor
            var (letter, color) = statusLetter(f.diff.change.status)
            if f.conflicted { (letter, color) = ("!", .systemRed) }
            badge.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
            badge.stringValue = letter
            badge.textColor = f.reviewed ? .tertiaryLabelColor : color
            badge.toolTip = switch letter {
            case "A": "Added"; case "U": "Untracked"; case "D": "Deleted"; case "R": "Renamed"; case "C": "Copied"
            case "T": "Type changed"; case "!": "Conflicted"; default: "Modified"
            }
        case .file(let p, let showsFolder):
            let path = p as NSString
            name.stringValue = path.lastPathComponent
            dir.stringValue = showsFolder ? path.deletingLastPathComponent : ""
            toolTip = p
            glyph.image = fileIcon(p)
        case .folder(let n, let reviewed, let changed):
            name.stringValue = n
            glyph.image = symbol("folder", [.secondaryLabelColor])
            count(reviewed, changed)
        case .folded(let n):
            name.stringValue = "\(n) unchanged"
            name.textColor = .secondaryLabelColor
            glyph.image = symbol("ellipsis", [.tertiaryLabelColor])
            toolTip = "Show unchanged items"
        case .allChanges(let reviewed, let changed):
            name.stringValue = "All Changes"
            glyph.image = symbol("square.stack", [.secondaryLabelColor])
            count(reviewed, changed)
        }
        needsLayout = true
    }
}

/// Returns the Finder icon for a file's type, at row size.
@MainActor
func fileIcon(_ path: String) -> NSImage {
    let ext = (path as NSString).pathExtension.lowercased()
    if let cached = fileIcons[ext] { return cached }
    let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .plainText)
    icon.size = NSSize(width: 16, height: 16)
    fileIcons[ext] = icon
    return icon
}

@MainActor private var fileIcons: [String: NSImage] = [:]

func compactDate(_ d: Date) -> String {
    let s = -d.timeIntervalSinceNow
    if s < 60 { return "now" }
    if s < 3600 { return "\(Int(s / 60))m" }
    if s < 86400 { return "\(Int(s / 3600))h" }
    if s < 86400 * 7 { return "\(Int(s / 86400))d" }
    let cal = Calendar.current
    if cal.component(.year, from: d) == cal.component(.year, from: Date()) {
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
    return d.formatted(.dateTime.year(.twoDigits).month(.twoDigits).day(.twoDigits))
}

@MainActor
final class TargetCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("TargetCell")
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = TargetCell.id
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        title.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail
        title.font = .systemFont(ofSize: 13)
        count.translatesAutoresizingMaskIntoConstraints = false
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        count.textColor = .secondaryLabelColor
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(icon); addSubview(title); addSubview(count)
        imageView = icon
        textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title t: String, symbol: String, count n: Int) {
        title.stringValue = t
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        count.stringValue = n > 0 ? "\(n)" : ""
        title.textColor = n > 0 || symbol == "arrow.triangle.branch" ? .labelColor : .secondaryLabelColor
    }
}

/// A small pie showing how much of a commit has been reviewed.
@MainActor
final class ProgressPie: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 14) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let color = NSColor.controlAccentColor
        if fraction >= 1 {
            let img = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Reviewed")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular).applying(.init(paletteColors: [.white, NSColor.systemGreen])))
            img?.draw(in: bounds)
            return
        }
        color.withAlphaComponent(0.6).setStroke()
        let ring = NSBezierPath(ovalIn: r)
        ring.lineWidth = 1.2
        ring.stroke()
        guard fraction > 0 else { return }
        let c = NSPoint(x: r.midX, y: r.midY)
        let p = NSBezierPath()
        p.move(to: c)
        p.appendArc(withCenter: c, radius: r.width / 2 - 1.5, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
        p.close()
        color.setFill()
        p.fill()
    }
}

@MainActor
final class CommitCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("CommitCell")
    let subject = NSTextField(labelWithString: "")
    let meta = NSTextField(labelWithString: "")
    let date = NSTextField(labelWithString: "")
    let pie = ProgressPie()

    init() {
        super.init(frame: .zero)
        identifier = CommitCell.id
        for v in [subject, meta, date] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.lineBreakMode = .byTruncatingTail
            v.maximumNumberOfLines = 1
            v.usesSingleLineMode = true
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(v)
        }
        subject.font = .systemFont(ofSize: 13)
        meta.font = .systemFont(ofSize: 11)
        date.font = .systemFont(ofSize: 11)
        date.textColor = .secondaryLabelColor
        date.alignment = .right
        date.setContentCompressionResistancePriority(.required, for: .horizontal)
        date.setContentHuggingPriority(.required, for: .horizontal)
        pie.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pie)
        textField = subject
        NSLayoutConstraint.activate([
            subject.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            subject.trailingAnchor.constraint(equalTo: pie.leadingAnchor, constant: -6),
            subject.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            meta.leadingAnchor.constraint(equalTo: subject.leadingAnchor),
            meta.trailingAnchor.constraint(lessThanOrEqualTo: date.leadingAnchor, constant: -6),
            meta.topAnchor.constraint(equalTo: subject.bottomAnchor, constant: 2),
            date.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            date.firstBaselineAnchor.constraint(equalTo: meta.firstBaselineAnchor),
            pie.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            pie.centerYAnchor.constraint(equalTo: subject.centerYAnchor),
            pie.widthAnchor.constraint(equalToConstant: 14),
            pie.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { pie.needsDisplay = true }
    }

    /// Fills in the row for a commit.
    ///
    /// The meta line shows the sha, then the refs (they identify the commit), then the author,
    /// which truncates first.
    func configure(subject s: String, sha: String, author: String?, date d: Date, refs: [String], progress: (done: Int, total: Int)) {
        subject.stringValue = s
        subject.textColor = progress.total > 0 && progress.done == progress.total ? .secondaryLabelColor : .labelColor
        let secondary = NSColor.secondaryLabelColor
        let m = NSMutableAttributedString(string: sha, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: secondary])
        for r in refs.prefix(3) {
            m.append(NSAttributedString(string: "  " + r, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.controlAccentColor]))
        }
        if let author {
            m.append(NSAttributedString(string: "  " + author, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: secondary]))
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        m.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: m.length))
        meta.attributedStringValue = m
        date.stringValue = compactDate(d)
        toolTip = "\(s)\n\(author ?? "")  \(d.formatted(date: .abbreviated, time: .shortened))" + (refs.isEmpty ? "" : "\n" + refs.joined(separator: ", "))
        pie.isHidden = progress.done == 0
        pie.fraction = progress.total == 0 ? 0 : CGFloat(progress.done) / CGFloat(progress.total)
    }
}
