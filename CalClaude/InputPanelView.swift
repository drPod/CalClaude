import SwiftUI
import AppKit

struct InputPanelView: View {
    @ObservedObject var panelState: PanelState
    @ObservedObject var screenCaptureService: ScreenCaptureService
    @State private var inputText = ""

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
            if let image = screenCaptureService.capturedImage {
                VStack(spacing: 6) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 120)
                        .cornerRadius(6)

                    HStack(spacing: 8) {
                        Text("Press Send to extract event details")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove") {
                            screenCaptureService.clearCapture()
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        Button("Recapture") {
                            Task {
                                try? await screenCaptureService.captureFrontmostWindow()
                            }
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .disabled(panelState.isLoading)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }

            HStack(alignment: .top, spacing: 10) {
                TextField(
                    screenCaptureService.capturedImage != nil
                        ? "Describe the event, or just press Send"
                        : "Ask Claude…",
                    text: $inputText,
                    axis: .vertical
                )
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
                    .onSubmit { submit() }
                    .disabled(panelState.isLoading)

                if screenCaptureService.capturedImage == nil {
                    Button("Recapture") {
                        Task {
                            try? await screenCaptureService.captureFrontmostWindow()
                        }
                    }
                    .disabled(panelState.isLoading)
                }
            }
            .padding(8)

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

    private func submit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || screenCaptureService.screenshotPath != nil else { return }
        guard !panelState.isLoading else { return }
        onSubmit(text, screenCaptureService.screenshotPath)
    }
}
