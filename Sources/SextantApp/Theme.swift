import AppKit
import os
import SextantCore

/// A flat map of color tokens.
///
/// User themes live in `~/.config/sextant/themes/*.json`:
///
///     { "name": "My Dark", "appearance": "dark", "base": "Revue Dark", "cardOpacity": 0.8,
///       "colors": { "canvas": "#101010", "syntax.keyword": "#ff8080" } }
///
/// Any token not given falls back to the base theme (or the built-in of the same appearance).
struct Theme {
    var name: String
    var isDark: Bool
    var colors: [String: NSColor]
    /// How opaque the code cards' canvas is over the window's frost, so the wallpaper's colour
    /// comes through the cards as it does the frost. A theme keeps it high enough that its syntax
    /// and diff text stay at WCAG AA on plain, added and removed lines over any backdrop.
    var cardOpacity: CGFloat

    func color(_ key: String) -> NSColor {
        colors[key] ?? (isDark ? Theme.revueDark : Theme.revueLight).colors[key] ?? .magenta
    }

    var canvas: NSColor { color("canvas") }
    var fg: NSColor { color("fg") }
    var fgMuted: NSColor { color("fgMuted") }
    var border: NSColor { color("border") }

    /// Text and icons quieter than `fgMuted`, such as section labels.
    var fgSubtle: NSColor { color("fgSubtle") }
    /// Idle controls, which come up to `fgSubtle` on hover.
    var fgFaint: NSColor { color("fgFaint") }

    /// The focused card's shadow: its colour comes from `cardShadow`, and its blur and offset
    /// from the appearance, softer in light.
    var cardShadowRadius: CGFloat { isDark ? 8 : 6 }

    func syntax(_ k: TokenKind) -> NSColor {
        switch k {
        case .keyword: color("syntax.keyword")
        case .string: color("syntax.string")
        case .comment: color("syntax.comment")
        case .number: color("syntax.number")
        case .type: color("syntax.type")
        case .function: color("syntax.function")
        case .constant: color("syntax.constant")
        case .attribute: color("syntax.attribute")
        case .variable: color("syntax.variable")
        case .tag: color("syntax.tag")
        case .property: color("syntax.property")
        }
    }

