import AppKit

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
final class PaneCard: NSView, PaneSurface {
    private let clip = NSView()
    private let cardShadow = CALayer()
    private let shadowCutout = CAShapeLayer()
    private let content: NSView
    private let header: PaneHeader
    /// The part of the card in view, in its own coordinates.
    private var part = NSRect.zero
    private var mainObservers: [NSObjectProtocol] = []

    /// Concentric with the window's corners, at the strip's margin from them.
    static let cornerRadius: CGFloat = GlassLook.windowCornerRadius - GlassLook.margin
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
