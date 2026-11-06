import AppKit

/// The fonts of the navigator and inspector, from the system's text styles, so the side
/// columns read like the system's own sidebars, though in the theme's colours.
extension NSFont {
    /// A quiet section label, like a sidebar's group headings, in sentence case.
    static var sectionLabel: NSFont {
        let subheadline = NSFont.preferredFont(forTextStyle: .subheadline)
        return .systemFont(ofSize: subheadline.pointSize, weight: .medium)
    }

    /// A row's main text.
    static var row: NSFont { .preferredFont(forTextStyle: .body) }

    /// What a row says beside or under its main text, such as a folder, an author or a date.
    static var detail: NSFont { .preferredFont(forTextStyle: .callout) }

    /// Counts and change sizes beside a row's text, with digits that line up.
    static var detailDigits: NSFont { .monospacedDigitSystemFont(ofSize: detail.pointSize, weight: .regular) }

    /// Hashes and line numbers beside a row's text, in the code's style.
    static var detailCode: NSFont { .monospacedSystemFont(ofSize: detail.pointSize, weight: .regular) }
}
