import AppKit

/// The look the user chose in Settings, which each window takes when it opens and keeps.
enum LookChoice: String, CaseIterable {
    /// Cards of code on frosted glass, under a toolbar that floats over them.
    case glass
    /// Flat columns between a title band and a status bar, the way macOS looked before glass.
    case classic

    static let defaultsKey = "look"

    /// The look chosen in Settings.
    static var chosen: LookChoice {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(LookChoice.init) ?? .glass
    }

    /// The look itself, the only place a window's parts are told apart by look.
    @MainActor
    var look: any Look {
        switch self {
        case .glass: GlassLook()
        case .classic: ClassicLook()
        }
    }

    var title: String {
        switch self {
        case .glass: "Glass"
        case .classic: "Classic"
        }
    }
}

/// How a window looks: the frame around its columns, the surfaces its panes sit on, its lists'
/// selection and the materials of what floats over the code.
///
/// What a window shows and does is the same in every look.
@MainActor
protocol Look {
    /// The themes used where the user hasn't chosen one, by name.
    var defaultThemes: (light: String, dark: String) { get }
    /// How the strip places its panes.
    var strip: StripLayout { get }
    /// How a pane's header sits on its pane.
    var paneHeader: PaneHeaderStyle { get }
    /// Makes the frame a window's columns sit in.
    func makeFrame() -> WindowFrame
    /// Puts a pane's reader on the surface it shows on in the strip.
    ///
    /// - Parameters:
    ///   - content: The reader's view, which fills the surface.
    ///   - header: The reader's header, at the top of `content`.
    func makePaneSurface(content: NSView, header: PaneHeader) -> PaneSurface
    /// Makes a row of a side column's list, which draws its selection.
    func makeRowView() -> NSTableRowView
    /// Puts something that floats over the code, such as the change counter, on its material.
    ///
    /// - Parameters:
    ///   - content: What floats, which fills the material.
    ///   - cornerRadius: The radius of the material's corners.
    func floating(_ content: NSView, cornerRadius: CGFloat) -> NSView
    /// Puts the contents of a panel over the window, such as Go to Anything, on its material.
    ///
    /// - Parameter content: The panel's contents, which fill the material.
    /// - Returns: The material, with its corners already rounded.
    func panel(_ content: NSView) -> NSView
    /// The opacity of a pane's canvas, over whatever lies behind the strip.
    func canvasOpacity(of theme: Theme) -> CGFloat
}

/// How the strip places its panes.
struct StripLayout {
    /// The space between the panes and the strip's edges.
    var margins: NSEdgeInsets
    /// The space between neighbouring panes.
    var gap: CGFloat
    /// What fills the strip between and around the panes, or `nil` to let what's behind it show.
    var seam: NSColor?
}

/// How a pane's header sits on its pane.
struct PaneHeaderStyle {
    var height: CGFloat
    /// The header's fill when its pane is focused and when it isn't, or `nil` to leave it clear
    /// over the pane's canvas.
    var bar: (focused: NSColor, other: NSColor)?
    /// Whether the header lies in the window's titlebar, so a double click zooms the window as
    /// a titlebar's would.
    var liesInTitlebar: Bool
}

/// The frame a window's columns sit in, which shows what the window reviews and gives the
/// window its controls for the columns.
@MainActor
protocol WindowFrame: AnyObject {
    /// What the navigator shows above its tabs, if anything.
    var navigatorHeading: NSView? { get }
    /// The view the subject picker opens from, when it's in view.
    var subjectAnchor: NSView? { get }
    /// Sets the window up and puts the controller's columns in it.
    func install(in controller: RepoWindowController)
    /// Shows what the window reviews.
    func show(_ summary: ReviewSummary)
    /// Follows the side columns as they show, hide or resize.
    func columnsChanged()
}

/// The surface a pane shows on in the strip.
@MainActor
protocol PaneSurface: NSView {
    /// Focuses the pane or lets it recede.
    ///
    /// - Parameters:
    ///   - focused: Whether the pane is the focused one.
    ///   - animated: Whether to change in step with the strip sliding to it.
    func setFocused(_ focused: Bool, animated: Bool)
    /// Shows only part of the pane, as when the strip's edge cuts it off.
    ///
    /// Call it inside an animation group to move the cut with the strip.
    func show(part: NSRect)
    /// How far the header keeps its content in from each end, clear of titlebar controls.
    var headerClearance: NSEdgeInsets { get set }
}

@MainActor
extension NSSplitViewItem {
    /// Makes a side column that sits beside the panes, as the inspector does.
    ///
    /// - Parameters:
    ///   - controller: The column's contents.
    ///   - maximum: The widest the column gets.
    static func sideColumn(_ controller: NSViewController, maximum: CGFloat) -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: controller)
        item.holdingPriority = .init(260)
        item.configureSideColumn(maximum: maximum)
        return item
    }

    /// Gives a side column its widths and lets it fold away.
    ///
    /// - Parameter maximum: The widest the column gets.
    func configureSideColumn(maximum: CGFloat) {
        minimumThickness = 220
        maximumThickness = maximum
        preferredThicknessFraction = 0.18
        canCollapse = true
        canCollapseFromWindowResize = true
    }

    /// Makes the column for the strip of panes.
    static func strip(_ strip: PaneStrip) -> NSSplitViewItem {
        let controller = NSViewController()
        controller.view = strip
        let item = NSSplitViewItem(viewController: controller)
        item.minimumThickness = 420
        return item
    }
}

extension NSView {
    /// Adds a view that fills this one, following its size.
    func pin(_ child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: topAnchor),
            child.bottomAnchor.constraint(equalTo: bottomAnchor),
            child.leadingAnchor.constraint(equalTo: leadingAnchor),
            child.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
}
