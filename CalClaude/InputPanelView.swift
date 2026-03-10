import SwiftUI
import AppKit

struct InputPanelView: View {
    @ObservedObject var panelState: PanelState
    @State private var inputText = ""
    @State private var screenshotPath: String?
    @State private var isCapturing = false

    var onDismiss: () -> Void
    var onSubmit: (String, String?) -> Void
    var onConfirmCreate: (CalendarEventPayload) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let created = panelState.eventCreatedMessage {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(created)
                        .font(.subheadline)
                }
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
            } else if let payload = panelState.pendingEvent {
                confirmationToast(payload)
            } else {
                inputSection
            }

            if let error = panelState.validationError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)
            }
        }
        .frame(minWidth: 480, minHeight: 100)
        .background(.ultraThinMaterial)
        .onExitCommand {
            onDismiss()
        }
    }

    private var inputSection: some View {
        Group {
            HStack(alignment: .top, spacing: 10) {
                TextField("Ask Claude…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
                    .onSubmit { submit() }
                    .disabled(panelState.isLoading)

                Button("Capture Screenshot") {
                    captureScreenshot()
                }
                .disabled(isCapturing || panelState.isLoading)
            }
            .padding(8)

            if let path = screenshotPath {
                HStack {
                    Image(systemName: "photo.fill")
                        .foregroundStyle(.secondary)
                    Text(path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove") {
                        screenshotPath = nil
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 8)
            }

            HStack {
                if panelState.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Thinking…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Spacer()
                Button("Send") {
                    submit()
                }
                .disabled(panelState.isLoading)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private func confirmationToast(_ payload: CalendarEventPayload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(payload.title)
                .font(.headline)
                .lineLimit(1)
            Text("\(payload.date) at \(payload.time) · \(payload.duration) min · \(payload.calendar)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Create") {
                onConfirmCreate(payload)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial)
    }

    private func captureScreenshot() {
        isCapturing = true
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalClaude_screenshot_\(UUID().uuidString.prefix(8)).png")

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", tempURL.path]

            do {
                try process.run()
                process.waitUntilExit()
                let success = process.terminationStatus == 0 &&
                    FileManager.default.fileExists(atPath: tempURL.path) &&
                    ((try? FileManager.default.attributesOfItem(atPath: tempURL.path))?[.size] as? Int64 ?? 0) > 0
                DispatchQueue.main.async {
                    isCapturing = false
                    if success {
                        screenshotPath = tempURL.path
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isCapturing = false
                }
            }
        }
    }

    private func submit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || screenshotPath != nil else { return }
        guard !panelState.isLoading else { return }
        onSubmit(text, screenshotPath)
    }
}
