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
    let reader = Reader()
    /// The card the reader shows in, in the strip.
    private(set) lazy var card = PaneCard(content: reader.view, header: reader.header)
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
/// Each pane is a card inset from the strip's edges, and says where it is in its own header,
/// so the strip only places them.
@MainActor
final class PaneStrip: NSView {
    private let viewport = FlippedView()
    private let track = FlippedView()
    private var cards: [PaneCard] = []
    private var offset: CGFloat = 0
    private(set) var focused = 0
    /// The window-space frames of the titlebar controls that can sit over the cards' headers.
    var titlebarControls: () -> [NSRect] = { [] }

    /// The narrowest a pane gets beside others, below which each pane takes the whole strip.
    static let minimumPaneWidth: CGFloat = 480
    /// The space between neighbouring cards.
    static let gap: CGFloat = 8
    /// How long the strip takes to slide to a newly focused card, and the cards to change emphasis.
    static let slideDuration: TimeInterval = 0.18
    /// The space between the cards and the strip's edges, the same as the sidebar's glass keeps
    /// from the window's edges.
    static let margins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    /// The corner radius of a macOS 26 window with a toolbar, measured from a capture, since
    /// AppKit doesn't publish it. The cards' corners are concentric with it.
    static let windowCornerRadius: CGFloat = 26
    /// The space kept between a titlebar control and the header content beside it.
    static let controlClearance: CGFloat = 10

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        viewport.wantsLayer = true
        viewport.layer?.masksToBounds = true
        addSubview(viewport)
        viewport.addSubview(track)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Shows panes' cards in order, with one focused.
    func show(_ panes: [PaneCard], focused index: Int, animated: Bool) {
        if panes != cards {
            for c in cards where !panes.contains(c) { c.removeFromSuperview() }
            for c in panes where c.superview !== track {
                c.translatesAutoresizingMaskIntoConstraints = true
                c.autoresizingMask = []
                track.addSubview(c)
            }
            cards = panes
        }
        focused = index
        for (i, c) in cards.enumerated() { c.setFocused(i == index, animated: animated) }
        layoutPanes(animated: animated)
    }

    /// The part of the strip the cards fill when they're all in view.
    ///
    /// The strip reaches under the sidebar, which the safe area at its leading side keeps the
    /// cards clear of. The top ignores the safe area, so the cards' headers share the row with
    /// the traffic lights and toolbar buttons, which each header keeps its content clear of.
    private var cardArea: NSRect {
        let m = Self.margins, safe = safeAreaInsets
        let left = safe.left + m.left, right = safe.right + m.right
        return NSRect(x: left, y: m.top, width: max(0, bounds.width - left - right), height: max(0, bounds.height - m.top - m.bottom))
    }

    override func layout() {
        super.layout()
        layoutPanes(animated: false)
    }

    /// The width every pane takes: the whole strip for one pane, else two thirds of it, so the
    /// pane beside the focused one shows.
    var paneWidth: CGFloat {
        let w = cardArea.width
        guard cards.count > 1 else { return w }
        let part = (w * 2 / 3).rounded()
        return part < Self.minimumPaneWidth ? w : part
    }