    static func parse(_ hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 6 {
            r = CGFloat((v >> 16) & 0xff) / 255; g = CGFloat((v >> 8) & 0xff) / 255; b = CGFloat(v & 0xff) / 255; a = 1
        } else {
            r = CGFloat((v >> 24) & 0xff) / 255; g = CGFloat((v >> 16) & 0xff) / 255; b = CGFloat((v >> 8) & 0xff) / 255; a = CGFloat(v & 0xff) / 255
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    static func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        let v = [s.redComponent, s.greenComponent, s.blueComponent].map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
        return "#" + v + (s.alphaComponent < 1 ? String(format: "%02x", Int((s.alphaComponent * 255).rounded())) : "")
    }

    /// A user theme file spelling out every token, for copying and editing.
    var json: String {
        let colorLines = colors.keys.sorted().map { "    \"\($0)\": \"\(Theme.hex(colors[$0]!))\"" }.joined(separator: ",\n")
        return """
        {
          "name": "My \(name)",
          "appearance": "\(isDark ? "dark" : "light")",
          "base": "\(name)",
          "cardOpacity": \(cardOpacity),
          "colors": {
        \(colorLines)
          }
        }

        """
    }

    init(name: String, isDark: Bool, cardOpacity: CGFloat = 1, hex: [String: String]) {
        self.name = name
        self.isDark = isDark
        self.cardOpacity = cardOpacity
        colors = hex.compactMapValues(Theme.parse)
    }

    init(name: String, isDark: Bool, cardOpacity: CGFloat = 1, colors: [String: NSColor]) {
        self.name = name
        self.isDark = isDark
        self.cardOpacity = cardOpacity
        self.colors = colors
    }

    static let revueLight = Theme(name: "Revue Light", isDark: false, cardOpacity: 0.95, hex: [
        "canvas": "#f9fafb", "fg": "#1f2328", "fgMuted": "#656c76", "border": "#1f23281a",
        "header": "#1f232808", "lineNumber": "#8c959f",
        "addLine": "#1a7f3714", "addNum": "#1a7f3714", "addWord": "#1a7f3733",
        "delLine": "#cf222e12", "delNum": "#cf222e12", "delWord": "#cf222e2e",
        "hunkLine": "#1f232809", "hunkNum": "#1f232809", "hunkFg": "#818991",
        "emptyLine": "#1f232806", "hatch": "#1f232812", "selection": "#0969da2e", "findMatch": "#d4a72c40",
        "accent": "#0969da", "success": "#1a7f37", "danger": "#d1242f", "attention": "#9a6700", "done": "#8250df",
        "syntax.keyword": "#a40e26", "syntax.string": "#0a3069", "syntax.comment": "#59636e",
        "syntax.number": "#0550ae", "syntax.type": "#953800", "syntax.function": "#6639ba",
        "syntax.constant": "#0550ae", "syntax.attribute": "#0550ae", "syntax.variable": "#953800",
        "syntax.tag": "#116329", "syntax.property": "#0550ae",
        "cardStroke": "#1f232817", "cardStrokeFocused": "#1f232824", "cardShadow": "#1f23281f", "cardHighlight": "#ffffff99",
        "fgSubtle": "#818991", "fgFaint": "#1f232866", "selectionPill": "#fdfdfe", "selectionPillStroke": "#1f23281a", "hover": "#1f23280a",
    ])

    static let revueDark = Theme(name: "Revue Dark", isDark: true, cardOpacity: 0.78, hex: [
        "canvas": "#13171d", "fg": "#e6edf3", "fgMuted": "#8b939d", "border": "#ffffff14",
        "header": "#e6edf308", "lineNumber": "#6e7681",
        "addLine": "#3fb9501a", "addNum": "#3fb9501a", "addWord": "#3fb95047",
        "delLine": "#f851491c", "delNum": "#f851491c", "delWord": "#f8514947",
        "hunkLine": "#e6edf309", "hunkNum": "#e6edf309", "hunkFg": "#6e7681",
        "emptyLine": "#e6edf306", "hatch": "#e6edf30f", "selection": "#388bfd40", "findMatch": "#bb800947",
        "accent": "#4493f8", "success": "#3fb950", "danger": "#f85149", "attention": "#d29922", "done": "#ab7df8",
        "syntax.keyword": "#ff7b72", "syntax.string": "#a5d6ff", "syntax.comment": "#9198a1",
        "syntax.number": "#79c0ff", "syntax.type": "#ffa657", "syntax.function": "#d2a8ff",
        "syntax.constant": "#79c0ff", "syntax.attribute": "#79c0ff", "syntax.variable": "#ffa657",
        "syntax.tag": "#7ee787", "syntax.property": "#79c0ff",
        "cardStroke": "#ffffff12", "cardStrokeFocused": "#ffffff1a", "cardShadow": "#00000059", "cardHighlight": "#ffffff0f",
        "fgSubtle": "#6e7681", "fgFaint": "#e6edf34d", "selectionPill": "#1c2026", "selectionPillStroke": "#ffffff1a", "hover": "#e6edf30b",
    ])

    static let revueDarkDimmed = Theme(name: "Revue Dark Dimmed", isDark: true, cardOpacity: 0.92, hex: [
        "canvas": "#212830", "fg": "#d1d7e0", "fgMuted": "#9198a1", "border": "#ffffff14",
        "header": "#cdd9e508", "lineNumber": "#656c76",
        "addLine": "#57ab5a1a", "addNum": "#57ab5a1a", "addWord": "#57ab5a47",
        "delLine": "#e5534b1c", "delNum": "#e5534b1c", "delWord": "#e5534b47",
        "hunkLine": "#cdd9e509", "hunkNum": "#cdd9e509", "hunkFg": "#768390",
        "emptyLine": "#cdd9e506", "hatch": "#cdd9e50f", "selection": "#4184e440", "findMatch": "#ae7c1447",
        "accent": "#478be6", "success": "#57ab5a", "danger": "#e5534b", "attention": "#c69026", "done": "#986ee2",
        "syntax.keyword": "#f47067", "syntax.string": "#96d0ff", "syntax.comment": "#768390",
        "syntax.number": "#6cb6ff", "syntax.type": "#f69d50", "syntax.function": "#dcbdfb",
        "syntax.constant": "#6cb6ff", "syntax.attribute": "#6cb6ff", "syntax.variable": "#f69d50",
        "syntax.tag": "#8ddb8c", "syntax.property": "#6cb6ff",
        "cardStroke": "#ffffff12", "cardStrokeFocused": "#ffffff1a", "cardShadow": "#00000059", "cardHighlight": "#ffffff0f",
        "fgSubtle": "#768390", "fgFaint": "#d1d7e04d", "selectionPill": "#262c34", "selectionPillStroke": "#ffffff1a", "hover": "#cdd9e50b",
    ])

    /// Revue Light with blue for added and orange for removed, as calm as its other diff colours.
    static let revueLightColorblind = revueLight.with(name: "Revue Light Colorblind", hex: [
        "addLine": "#0969da17", "addNum": "#0969da17", "addWord": "#0969da4f",
        "delLine": "#bc4c0017", "delNum": "#bc4c0017", "delWord": "#bc4c004d",
        "success": "#0969da", "danger": "#bc4c00",
    ])

    /// Revue Dark with blue for added and orange for removed, as calm as its other diff colours.
    static let revueDarkColorblind = revueDark.with(name: "Revue Dark Colorblind", hex: [
        "addLine": "#388bfd17", "addNum": "#388bfd17", "addWord": "#388bfd47",
        "delLine": "#db6d2817", "delNum": "#db6d2817", "delWord": "#db6d2847",
        "success": "#58a6ff", "danger": "#db6d28",
    ])

    /// Revue Light with GitHub's stock code and diff colours.
    static let githubLight = revueLight.with(name: "GitHub Light", cardOpacity: 1, hex: [
        "canvas": "#ffffff", "syntax.keyword": "#cf222e", "fgMuted": "#59636e", "lineNumber": "#6e7781",
        "addLine": "#dafbe1", "addNum": "#d1f8d9", "addWord": "#aceebb",
        "delLine": "#ffebe9", "delNum": "#ffcecb", "delWord": "#ff818266",
        "hunkLine": "#ddf4ff", "hunkNum": "#b6e3ff", "hunkFg": "#59636e",
        "emptyLine": "#f6f8fa", "selection": "#0969da33", "findMatch": "#fae17d99",
    ])

    /// Revue Dark with GitHub's stock code and diff colours.
    static let githubDark = revueDark.with(name: "GitHub Dark", cardOpacity: 1, hex: [
        "canvas": "#0d1117", "fgMuted": "#9198a1",
        "addLine": "#2ea04326", "addNum": "#3fb9504d", "addWord": "#2ea04366",
        "delLine": "#f851491a", "delNum": "#f851494d", "delWord": "#f8514966",
        "hunkLine": "#388bfd1a", "hunkNum": "#388bfd66", "hunkFg": "#9198a1",
        "emptyLine": "#151b23", "selection": "#388bfd4d", "findMatch": "#bb800966",
    ])

    /// Revue Dark Dimmed with GitHub's stock code and diff colours.
    static let githubDarkDimmed = revueDarkDimmed.with(name: "GitHub Dark Dimmed", cardOpacity: 1, hex: [
        "addLine": "#46954a26", "addNum": "#57ab5a4d", "addWord": "#46954a66",
        "delLine": "#e5534b1a", "delNum": "#e5534b4d", "delWord": "#e5534b66",
        "hunkLine": "#4184e41a", "hunkNum": "#4184e466", "hunkFg": "#9198a1",
        "emptyLine": "#262c36", "selection": "#4184e44d", "findMatch": "#ae7c1466",
    ])

    static let githubLightHighContrast = Theme(name: "GitHub Light High Contrast", isDark: false, hex: [
        "canvas": "#ffffff", "fg": "#010409", "fgMuted": "#454c54", "border": "#20252c",
        "header": "#e6eaef", "lineNumber": "#454c54",
        "addLine": "#d2fedb", "addNum": "#82e596", "addWord": "#82e596",
        "delLine": "#fff0ee", "delNum": "#ffc1bc", "delWord": "#ee5a5d66",
        "hunkLine": "#9cd7ff", "hunkNum": "#9cd7ff", "hunkFg": "#010409",
        "emptyLine": "#e6eaef", "hatch": "#20252c26", "selection": "#0349b433", "findMatch": "#fcd53c",
        "accent": "#0349b4", "success": "#055d20", "danger": "#a0111f", "attention": "#744500", "done": "#622cbc",
        "syntax.keyword": "#a0111f", "syntax.string": "#032563", "syntax.comment": "#4b535d",
        "syntax.number": "#023b95", "syntax.type": "#702c00", "syntax.function": "#622cbc",
        "syntax.constant": "#023b95", "syntax.attribute": "#023b95", "syntax.variable": "#702c00",
        "syntax.tag": "#024c1a", "syntax.property": "#023b95",
        "cardStroke": "#20252c3d", "cardStrokeFocused": "#20252c66", "cardShadow": "#01040926", "cardHighlight": "#ffffffcc",
        "fgSubtle": "#454c54", "fgFaint": "#01040999", "selectionPill": "#ffffff", "selectionPillStroke": "#20252c40", "hover": "#01040912",
    ])

    /// GitHub Light with Primer's colour-blind diff colours: blue for added and orange for removed.
    static let githubLightColorblind = githubLight.with(name: "GitHub Light Colorblind", hex: [
        "addLine": "#ddf4ff", "addNum": "#b6e3ff", "addWord": "#b6e3ff",
        "delLine": "#fff1e5", "delNum": "#ffd8b5", "delWord": "#ffd8b5",
        "success": "#0969da", "danger": "#bc4c00",
    ])

    /// GitHub Dark with Primer's colour-blind diff colours: blue for added and orange for removed.
    static let githubDarkColorblind = githubDark.with(name: "GitHub Dark Colorblind", hex: [
        "addLine": "#388bfd26", "addNum": "#58a6ff4d", "addWord": "#388bfd66",
        "delLine": "#db6d2826", "delNum": "#db6d284d", "delWord": "#db6d2866",
        "success": "#58a6ff", "danger": "#db6d28",
    ])

    static let builtIn: [Theme] = [
        revueLight, revueDark, revueDarkDimmed, revueLightColorblind, revueDarkColorblind,
        githubLight, githubDark, githubDarkDimmed, githubLightHighContrast, githubLightColorblind, githubDarkColorblind,
    ]

    /// Reads a user theme file.
    ///
    /// - Parameters:
    ///   - url: The theme file.
    ///   - bases: The themes its `base` can name.
    /// - Returns: `nil` when the file can't be read as a theme.
    init?(file url: URL, bases: [Theme]) {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let name = obj["name"] as? String ?? url.deletingPathExtension().lastPathComponent
        let isDark = (obj["appearance"] as? String)?.lowercased() == "dark"
        let base = (obj["base"] as? String).flatMap { b in bases.first { $0.name == b } } ?? (isDark ? Theme.revueDark : Theme.revueLight)
        var colors = base.colors
        for (k, v) in (obj["colors"] as? [String: String]) ?? [:] {
            if let c = Theme.parse(v) { colors[k] = c }
        }
        let opacity = (obj["cardOpacity"] as? Double).map { CGFloat(max(0.5, min(1, $0))) } ?? base.cardOpacity
        self.init(name: name, isDark: isDark, cardOpacity: opacity, colors: colors)
    }

    /// Returns a copy of the theme under another name, with some colours replaced.
    ///
    /// - Parameters:
    ///   - name: The copy's name.
    ///   - cardOpacity: The copy's card opacity, or `nil` to keep this theme's.
    ///   - hex: The colours to replace.
    func with(name: String, cardOpacity: CGFloat? = nil, hex: [String: String]) -> Theme {
        Theme(name: name, isDark: isDark, cardOpacity: cardOpacity ?? self.cardOpacity, colors: colors.merging(hex.compactMapValues(Theme.parse)) { $1 })
    }
}

/// The owner of theme and font preferences, which tells views when they change.
@MainActor
final class Appearance {
    static let shared = Appearance()
    static let didChange = Notification.Name("SextantAppearanceDidChange")

