import SwiftUI

enum CalClaudeDefaults {
    static let systemPromptKey = "calclaude.systemPrompt"

    static var systemPrompt: String {
        get { UserDefaults.standard.string(forKey: systemPromptKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: systemPromptKey) }
    }
}

struct SettingsView: View {
    @AppStorage(CalClaudeDefaults.systemPromptKey) private var systemPrompt = ""

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
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 200)
        .navigationTitle("Settings")
    }
}

#Preview {
    SettingsView()
}
