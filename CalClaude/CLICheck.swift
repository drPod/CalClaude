import Foundation

enum CLICheck {
    /// Runs `which claude` and checks exit code 0.
    static var isAvailable: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "which claude"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Runs `claude --version`, returns the version string on success or nil.
    static var versionString: String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "claude --version"]
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "claude --version"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
            // Drain both pipes before wait to avoid full buffers blocking the child (and XPC invalidation).
            let group = DispatchGroup()
            var stdoutData = Data()
            var stderrData = Data()
            group.enter()
            DispatchQueue.global().async {
                stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            process.waitUntilExit()
            group.wait()
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
