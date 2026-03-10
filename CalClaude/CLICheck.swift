import Foundation

enum CLICheck {
    /// Resolves the absolute path to the `claude` binary using a login shell,
    /// so the full user PATH (homebrew, npm, etc.) is searched.
    static var resolvedPath: String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "which claude 2>/dev/null"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }

    /// Returns true if the `claude` binary can be found on the user's PATH.
    static var isAvailable: Bool { resolvedPath != nil }

    /// Runs `claude --version`, returns the version string on success or nil.
    static var versionString: String? {
        guard let claudePath = resolvedPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Drain pipe before wait to avoid full buffer blocking the child (and XPC teardown).
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// Runs `claude --version` and inspects exit code and stderr.
    /// Returns nil if healthy, or an error description.
    static var healthCheck: String? {
        guard let claudePath = resolvedPath else {
            return "Claude CLI not found. Make sure it is installed and on your PATH."
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["--version"]
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        do {
            try process.run()
            // Drain stderr before wait to avoid blocking the child.
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return nil }
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if stderr.isEmpty {
                return "Claude CLI exited with code \(process.terminationStatus)."
            }
            let authPatterns = ["auth", "API key", "token", "login", "expired"]
            if authPatterns.contains(where: { stderr.localizedCaseInsensitiveContains($0) }) {
                return "Claude CLI is installed but returned an auth error. Run `claude` in Terminal to re-authenticate."
            }
            let firstLine = stderr.components(separatedBy: .newlines).first ?? stderr
            let trimmed = firstLine.count > 200 ? String(firstLine.prefix(200)) + "…" : firstLine
            return "Claude CLI error: \(trimmed)"
        } catch {
            return "Could not run Claude CLI: \(error.localizedDescription)"
        }
    }

    static let installURL = URL(string: "https://docs.anthropic.com/en/docs/claude-code/overview")!
}
