import AppKit

/// The look of macOS 11 to 15: flat columns that reach the window's edges between a title band
/// and a status bar, ruled off by hairlines, with each pane under a bar of its own.
struct ClassicLook: Look {
    var defaultThemes: (light: String, dark: String) { ("GitHub Light", "GitHub Dark") }

    /// Panes edge to edge, with a hairline of the strip between them.
    var strip: StripLayout { StripLayout(margins: NSEdgeInsetsZero, gap: 1, seam: .separatorColor) }

    /// A bar like an editor's in Xcode, raised for the focused pane.
    var paneHeader: PaneHeaderStyle {
        PaneHeaderStyle(height: 30, bar: (focused: Chrome.focusedBar, other: Chrome.bar), liesInTitlebar: false)
    }

    func makeFrame() -> WindowFrame { ClassicFrame() }

    func makePaneSurface(content: NSView, header: PaneHeader) -> PaneSurface { PaneColumn(content: content, header: header) }

    func makeRowView() -> NSTableRowView { ClassicRowView() }

    func floating(_ content: NSView, cornerRadius: CGFloat) -> NSView {
        Material(.popover, blending: .withinWindow, cornerRadius: cornerRadius, content: content)
    }

    func panel(_ content: NSView) -> NSView {
        Material(.popover, blending: .behindWindow, cornerRadius: 10, content: content)
    }

    /// Opaque, since nothing lies behind the strip to show through.
    func canvasOpacity(of theme: Theme) -> CGFloat { 1 }
}

/// The colours of the window's frame around the code: its side columns and bars.
enum Chrome {
    /// The navigator and inspector, flat and reaching the window's edges.
    static let panel = NSColor(name: "SextantPanel") { appearance in
        appearance.isDark ? NSColor(white: 0.155, alpha: 1) : NSColor(white: 0.955, alpha: 1)
    }

    /// The title band and status bar of the window in use.
    static let activeFrame = NSColor(name: "SextantActiveFrame") { appearance in
        appearance.isDark ? NSColor(white: 0.215, alpha: 1) : NSColor(white: 0.915, alpha: 1)
    }

    /// The title band and status bar of a window that isn't in use.
    static let inactiveFrame = NSColor(name: "SextantInactiveFrame") { appearance in
        appearance.isDark ? NSColor(white: 0.175, alpha: 1) : NSColor(white: 0.955, alpha: 1)
    }

    /// The headers of panes that don't have focus.
    static let bar = NSColor(name: "SextantBar") { appearance in
        appearance.isDark ? NSColor(white: 0.135, alpha: 1) : NSColor(white: 0.93, alpha: 1)
    }

    /// The header of the pane with focus, raised above the others.
    static let focusedBar = NSColor(name: "SextantFocusedBar") { appearance in
        appearance.isDark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.995, alpha: 1)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// The classic window's frame: a title band over the columns, holding the title, the column
/// toggles, what's reviewed and Go to Anything, and a status bar under them.
///
/// The side columns are plain split items, since a sidebar floats on glass, and they share the
/// frame's panel colour, which the window's root fills.
@MainActor
final class ClassicFrame: WindowFrame {
    private let titlebar = Titlebar()
    private let statusBar = StatusBar()
    private weak var controller: RepoWindowController?

    var navigatorHeading: NSView? { nil }

    var subjectAnchor: NSView? {
        let subject = titlebar.subject.subject
        return subject.window != nil && !subject.isHiddenOrHasHiddenAncestor ? subject : nil
    }

    func install(in controller: RepoWindowController) {
        self.controller = controller
        guard let window = controller.window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        titlebar.connect(to: controller)

        let splitView = controller.split.splitView
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        controller.split.splitViewItems = [.sideColumn(controller.navigator, maximum: 440), .strip(controller.strip), .sideColumn(controller.inspector, maximum: 420)]
        splitView.autosaveName = "SextantSplitClassic"
        let columns = controller.split.view

        let root = NSViewController()
        let v = FilledView(color: Chrome.panel)
        v.prefersCompactControlSizeMetrics = true
        root.view = v
        root.addChild(controller.split)
        for sub in [titlebar, columns, statusBar] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            titlebar.topAnchor.constraint(equalTo: v.topAnchor),
            titlebar.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            titlebar.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            columns.topAnchor.constraint(equalTo: titlebar.bottomAnchor),
            columns.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            columns.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        window.contentViewController = root
    }