    private func layoutPanes(animated: Bool) {
        let safe = safeAreaInsets
        viewport.frame = NSRect(x: safe.left, y: 0, width: max(0, bounds.width - safe.left - safe.right), height: bounds.height)
        let area = cardArea
        let w = paneWidth, h = area.height, gap = Self.gap
        for (i, c) in cards.enumerated() {
            let frame = NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: h)
            if c.frame != frame { c.frame = frame }
        }
        let total = cards.isEmpty ? 0 : CGFloat(cards.count) * (w + gap) - gap
        offset = stripOffset(showing: focused, from: offset, paneWidth: w, gap: gap, viewport: area.width, total: total)
        let trackFrame = NSRect(x: area.minX - viewport.frame.minX - offset, y: area.minY, width: max(total, area.width), height: h)
        let controls = titlebarControls()
        let place = {
            for c in self.cards {
                let x = self.viewport.frame.minX + trackFrame.minX + c.frame.minX
                let from = max(0, area.minX - x), to = min(w, area.maxX - x)
                c.show(part: NSRect(x: from, y: 0, width: max(0, to - from), height: h))
                let header = NSRect(x: x, y: area.minY, width: w, height: PaneHeader.height)
                c.headerClearance = self.clearance(ofHeader: header, shownFrom: x + from, controls: controls)
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

    /// How far a card's header keeps its content in from each end, clear of the titlebar
    /// controls over it.
    ///
    /// - Parameters:
    ///   - header: The header's frame in the strip.
    ///   - shownFrom: Where the card starts showing, after any part cut off at the strip's edge.
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

/// A pane as a card: its reader, clipped to rounded corners, raised off the frost by a shadow and
/// edged with a one-pixel rim, as the system's glass panels are.
///
/// The focused card in the main window stands out with a full shadow and a brighter rim, and the
/// others recede: their shadow halves, and what's drawn on them dims to 70% in the main window and
/// to 50% in an inactive one. The card's fill, which the content view paints as its own
/// background, keeps the theme's card opacity, so a dimmed card lets no more of the backdrop
/// through than a focused one; only its text, line tints and controls fade. The shadow falls only
/// outside the card, so it doesn't darken the card's fill through its translucency.
///
/// The window stays main while a panel or popover of its own, such as Go to Anything or a note,
/// takes the keyboard, so the cards don't change then. A card cut off at the strip's edge shows as
/// a narrower card, with its own rounded corners and rim on the cut side.
@MainActor
final class PaneCard: NSView {
    private let clip = NSView()
    private let cardShadow = CALayer()
    private let shadowCutout = CAShapeLayer()
    private let content: NSView
    private let header: PaneHeader
    /// The part of the card in view, in its own coordinates.
    private var part = NSRect.zero
    private var mainObservers: [NSObjectProtocol] = []

    /// Concentric with the window's corners, at the strip's margin from them.
    static let cornerRadius: CGFloat = PaneStrip.windowCornerRadius - PaneStrip.margins.top
    private static let shadowOffset = CGSize(width: 0, height: -2)

    private(set) var isFocused = true

    /// Focuses the card or lets it recede, fading its content and shadow in step with the strip
    /// when animated.
    ///
    /// - Parameters:
    ///   - focused: Whether the card is the focused one.
    ///   - animated: Whether to fade, as when the strip slides to the newly focused card.
    func setFocused(_ focused: Bool, animated: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        applyEmphasis(animated: animated)
    }

    /// How far the header keeps its content in from each end, clear of titlebar controls.
    var headerClearance = NSEdgeInsetsZero {
        didSet { header.clearance = headerClearance }
    }

    init(content: NSView, header: PaneHeader) {
        self.content = content
        self.header = header
        super.init(frame: .zero)
        wantsLayer = true
        cardShadow.shadowOpacity = 0
        shadowCutout.fillRule = .evenOdd
        cardShadow.mask = shadowCutout
        layer?.addSublayer(cardShadow)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Self.cornerRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        addSubview(clip)
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = []
        clip.addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    private var isEmphasized: Bool { isFocused && (window?.isMainWindow ?? true) }

    override func updateLayer() {
        guard let clipLayer = clip.layer else { return }
        let theme = Appearance.shared.theme(for: effectiveAppearance)
        cardShadow.shadowColor = theme.color("cardShadow").cgColor
        if cardShadow.shadowRadius != theme.cardShadowRadius {
            cardShadow.shadowRadius = theme.cardShadowRadius
            placeParts()
        }
        cardShadow.shadowOffset = Self.shadowOffset
        clipLayer.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
        clipLayer.borderColor = theme.color(isEmphasized ? "cardRimFocused" : "cardRim").cgColor
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    private func applyEmphasis(animated: Bool) {
        let alpha: CGFloat = isFocused ? 1 : window?.isMainWindow ?? true ? 0.7 : 0.5
        let opacity: Float = isEmphasized ? 1 : 0.5
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? PaneStrip.slideDuration : 0
            for v in content.subviews { v.animator().alphaValue = alpha }
        }
        if cardShadow.shadowOpacity != opacity {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if animated {
                let fade = CABasicAnimation(keyPath: "shadowOpacity")
                fade.fromValue = cardShadow.presentation()?.shadowOpacity ?? cardShadow.shadowOpacity
                fade.duration = PaneStrip.slideDuration
                cardShadow.add(fade, forKey: "shadowOpacity")
            }
            cardShadow.shadowOpacity = opacity
            CATransaction.commit()
        }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        mainObservers.forEach(NotificationCenter.default.removeObserver)
        mainObservers = []
        guard let window else { return }
        applyEmphasis(animated: false)
        for name in [NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
            mainObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyEmphasis(animated: false) }
            })
        }
    }

    /// Shows only part of the card, as when the strip's edge cuts it off.
    ///
    /// Call it inside an animation group to move the cut with the strip.
    func show(part: NSRect) {
        self.part = part
        placeParts()
    }

    override func layout() {
        super.layout()
        placeParts()
    }

    private func placeParts() {
        isHidden = part.width < 1
        clip.frame = part
        content.frame = NSRect(x: -part.minX, y: -part.minY, width: bounds.width, height: bounds.height)
        let r = Self.cornerRadius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let card = NSRect(origin: .zero, size: part.size)
        cardShadow.frame = part
        cardShadow.shadowPath = CGPath(roundedRect: card, cornerWidth: r, cornerHeight: r, transform: nil)
        let reach = cardShadow.shadowRadius * 3 + abs(Self.shadowOffset.height)
        let cutout = CGMutablePath()
        cutout.addRect(card.insetBy(dx: -reach, dy: -reach))
        cutout.addRoundedRect(in: card, cornerWidth: r, cornerHeight: r)
        shadowCutout.frame = card
        shadowCutout.path = cutout
        CATransaction.commit()
    }
}

/// The window's surface behind all three columns and the seams between the cards: the system's
/// sidebar material, blended with what lies behind the window.
///
/// It frosts the desktop and other windows enough that their colour and light come through but
/// none of their shapes, and it goes flat when the window is inactive, as the system's own
/// sidebars do.
@MainActor
final class BackdropView: NSVisualEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .sidebar
        blendingMode = .behindWindow
        state = .followsWindowActiveState
    }

    required init?(coder: NSCoder) { fatalError() }
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
