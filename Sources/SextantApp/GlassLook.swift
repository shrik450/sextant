import AppKit

/// The look of macOS 26: the side columns and the panes' cards share one frosted backdrop, and a
/// toolbar floats over the cards' headers.
struct GlassLook: Look {
    /// The space between the cards and the strip's edges.
    static let margin: CGFloat = 8
    /// The corner radius of a macOS 26 window with a toolbar, measured from a capture, since
    /// AppKit doesn't publish it. The cards' corners are concentric with it.
    static let windowCornerRadius: CGFloat = 26
    /// The corner radius of Go to Anything, as round as a window's.
    static let panelCornerRadius: CGFloat = 20

    var defaultThemes: (light: String, dark: String) { ("Revue Light", "Revue Dark") }

    var strip: StripLayout {
        let m = Self.margin
        return StripLayout(margins: NSEdgeInsets(top: m, left: m, bottom: m, right: m), gap: 8, seam: nil)
    }

    /// A header centred on the traffic lights, in the titlebar's row.
    var paneHeader: PaneHeaderStyle { PaneHeaderStyle(height: 36, bar: nil, liesInTitlebar: true) }

    func makeFrame() -> WindowFrame { GlassFrame() }

    func makePaneSurface(content: NSView, header: PaneHeader) -> PaneSurface { PaneCard(content: content, header: header) }

    func makeRowView() -> NSTableRowView { PillRowView() }

    func floating(_ content: NSView, cornerRadius: CGFloat) -> NSView {
        let glass = NSGlassEffectView()
        glass.cornerRadius = cornerRadius
        glass.contentView = content
        return glass
    }

    func panel(_ content: NSView) -> NSView {
        let glass = floating(content, cornerRadius: Self.panelCornerRadius)
        let shape = NSView()
        shape.wantsLayer = true
        shape.layer?.cornerRadius = Self.panelCornerRadius
        shape.layer?.cornerCurve = .continuous
        shape.layer?.masksToBounds = true
        glass.autoresizingMask = [.width, .height]
        shape.addSubview(glass)
        return shape
    }

    /// The theme's card opacity, so the backdrop's frost shows through the cards.
    func canvasOpacity(of theme: Theme) -> CGFloat { theme.cardOpacity }
}

/// The glass window's frame: a navigator headed by the review, and a toolbar with the navigator
/// toggle and a few plain buttons beside the traffic lights and the inspector toggle at the far
/// end, so the cards rise to the top of the window between them.
///
/// The navigator is a plain column rather than the system's sidebar, whose own glass would set it
/// apart from the backdrop the rest of the window shares.
@MainActor
final class GlassFrame: NSObject, WindowFrame, NSToolbarDelegate {
    private let reviewHeader = ReviewHeader()
    private weak var controller: RepoWindowController?

    private static let navigatorToggleID = NSToolbarItem.Identifier("navigatorToggle")
    private static let goToAnythingID = NSToolbarItem.Identifier("goToAnything")
    private static let findInFilesID = NSToolbarItem.Identifier("findInFiles")
    private static let inspectorToggleID = NSToolbarItem.Identifier("inspectorToggle")

    var navigatorHeading: NSView? { reviewHeader }

    /// The review's subject while the navigator shows it.
    var subjectAnchor: NSView? {
        guard let controller, controller.isShown(.navigator), reviewHeader.window != nil else { return nil }
        return reviewHeader.subject
    }

    func install(in controller: RepoWindowController) {
        self.controller = controller
        guard let window = controller.window else { return }
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        reviewHeader.subject.target = controller
        reviewHeader.subject.action = #selector(RepoWindowController.chooseSubject(_:))
        reviewHeader.base.target = controller
        reviewHeader.base.action = #selector(RepoWindowController.baseChosen(_:))

        let columns = SeamlessSplitView()
        columns.isVertical = true
        columns.dividerStyle = .thin
        columns.arrangesAllSubviews = false
        controller.split.splitView = columns
        controller.split.splitViewItems = [.sideColumn(controller.navigator, maximum: 440), .strip(controller.strip), .sideColumn(controller.inspector, maximum: 420)]
        columns.autosaveName = "SextantSplit3"
        window.contentViewController = controller.split
        let backdrop = BackdropView(frame: columns.bounds)
        backdrop.autoresizingMask = [.width, .height]
        columns.addSubview(backdrop, positioned: .below, relativeTo: nil)

        let toolbar = NSToolbar(identifier: "SextantToolbar3")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        controller.strip.titlebarControls = { [weak self] in self?.titlebarControlFrames ?? [] }
    }