    func show(_ summary: ReviewSummary) {
        titlebar.title.stringValue = summary.repository
        titlebar.subject.show(summary.subject, base: summary.base)
        statusBar.show(summary: summary.scope, reviewed: summary.reviewed, of: summary.total)
    }

    /// Lines the title band up with the columns shown.
    func columnsChanged() {
        guard let controller else { return }
        let items = controller.split.splitViewItems
        func width(_ column: RepoWindowController.SideColumn) -> CGFloat {
            controller.isShown(column) ? items[column.rawValue].viewController.view.frame.width : 0
        }
        titlebar.align(navigator: width(.navigator), inspector: width(.inspector))
    }
}

/// A view filled with a colour that follows the appearance.
final class FilledView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}

/// A bar of the window's frame, such as the title band or the status bar, which is lighter while
/// the window isn't the one in use, as titlebars are, and has a hairline on the edge it shares
/// with the columns.
@MainActor
class FrameBar: NSView {
    private let edge: NSRectEdge
    /// Whether the window is the one in use.
    private(set) var isActive = false

    init(edge: NSRectEdge) {
        self.edge = edge
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Moves the window when dragged, and zooms or minimizes it when double-clicked, as the user
    /// set in Settings, the way a titlebar does.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        guard event.clickCount == 2 else { return window.performDrag(with: event) }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }

    private static let activityNotifications = [NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification]

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        for name in Self.activityNotifications { NotificationCenter.default.removeObserver(self, name: name, object: window) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        activityChanged()
        guard let window else { return }
        for name in Self.activityNotifications {
            NotificationCenter.default.addObserver(self, selector: #selector(windowActivityChanged(_:)), name: name, object: window)
        }
    }

    @objc private func windowActivityChanged(_ n: Notification) { activityChanged() }

    /// Redraws for whether the window is in use, which subclasses extend to restyle their parts.
    func activityChanged() {
        isActive = window?.isMainWindow ?? false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        (isActive ? Chrome.activeFrame : Chrome.inactiveFrame).setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        let y = edge == .minY ? bounds.minY : bounds.maxY - 1
        NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
    }
}

/// A pane as a flat column of the strip, ruled off from its neighbours by the strip's seam. Its
/// header's bar shows whether it's focused, so nothing on it dims.
@MainActor
final class PaneColumn: NSView, PaneSurface {
    private let clip = NSView()
    private let content: NSView
    private let header: PaneHeader
    /// The part of the column in view, in its own coordinates.
    private var part = NSRect.zero

    init(content: NSView, header: PaneHeader) {
        self.content = content
        self.header = header
        super.init(frame: .zero)
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        addSubview(clip)
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = []
        clip.addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setFocused(_ focused: Bool, animated: Bool) {}

    var headerClearance = NSEdgeInsetsZero {
        didSet { header.clearance = headerClearance }
    }

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
    }
}

/// A side column's row, whose selection is a flat rounded bar inset from the column's edges, as
/// sidebars drew it before glass: grey, tinted with the theme's accent while the list has the
/// keyboard. Selected text keeps its colour.
final class ClassicRowView: NSTableRowView {
    private static let inset: CGFloat = 10

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        let theme = Appearance.shared.theme(for: effectiveAppearance)
        let bar = bounds.insetBy(dx: Self.inset, dy: 0)
        (isEmphasized ? theme.color("accent").withAlphaComponent(0.22) : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 5, yRadius: 5).fill()
    }
}

/// A classic material holding content, such as the popover material under Go to Anything, with
/// rounded corners and a hairline rim.
@MainActor
private final class Material: NSVisualEffectView {
    init(_ material: NSVisualEffectView.Material, blending: NSVisualEffectView.BlendingMode, cornerRadius: CGFloat, content: NSView) {
        super.init(frame: .zero)
        self.material = material
        blendingMode = blending
        state = .active
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        pin(content)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        colorRim()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        colorRim()
    }

    private func colorRim() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}
