# CalClaude

A macOS menubar app for creating calendar events with natural language, powered by Claude.

Press **⌘⇧C** from anywhere to open a Spotlight-style panel, describe your event in plain English (optionally attach a screenshot), and CalClaude uses the Claude CLI to parse it into a calendar event.

## Features

- **Global hotkey** — ⌘⇧C summons the input panel from any app
- **Natural language** — "Lunch with Sarah tomorrow at noon for 90 minutes"
- **Screenshot support** — Capture a region and let Claude read event details from images
- **Confirmation step** — Review parsed event details before creating
- **Cancel support** — Cancel long-running requests with a single click
- **Guided onboarding** — First-launch wizard walks through CLI, Accessibility, and Calendar setup

## Prerequisites

- **macOS 13.0+**
- **Claude CLI** installed and on your PATH ([install guide](https://docs.anthropic.com/en/docs/claude-code/overview))
- **Xcode 15+** (to build from source)

## Build from Source

```bash
git clone https://github.com/your-username/CalClaude.git
cd CalClaude
open CalClaude.xcodeproj
```

Select the **CalClaude** scheme, then **⌘R** to build and run.

## First Launch

CalClaude's onboarding wizard checks three requirements:

1. **Claude CLI** — Detects whether `claude` is installed and healthy
2. **Accessibility** — Needed for the global ⌘⇧C hotkey
3. **Calendar** — Permission to create events in your calendars

The wizard reappears automatically if any requirement becomes unmet (e.g., CLI uninstalled, accessibility revoked).

## Usage

1. Press **⌘⇧C** (or use the menubar menu) to open the panel
2. Type a natural language event description
3. Optionally click **Capture Screenshot** to include an image
4. Press **⌘↵** or click **Send**
5. Review the parsed event and click **Create**
6. Press **Escape** to dismiss

## Troubleshooting

- **"Claude CLI auth error"** — Run `claude` in Terminal to re-authenticate
- **"No writable calendar found"** — Open Calendar.app and create a calendar
- **Accessibility not detected** — Remove and re-add CalClaude in System Settings > Privacy & Security > Accessibility
- **Request hanging** — Click the Cancel button, or check your network connection

## Project Structure

| File | Purpose |
|------|---------|
| `CalClaudeApp.swift` | App entry, MenuBarExtra, NSApplicationDelegateAdaptor |
| `AppDelegate.swift` | Panel lifecycle, hotkey registration, onboarding, Claude/event orchestration |
| `FloatingPanel.swift` | NSPanel subclass (Spotlight-style floating window) |
| `HotKeyManager.swift` | Carbon global hotkey (⌘⇧C) |
| `InputPanelView.swift` | Text field, screenshot capture, send/cancel buttons |
| `AccessibilityRequiredView.swift` | PanelRootView + accessibility permission screen |
| `ClaudeCLIService.swift` | Runs Claude CLI with timeout, cancellation, and stderr surfacing |
| `CLICheck.swift` | Detects Claude CLI availability and health |
| `CalendarService.swift` | EventKit integration — calendar access and event creation |
| `CalendarEventPayload.swift` | Event payload model and JSON validation |
| `PanelState.swift` | Observable UI state (loading, errors, pending events) |
| `OnboardingState.swift` | Onboarding requirement tracking |
| `OnboardingView.swift` | Three-step onboarding wizard UI |
| `OnboardingWindowController.swift` | NSWindow management for onboarding |
| `SettingsView.swift` | Custom system prompt configuration |
| `Info.plist` | LSUIElement=true (menubar-only, no Dock icon) |
