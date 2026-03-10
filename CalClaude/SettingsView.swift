import SwiftUI

enum CalClaudeDefaults {
    static let systemPromptKey = "calclaude.systemPrompt"
    static let rememberPanelPositionKey = "calclaude.rememberPanelPosition"
    static let panelPositionSavedKey = "calclaude.panelPositionSaved"
    static let panelOriginXKey = "calclaude.panelOriginX"
    static let panelOriginYKey = "calclaude.panelOriginY"

    static var systemPrompt: String {
        get { UserDefaults.standard.string(forKey: systemPromptKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: systemPromptKey) }
    }

    static var rememberPanelPosition: Bool {
        get { UserDefaults.standard.object(forKey: rememberPanelPositionKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: rememberPanelPositionKey) }
    }
}

struct SettingsView: View {
    @AppStorage(CalClaudeDefaults.systemPromptKey) private var systemPrompt = ""
    @AppStorage(CalClaudeDefaults.rememberPanelPositionKey) private var rememberPanelPosition = true

    var body: some View {
        Form {
            Section {
                TextField(
                    "System prompt (e.g. “Always use my Life calendar unless specified”)",
                    text: $systemPrompt,
                    axis: .vertical
                )
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
            } header: {
                Text("Calendar defaults")
            } footer: {
                Text("This text is prepended to every Claude call. Use it to set default calendar or other preferences.")
            }

            Section {
                Toggle("Remember panel position", isOn: $rememberPanelPosition)
            } header: {
                Text("Panel")
            } footer: {
                Text("When off, the panel opens in the same spot each time.")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 200)
        .navigationTitle("Settings")
    }
}

#Preview {
    SettingsView()
}
