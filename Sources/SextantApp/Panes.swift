import AppKit
import SextantCore

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
    let reader: Reader
    /// The surface the reader shows on, in the strip.
    let surface: PaneSurface
    var session: Session?
    /// What the reader shows: the overview of every change, or one file.
    var focus: Location.Place?
    /// Where to land once the session has loaded.
    var pendingLocation: Location?
    var showGeneration = 0
    var loadingGeneration: Int?
    /// Whether search results open in this pane, as they do in the pane opened for the first.
    var showsResults = false

    init(look: any Look) {
        reader = Reader(look: look)
        surface = look.makePaneSurface(content: reader.view, header: reader.header)
    }

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
/// Each pane says where it is in its own header, so the strip only places them, as its look
/// lays them out.
@MainActor
final class PaneStrip: NSView {
    private let viewport = FlippedView()
    private let track = FlippedView()
    private var surfaces: [PaneSurface] = []
    private var offset: CGFloat = 0
    private(set) var focused = 0
    private let arrangement: StripLayout
    private let headerHeight: CGFloat
    /// The window-space frames of the titlebar controls that can sit over the panes' headers.
    var titlebarControls: () -> [NSRect] = { [] }

    /// The narrowest a pane gets beside others, below which each pane takes the whole strip.
    static let minimumPaneWidth: CGFloat = 480
    /// How long the strip takes to slide to a newly focused pane, and the panes to change emphasis.
    static let slideDuration: TimeInterval = 0.18
    /// The space kept between a titlebar control and the header content beside it.
    static let controlClearance: CGFloat = 10

    init(look: any Look) {
        arrangement = look.strip
        headerHeight = look.paneHeader.height
        super.init(frame: .zero)
        wantsLayer = true
        viewport.wantsLayer = true
        viewport.layer?.masksToBounds = true
        addSubview(viewport)
        viewport.addSubview(track)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = arrangement.seam?.cgColor
    }

    /// Shows panes in order, with one focused.
    func show(_ panes: [PaneSurface], focused index: Int, animated: Bool) {
        if !panes.elementsEqual(surfaces, by: ===) {
            for s in surfaces where !panes.contains(where: { $0 === s }) { s.removeFromSuperview() }
            for s in panes where s.superview !== track {
                s.translatesAutoresizingMaskIntoConstraints = true
                s.autoresizingMask = []
                track.addSubview(s)
            }
            surfaces = panes
        }
        focused = index
        for (i, s) in surfaces.enumerated() { s.setFocused(i == index, animated: animated) }
        layoutPanes(animated: animated)
    }

    /// The part of the strip the panes fill when they're all in view.
    ///
    /// The strip can reach under a floating sidebar, which the safe area at its leading side
    /// keeps the panes clear of. The top ignores the safe area, so the panes' headers can share
    /// the row with the traffic lights and toolbar buttons, which each header keeps its content
    /// clear of.
    private var paneArea: NSRect {
        let m = arrangement.margins, safe = safeAreaInsets
        let left = safe.left + m.left, right = safe.right + m.right
        return NSRect(x: left, y: m.top, width: max(0, bounds.width - left - right), height: max(0, bounds.height - m.top - m.bottom))
    }

    override func layout() {
        super.layout()
        layoutPanes(animated: false)
    }

    /// Whether every pane takes the whole strip, so the focused one fills it and the strip slides
    /// a whole pane at a time.
    var isZoomed = false {
        didSet { if isZoomed != oldValue { needsLayout = true } }
    }

    /// The width every pane takes: the whole strip for one pane or while zoomed, else two thirds
    /// of it, so the pane beside the focused one shows.
    var paneWidth: CGFloat {
        let w = paneArea.width
        guard surfaces.count > 1, !isZoomed else { return w }
        let part = (w * 2 / 3).rounded()
        return part < Self.minimumPaneWidth ? w : part
    }

    private func layoutPanes(animated: Bool) {
        let safe = safeAreaInsets
        viewport.frame = NSRect(x: safe.left, y: 0, width: max(0, bounds.width - safe.left - safe.right), height: bounds.height)
        let area = paneArea
        let w = paneWidth, h = area.height, gap = arrangement.gap
        for (i, s) in surfaces.enumerated() {
            let frame = NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: h)
            if s.frame != frame { s.frame = frame }
        }
        let total = surfaces.isEmpty ? 0 : CGFloat(surfaces.count) * (w + gap) - gap
        offset = stripOffset(showing: focused, from: offset, paneWidth: w, gap: gap, viewport: area.width, total: total)
        let trackFrame = NSRect(x: area.minX - viewport.frame.minX - offset, y: area.minY, width: max(total, area.width), height: h)
        let controls = titlebarControls()
        let place = {
            for s in self.surfaces {
                let x = self.viewport.frame.minX + trackFrame.minX + s.frame.minX
                let from = max(0, area.minX - x), to = min(w, area.maxX - x)
                s.show(part: NSRect(x: from, y: 0, width: max(0, to - from), height: h))
                let header = NSRect(x: x, y: area.minY, width: w, height: self.headerHeight)
                s.headerClearance = self.clearance(ofHeader: header, shownFrom: x + from, controls: controls)
            }
        }
        if animated, track.frame.size == trackFrame.size {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.slideDuration
                ctx.allowsImplicitAnimation = true
                track.animator().frame = trackFrame
                place()
            }
        } else {
            track.frame = trackFrame
            place()
        }
    }

    /// How far a pane's header keeps its content in from each end, clear of the titlebar
    /// controls over it.
    ///
    /// - Parameters:
    ///   - header: The header's frame in the strip.
    ///   - shownFrom: Where the pane starts showing, after any part cut off at the strip's edge.
    ///   - controls: The window-space frames of the titlebar controls.
    private func clearance(ofHeader header: NSRect, shownFrom: CGFloat, controls: [NSRect]) -> NSEdgeInsets {
        guard window != nil else { return NSEdgeInsetsZero }
        let inWindow = convert(header, to: nil)
        let shownMinX = inWindow.minX + (shownFrom - header.minX)
        var leading: CGFloat = 0, trailing: CGFloat = 0
        for c in controls where c.maxY > inWindow.minY && c.minY < inWindow.maxY && c.maxX > shownMinX && c.minX < inWindow.maxX {
            if c.midX < (shownMinX + inWindow.maxX) / 2 {
                leading = max(leading, c.maxX + Self.controlClearance - inWindow.minX)
            } else {
                trailing = max(trailing, inWindow.maxX - c.minX + Self.controlClearance)
            }
        }
        return NSEdgeInsets(top: 0, left: leading, bottom: 0, right: trailing)
    }
}

/// The window's split view, whose dividers stay invisible, so the strip and the inspector read
/// as one surface. They can still be dragged.
final class SeamlessSplitView: NSSplitView {
    override var dividerColor: NSColor { .clear }
}

extension NSView {
    /// Redraws the view and everything in it, as when the theme its colours resolve from changes.
    func redrawSubtree() {
        needsDisplay = true
        for v in subviews { v.redrawSubtree() }
    }
}

/// A view laid out from the top, like the panes in it.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
