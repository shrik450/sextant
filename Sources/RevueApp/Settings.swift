import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage("lightTheme") private var lightTheme = "GitHub Light"
    @AppStorage("darkTheme") private var darkTheme = "GitHub Dark"
    @AppStorage("fontName") private var fontName = ""
    @AppStorage("fontSize") private var fontSize = 12.0
    @AppStorage("tabWidth") private var tabWidth = 4
    @AppStorage("editorCommand") private var editorCommand = ""
    @State private var themes: [String] = Appearance.shared.themes.map(\.name)

    private static let monospacedFamilies: [String] = NSFontManager.shared.availableFontFamilies.filter { fam in
        guard let f = NSFont(name: fam, size: 12) else { return false }
        return f.isFixedPitch || fam.localizedCaseInsensitiveContains("mono") || fam.localizedCaseInsensitiveContains("code")
    }

    var body: some View {
        Form {
            Section {
                Picker("Light appearance", selection: $lightTheme) {
                    ForEach(themes, id: \.self) { Text($0).tag($0) }
                }
                Picker("Dark appearance", selection: $darkTheme) {
                    ForEach(themes, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Spacer()
                    Button("Show Themes Folder") { revealThemes() }
                }
            } header: {
                Text("Theme")
            }
            Section {
                Picker("Font", selection: $fontName) {
                    Text("System Monospaced").tag("")
                    Divider()
                    ForEach(Self.monospacedFamilies, id: \.self) { Text($0).tag($0) }
                }
                Stepper(value: $fontSize, in: 8...32, step: 1) {
                    LabeledContent("Size", value: "\(Int(fontSize)) pt")
                }
                Stepper(value: $tabWidth, in: 1...16) {
                    LabeledContent("Tab width", value: "\(tabWidth)")
                }
            } header: {
                Text("Text")
            }
            Section {
                TextField("Command", text: $editorCommand, prompt: Text("Default app"))
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("Open in Editor")
            } footer: {
                Text("Shell command; {file} and {line} are replaced. For example: zed {file}:{line}")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: Appearance.didChange)) { _ in
            themes = Appearance.shared.themes.map(\.name)
        }
    }

    private func revealThemes() {
        let current = Appearance.shared.theme(for: NSApp.effectiveAppearance)
        let example = Appearance.shared.createThemesDirectory(example: current)
        NSWorkspace.shared.activateFileViewerSelecting([example])
    }
}

final class SettingsViewController: NSHostingController<SettingsView> {
    init() { super.init(rootView: SettingsView()) }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
}