    private(set) var themes: [Theme] = Theme.builtIn
    private var observers: [NSObjectProtocol] = []

    static var themesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/sextant/themes", isDirectory: true)
    }

    private init() {
        UserDefaults.standard.register(defaults: [
            "lightTheme": "Revue Light", "darkTheme": "Revue Dark",
            "fontSize": 12.0, "fontName": "", "diffMode": "unified", "tabWidth": 4,
        ])
        reloadThemes()
        watchThemes()
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultsChanged() }
        })
    }

    private var lastSignature = ""
    private func defaultsChanged() {
        let d = UserDefaults.standard
        let sig = "\(d.string(forKey: "lightTheme") ?? "")|\(d.string(forKey: "darkTheme") ?? "")|\(d.double(forKey: "fontSize"))|\(d.string(forKey: "fontName") ?? "")|\(d.integer(forKey: "tabWidth"))"
        if sig != lastSignature {
            lastSignature = sig
            publishThemes()
            NotificationCenter.default.post(name: Appearance.didChange, object: nil)
        }
    }

    private var themeWatcher: FileWatcher?

    /// Watches theme files so they take effect as soon as they're saved.
    ///
    /// The folder may not exist yet, so this watches its nearest existing ancestor and only
    /// reacts to paths inside the themes folder.
    private func watchThemes() {
        let dir = Appearance.themesDirectory.resolvingSymlinksInPath().path
        var root = URL(fileURLWithPath: dir)
        while !FileManager.default.fileExists(atPath: root.path), root.path != "/" { root.deleteLastPathComponent() }
        themeWatcher = FileWatcher(paths: [root.path], latency: 0.2) { [weak self] paths in
            if paths.contains(where: { $0.hasPrefix(dir) }) { self?.reloadThemes() }
        }
    }

    /// Creates the themes folder with a disabled example listing every token of a theme.
    ///
    /// - Parameter base: The theme whose tokens the example lists.
    /// - Returns: The example's URL.
    func createThemesDirectory(example base: Theme) -> URL {
        let dir = Appearance.themesDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let example = dir.appendingPathComponent("example.json.disabled")
        if !FileManager.default.fileExists(atPath: example.path) {
            try? base.json.write(to: example, atomically: true, encoding: .utf8)
        }
        return example
    }

    func reloadThemes() {
        var result = Theme.builtIn
        let dir = Appearance.themesDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "json" {
            guard let theme = Theme(file: url, bases: result) else { continue }
            result.removeAll { $0.name == theme.name }
            result.append(theme)
        }
        themes = result
        publishThemes()
        NotificationCenter.default.post(name: Appearance.didChange, object: nil)
    }

    /// Tells themed colours which themes are current.
    private func publishThemes() {
        ThemedColors.use(light: theme(for: NSAppearance(named: .aqua)!), dark: theme(for: NSAppearance(named: .darkAqua)!))
    }

    func theme(for appearance: NSAppearance) -> Theme {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let name = UserDefaults.standard.string(forKey: dark ? "darkTheme" : "lightTheme") ?? ""
        return themes.first { $0.name == name } ?? (dark ? Theme.revueDark : Theme.revueLight)
    }

    var font: NSFont {
        let d = UserDefaults.standard
        let size = CGFloat(max(8, min(32, d.double(forKey: "fontSize"))))
        if let name = d.string(forKey: "fontName"), !name.isEmpty, let f = NSFont(name: name, size: size) { return f }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    var tabWidth: Int { max(1, UserDefaults.standard.integer(forKey: "tabWidth")) }

    func adjustFontSize(_ delta: Double) {
        let d = UserDefaults.standard
        d.set(max(8, min(32, d.double(forKey: "fontSize") + delta)), forKey: "fontSize")
    }

    func resetFontSize() { UserDefaults.standard.removeObject(forKey: "fontSize") }
}

