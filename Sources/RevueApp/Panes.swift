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
    /// Every definition in the snapshot, once indexed.
    var definitions: [LocatedDefinition]?
    /// How many files are indexed of how many need it, while indexing.
    var indexing: (done: Int, total: Int)?
    var indexTask: Task<Void, Never>?
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

    /// The pane's name: its file, or All Changes.
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
///
/// Each pane says where it is in its own header, so the strip only places them.
@MainActor
final class PaneStrip: NSView {
    private let viewport = NSView()
    private let track = FlippedView()
    private var views: [NSView] = []
    private var offset: CGFloat = 0
    private(set) var focused = 0

    /// The narrowest a pane gets beside others, below which each pane takes the whole strip.
    static let minimumPaneWidth: CGFloat = 480
    /// The space between neighbouring panes.
    static let gap: CGFloat = 1

    override init(frame: NSRect) {
        super.init(frame: frame)
        viewport.wantsLayer = true
        viewport.layer?.masksToBounds = true
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(viewport)
        viewport.addSubview(track)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Shows panes in order, with one focused.
    func show(_ panes: [NSView], focused index: Int, animated: Bool) {
        if panes != views {
            for v in views where !panes.contains(v) { v.removeFromSuperview() }
            for v in panes where v.superview !== track {
                v.translatesAutoresizingMaskIntoConstraints = true
                v.autoresizingMask = []
                track.addSubview(v)
            }
            views = panes
        }
        focused = index
        layoutPanes(animated: animated)
    }

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
        viewport.frame = bounds
        let w = paneWidth, h = viewport.bounds.height, gap = Self.gap
        for (i, v) in views.enumerated() {
            let frame = NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: h)
            if v.frame != frame { v.frame = frame }
        }
        let total = views.isEmpty ? 0 : CGFloat(views.count) * (w + gap) - gap
        offset = stripOffset(showing: focused, from: offset, paneWidth: w, gap: gap, viewport: viewport.bounds.width, total: total)
        let trackFrame = NSRect(x: -offset, y: 0, width: max(total, viewport.bounds.width), height: h)
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
