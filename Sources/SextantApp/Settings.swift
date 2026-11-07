import AppKit
import SextantCore
import SwiftUI

struct SettingsView: View {
    @AppStorage(LookChoice.defaultsKey) private var look: LookChoice = .glass
    @AppStorage("lightTheme") private var lightTheme: String?
    @AppStorage("darkTheme") private var darkTheme: String?
    @AppStorage("fontName") private var fontName = ""
    @AppStorage("fontSize") private var fontSize = 12.0
    @AppStorage("tabWidth") private var tabWidth = 4
    @AppStorage("editorCommand") private var editorCommand = ""
    @State private var themes: [String] = Appearance.shared.themes.map(\.name)
    @State private var monospaced: [String] = []

    /// The fixed-pitch font families, listed once, off the main actor.
    private static let monospacedFamilies = Task.detached(priority: .userInitiated) { monospacedFontFamilies() }

    /// The fonts to offer: the fixed-pitch families, and the chosen font if it isn't one of them.
    private var fonts: [String] {
        fontName.isEmpty || monospaced.contains(fontName) ? monospaced : [fontName] + monospaced
    }

    var body: some View {
        Form {
            Section {
                Picker("Look", selection: $look) {
                    ForEach(LookChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Window")
            } footer: {
                Text("Applies to windows you open next.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Light appearance", selection: theme($lightTheme, dark: false)) {
                    ForEach(themes, id: \.self) { Text($0).tag($0) }
                }
                Picker("Dark appearance", selection: theme($darkTheme, dark: true)) {
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
                    ForEach(fonts, id: \.self) { Text($0).tag($0) }
                }
                .task { monospaced = await Self.monospacedFamilies.value }
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

    /// A theme choice that shows the look's theme until the user chooses one.
    ///
    /// - Parameters:
    ///   - stored: The user's choice, if they made one.
    ///   - dark: Whether the choice is for the dark appearance.
    private func theme(_ stored: Binding<String?>, dark: Bool) -> Binding<String> {
        Binding(get: { stored.wrappedValue ?? Appearance.defaultThemeName(dark: dark) }, set: { stored.wrappedValue = $0 })
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
