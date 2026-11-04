import AppKit
import RevueCore

/// A review loaded for reading, shared by every pane that shows it.
@MainActor
final class Session {
    var review: Review
    var resolved: ResolvedReview?
    /// The review's changes, in diff order.
    var changes: [FileState] = []
    /// Every file in the review's snapshot.
    var snapshotFiles: [String] = []
    var snapshotLoaded: Snapshot?
    /// Files read while exploring the snapshot, by path.
    var explored: [String: FileState] = [:]
    var commitDetail: CommitDetail?
    var lastDiffs: [FileDiff]?
    var lastKey: String?
    var loadGeneration = 0
    var isLoading = false
    var error: String?
    /// Whether to offer the picker if the review turns out empty.
    var pickerIfEmpty = false

    init(review: Review) { self.review = review }

    var target: Target? { resolved?.target }
}

/// One reader in the window's strip, showing a place in a review.
@MainActor
final class Pane {
    let reader = Reader()
    var session: Session?
    /// What the reader shows: the overview of every change, or one file.
    var focus: Location.Place?
    /// Where to land once the session has loaded.
    var pendingLocation: Location?
    var showGeneration = 0
    var loadingGeneration: Int?
    /// Whether search results open in this pane, as they do in the pane opened for the first.
    var showsResults = false

    /// Whether a file is loading to show.
    var isLoadingFile: Bool { loadingGeneration == showGeneration }

    /// The pane's name in the trail: its file, or All Changes.
    var title: String {
        switch focus {
        case .file(let p)?: (p as NSString).lastPathComponent
        case .overview?: "All Changes"
        case nil: "Empty"
        }
    }
}

/// The window's panes side by side, like windows in a scrolling window manager: each pane
/// keeps its width, and the strip slides so the focused one is in view, with its neighbour
/// showing at the edge.
@MainActor
final class PaneStrip: NSView {
    private let trail = NSStackView()
    private let viewport = NSView()
    private let track = FlippedView()
    private let accent = NSView()
    private var views: [NSView] = []
    private var offset: CGFloat = 0
    private var shownTrail: (titles: [String], focused: Int)?
    private(set) var focused = 0
    var onSelect: ((Int) -> Void)?

    static let trailHeight: CGFloat = 26
    /// The narrowest a pane gets beside others, below which each pane takes the whole strip.
    static let minimumPaneWidth: CGFloat = 480

    override init(frame: NSRect) {
        super.init(frame: frame)
        trail.orientation = .horizontal
        trail.spacing = 2
        trail.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        viewport.wantsLayer = true
        viewport.layer?.masksToBounds = true
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.separatorColor.cgColor
        accent.wantsLayer = true
        accent.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        addSubview(trail)
        addSubview(viewport)
        viewport.addSubview(track)
        track.addSubview(accent)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Shows panes in order, with one focused.
    func show(_ panes: [NSView], titles: [String], focused index: Int, animated: Bool) {
        if panes != views {
            for v in views where !panes.contains(v) { v.removeFromSuperview() }
            for v in panes where v.superview !== track {
                v.translatesAutoresizingMaskIntoConstraints = true
                v.autoresizingMask = []
                track.addSubview(v, positioned: .below, relativeTo: accent)
            }
            views = panes
        }
        focused = index
        showTrail(titles)
        layoutPanes(animated: animated)
    }

    private func showTrail(_ titles: [String]) {
        if let shown = shownTrail, shown.titles == titles, shown.focused == focused { return }
        shownTrail = (titles, focused)
        trail.isHidden = titles.count < 2
        for v in trail.arrangedSubviews { v.removeFromSuperview() }
        guard titles.count > 1 else { return }
        for (i, t) in titles.enumerated() {
            if i > 0 {
                let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.compact.right", accessibilityDescription: nil)!)
                chevron.symbolConfiguration = .init(pointSize: 10, weight: .regular)
                chevron.contentTintColor = .tertiaryLabelColor
                trail.addArrangedSubview(chevron)
            }
            let b = NSButton(title: t, target: self, action: #selector(crumbClicked(_:)))
            b.bezelStyle = .inline
            b.isBordered = i == focused
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: i == focused ? .semibold : .regular)
            b.tag = i
            b.lineBreakMode = .byTruncatingMiddle
            b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            trail.addArrangedSubview(b)
        }
    }

    @objc private func crumbClicked(_ sender: NSButton) { onSelect?(sender.tag) }

    /// The width every pane takes: the whole strip for one pane, else two thirds of it, so the
    /// pane beside the focused one shows.
    var paneWidth: CGFloat {
        let w = viewport.bounds.width
        guard views.count > 1 else { return w }
        let part = (w * 2 / 3).rounded()
        return part < Self.minimumPaneWidth ? w : part
    }

    override func layout() {
        super.layout()
        layoutPanes(animated: false)
    }

    private func layoutPanes(animated: Bool) {
        let inset = safeAreaInsets.top
        let top = inset + (trail.isHidden ? 0 : Self.trailHeight)
        trail.frame = NSRect(x: 0, y: inset, width: bounds.width, height: Self.trailHeight)
        viewport.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        let w = paneWidth, h = viewport.bounds.height
        for (i, v) in views.enumerated() {
            let frame = NSRect(x: CGFloat(i) * (w + 1), y: 0, width: w, height: h)
            if v.frame != frame { v.frame = frame }
        }
        let total = views.isEmpty ? 0 : CGFloat(views.count) * (w + 1) - 1
        offset = stripOffset(showing: focused, from: offset, paneWidth: w, viewport: viewport.bounds.width, total: total)
        let trackFrame = NSRect(x: -offset, y: 0, width: max(total, viewport.bounds.width), height: h)
        accent.isHidden = views.count < 2
        accent.frame = NSRect(x: CGFloat(focused) * (w + 1), y: 0, width: w, height: 2)
        if animated, track.frame.size == trackFrame.size {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.allowsImplicitAnimation = true
                track.animator().frame = trackFrame
            }
        } else {
            track.frame = trackFrame
        }
    }
}


/// A view laid out from the top, like the panes in it.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