/// The current light and dark themes, for colours that resolve while drawing.
///
/// The appearance that draws a colour picks the theme, so chrome follows both the system's light
/// or dark mode and the user's theme choices.
enum ThemedColors {
    private static let state = OSAllocatedUnfairLock(uncheckedState: (light: Theme.revueLight, dark: Theme.revueDark, cache: [String: NSColor]()))

    /// Makes the given themes the ones themed colours resolve from.
    static func use(light: Theme, dark: Theme) {
        state.withLockUnchecked { $0.light = light; $0.dark = dark }
    }

    /// A colour that resolves to a theme token in whatever appearance draws it.
    static func color(_ key: String) -> NSColor {
        state.withLockUnchecked { s in
            if let c = s.cache[key] { return c }
            let c = NSColor(name: NSColor.Name("sextant." + key)) { appearance in
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let theme = state.withLockUnchecked { dark ? $0.dark : $0.light }
                return theme.color(key)
            }
            s.cache[key] = c
            return c
        }
    }
}

extension NSColor {
    /// A theme token as a colour that follows the appearance it's drawn in.
    static func themed(_ key: String) -> NSColor { ThemedColors.color(key) }
}

extension NSImage {
    /// Returns an SF Symbol drawn in one colour, keeping the cut-outs of the system's monochrome
    /// rendering, such as the check in `checkmark.circle.fill`.
    ///
    /// A palette of one colour would paint those cut-outs in the colour too. The colour resolves
    /// when the image draws, so a themed colour follows the appearance it's drawn in.
    ///
    /// - Parameters:
    ///   - name: The symbol's name.
    ///   - configuration: The symbol's size and weight.
    ///   - color: The colour to draw it in.
    ///   - label: What the symbol shows, for accessibility.
    /// - Returns: The image, or `nil` when there's no such symbol.
    static func monochromeSymbol(_ name: String, configuration: NSImage.SymbolConfiguration, color: NSColor, label: String? = nil) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(configuration) else { return nil }
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.alignmentRect = base.alignmentRect
        image.accessibilityDescription = label
        return image
    }
}