    func show(_ summary: ReviewSummary) { reviewHeader.show(summary) }

    func columnsChanged() {}

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.navigatorToggleID, Self.findInFilesID, Self.goToAnythingID, .flexibleSpace, Self.inspectorToggleID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.navigatorToggleID:
            buttonItem(id, "Navigator", symbol: "sidebar.left", shortcut: "⌘0", action: #selector(RepoWindowController.toggleNavigatorColumn(_:)))
        case Self.goToAnythingID:
            buttonItem(id, "Go to Anything", symbol: "magnifyingglass", shortcut: "⌘K", action: #selector(RepoWindowController.goToAnything(_:)))
        case Self.findInFilesID:
            buttonItem(id, "Find in Files", symbol: "text.page.badge.magnifyingglass", shortcut: "⇧⌘F", action: #selector(RepoWindowController.findInRepository(_:)))
        case Self.inspectorToggleID:
            buttonItem(id, "Inspector", symbol: "sidebar.right", shortcut: "⌥⌘0", action: #selector(RepoWindowController.toggleInspectorColumn(_:)))
        default:
            nil
        }
    }

    private func buttonItem(_ id: NSToolbarItem.Identifier, _ label: String, symbol: String, shortcut: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: controller, action: action)
        button.bezelStyle = .toolbar
        item.view = button
        item.label = label
        item.toolTip = "\(label) (\(shortcut))"
        return item
    }

    /// The window-space frames of the titlebar controls that can sit over the cards' row: the
    /// traffic lights and the buttons beside them, and the inspector toggle.
    private var titlebarControlFrames: [NSRect] {
        guard let window = controller?.window, let items = window.toolbar?.items else { return [] }
        func frame(_ id: NSToolbarItem.Identifier) -> NSRect? {
            guard let v = items.first(where: { $0.itemIdentifier == id })?.view, v.window != nil else { return nil }
            return v.convert(v.bounds, to: nil)
        }
        let width = window.frame.width
        var frames: [NSRect] = []
        if let last = frame(Self.goToAnythingID) { frames.append(NSRect(x: 0, y: last.minY, width: last.maxX, height: last.height)) }
        if let toggle = frame(Self.inspectorToggleID) { frames.append(NSRect(x: toggle.minX, y: toggle.minY, width: width - toggle.minX, height: toggle.height)) }
        return frames
    }
}

/// The window's surface behind all three columns and the seams between the cards: the system's
/// sidebar material, blended with what lies behind the window, under a wash of the theme's
/// `frostTint`.
///
/// The material frosts the desktop and other windows so that none of their shapes come through,
/// and the wash keeps the surface close to the theme's canvas, so the wallpaper only tints it, as
/// light refracted through glass would. It goes flat when the window is inactive, as the system's
/// own sidebars do.
@MainActor
final class BackdropView: NSVisualEffectView {
    private let wash = FrostWash()

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .sidebar
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        wash.frame = bounds
        wash.autoresizingMask = [.width, .height]
        addSubview(wash)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// The theme's `frostTint`, filling the frost it lies over.
@MainActor
private final class FrostWash: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Appearance.shared.theme(for: effectiveAppearance).color("frostTint").cgColor
    }
}

/// A side column's row, whose selection is a raised capsule of the theme's selection pill, with
/// a hairline and, in light, a soft shadow. Selected text keeps its colour.
final class PillRowView: NSTableRowView {
    /// How far the capsule keeps in from the column's edges.
    static let inset: CGFloat = 7

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        let theme = Appearance.shared.theme(for: effectiveAppearance)
        let pill = bounds.insetBy(dx: Self.inset, dy: 1)
        let shape = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
        NSGraphicsContext.saveGraphicsState()
        if !theme.isDark {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.themed("fg").withAlphaComponent(0.08)
            shadow.shadowBlurRadius = 3.5
            shadow.shadowOffset = NSSize(width: 0, height: -1.5)
            shadow.set()
        }
        theme.color("selectionPill").setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        theme.color("selectionPillStroke").setStroke()
        let edge = NSBezierPath(roundedRect: pill.insetBy(dx: 0.25, dy: 0.25), xRadius: pill.height / 2, yRadius: pill.height / 2)
        edge.lineWidth = 0.5
        edge.stroke()
    }
}
