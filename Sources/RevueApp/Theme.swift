import AppKit
import RevueCore

/// A flat map of color tokens.
///
/// User themes live in `~/.config/revue/themes/*.json`:
///
///     { "name": "My Dark", "appearance": "dark", "base": "GitHub Dark",
///       "colors": { "canvas": "#101010", "syntax.keyword": "#ff8080" } }
///
/// Any token not given falls back to the base theme (or the built-in of the same appearance).
struct Theme {
    var name: String
    var isDark: Bool
    var colors: [String: NSColor]

    func color(_ key: String) -> NSColor {
        colors[key] ?? (isDark ? Theme.githubDark : Theme.githubLight).colors[key] ?? .magenta
    }

    var canvas: NSColor { color("canvas") }
    var fg: NSColor { color("fg") }
    var fgMuted: NSColor { color("fgMuted") }
    var border: NSColor { color("border") }

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
          "colors": {
        \(colorLines)
          }
        }

        """
    }

    init(name: String, isDark: Bool, hex: [String: String]) {
        self.name = name
        self.isDark = isDark
        colors = hex.compactMapValues(Theme.parse)
    }

    init(name: String, isDark: Bool, colors: [String: NSColor]) {
        self.name = name
        self.isDark = isDark
        self.colors = colors
    }

    static let githubLight = Theme(name: "GitHub Light", isDark: false, hex: [
        "canvas": "#ffffff", "fg": "#1f2328", "fgMuted": "#59636e", "border": "#d1d9e0",
        "header": "#f6f8fa", "lineNumber": "#6e7781",
        "addLine": "#dafbe1", "addNum": "#d1f8d9", "addWord": "#aceebb",
        "delLine": "#ffebe9", "delNum": "#ffcecb", "delWord": "#ff818266",
        "hunkLine": "#ddf4ff", "hunkNum": "#b6e3ff", "hunkFg": "#59636e",
        "emptyLine": "#f6f8fa", "selection": "#0969da33", "findMatch": "#fae17d99",
        "accent": "#0969da", "success": "#1a7f37", "danger": "#d1242f", "attention": "#9a6700", "done": "#8250df",
        "syntax.keyword": "#cf222e", "syntax.string": "#0a3069", "syntax.comment": "#59636e",
        "syntax.number": "#0550ae", "syntax.type": "#953800", "syntax.function": "#6639ba",
        "syntax.constant": "#0550ae", "syntax.attribute": "#0550ae", "syntax.variable": "#953800",
        "syntax.tag": "#116329", "syntax.property": "#0550ae",
    ])

    static let githubDark = Theme(name: "GitHub Dark", isDark: true, hex: [
        "canvas": "#0d1117", "fg": "#e6edf3", "fgMuted": "#9198a1", "border": "#3d444d",
        "header": "#151b23", "lineNumber": "#6e7681",
        "addLine": "#2ea04326", "addNum": "#3fb9504d", "addWord": "#2ea04366",
        "delLine": "#f851491a", "delNum": "#f851494d", "delWord": "#f8514966",
        "hunkLine": "#388bfd1a", "hunkNum": "#388bfd66", "hunkFg": "#9198a1",
        "emptyLine": "#151b23", "selection": "#388bfd4d", "findMatch": "#bb800966",
        "accent": "#4493f8", "success": "#3fb950", "danger": "#f85149", "attention": "#d29922", "done": "#ab7df8",
        "syntax.keyword": "#ff7b72", "syntax.string": "#a5d6ff", "syntax.comment": "#9198a1",
        "syntax.number": "#79c0ff", "syntax.type": "#ffa657", "syntax.function": "#d2a8ff",
        "syntax.constant": "#79c0ff", "syntax.attribute": "#79c0ff", "syntax.variable": "#ffa657",
        "syntax.tag": "#7ee787", "syntax.property": "#79c0ff",
    ])

    static let githubDarkDimmed = Theme(name: "GitHub Dark Dimmed", isDark: true, hex: [
        "canvas": "#212830", "fg": "#d1d7e0", "fgMuted": "#9198a1", "border": "#3d444d",
        "header": "#262c36", "lineNumber": "#656c76",
        "addLine": "#46954a26", "addNum": "#57ab5a4d", "addWord": "#46954a66",
        "delLine": "#e5534b1a", "delNum": "#e5534b4d", "delWord": "#e5534b66",
        "hunkLine": "#4184e41a", "hunkNum": "#4184e466", "hunkFg": "#9198a1",
        "emptyLine": "#262c36", "selection": "#4184e44d", "findMatch": "#ae7c1466",
        "accent": "#478be6", "success": "#57ab5a", "danger": "#e5534b", "attention": "#c69026", "done": "#986ee2",
        "syntax.keyword": "#f47067", "syntax.string": "#96d0ff", "syntax.comment": "#768390",
        "syntax.number": "#6cb6ff", "syntax.type": "#f69d50", "syntax.function": "#dcbdfb",
        "syntax.constant": "#6cb6ff", "syntax.attribute": "#6cb6ff", "syntax.variable": "#f69d50",
        "syntax.tag": "#8ddb8c", "syntax.property": "#6cb6ff",
    ])

    static let githubLightHighContrast = Theme(name: "GitHub Light High Contrast", isDark: false, hex: [
        "canvas": "#ffffff", "fg": "#010409", "fgMuted": "#454c54", "border": "#20252c",
        "header": "#e6eaef", "lineNumber": "#454c54",
        "addLine": "#d2fedb", "addNum": "#82e596", "addWord": "#82e596",
        "delLine": "#fff0ee", "delNum": "#ffc1bc", "delWord": "#ee5a5d66",
        "hunkLine": "#9cd7ff", "hunkNum": "#9cd7ff", "hunkFg": "#010409",
        "emptyLine": "#e6eaef", "selection": "#0349b433", "findMatch": "#fcd53c",
        "accent": "#0349b4", "success": "#055d20", "danger": "#a0111f", "attention": "#744500", "done": "#622cbc",
        "syntax.keyword": "#a0111f", "syntax.string": "#032563", "syntax.comment": "#4b535d",
        "syntax.number": "#023b95", "syntax.type": "#702c00", "syntax.function": "#622cbc",
        "syntax.constant": "#023b95", "syntax.attribute": "#023b95", "syntax.variable": "#702c00",
        "syntax.tag": "#024c1a", "syntax.property": "#023b95",
    ])

    static let builtIn: [Theme] = [githubLight, githubDark, githubDarkDimmed, githubLightHighContrast]
}

/// The owner of theme and font preferences, which tells views when they change.
@MainActor
final class Appearance {
    static let shared = Appearance()
    static let didChange = Notification.Name("RevueAppearanceDidChange")

    private(set) var themes: [Theme] = Theme.builtIn
    private var observers: [NSObjectProtocol] = []

    static var themesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/revue/themes", isDirectory: true)
    }

    private init() {
        UserDefaults.standard.register(defaults: [
            "lightTheme": "GitHub Light", "darkTheme": "GitHub Dark",
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
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let name = obj["name"] as? String ?? url.deletingPathExtension().lastPathComponent
            let isDark = (obj["appearance"] as? String)?.lowercased() == "dark"
            let base = (obj["base"] as? String).flatMap { b in result.first { $0.name == b } } ?? (isDark ? Theme.githubDark : Theme.githubLight)
            var colors = base.colors
            for (k, v) in (obj["colors"] as? [String: String]) ?? [:] {
                if let c = Theme.parse(v) { colors[k] = c }
            }
            result.removeAll { $0.name == name }
            result.append(Theme(name: name, isDark: isDark, colors: colors))
        }
        themes = result
        NotificationCenter.default.post(name: Appearance.didChange, object: nil)
    }

    func theme(for appearance: NSAppearance) -> Theme {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let name = UserDefaults.standard.string(forKey: dark ? "darkTheme" : "lightTheme") ?? ""
        return themes.first { $0.name == name } ?? (dark ? Theme.githubDark : Theme.githubLight)
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
