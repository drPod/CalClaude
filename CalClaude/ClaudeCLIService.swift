import Foundation

final class ClaudeCLIService {
    static let shared = ClaudeCLIService()

    private var currentProcess: Process?
    private var currentTask: Task<Result<Data, String>, Never>?
    private let timeoutSeconds: UInt64 = 30

    private let jsonInstruction = """
    Respond with only a valid JSON object with these exact keys: title (string), date (YYYY-MM-DD), time (HH:mm), duration (integer, minutes), calendar (string). No other text or markdown.
    """

    private init() {}

    /// Builds the full system prompt: fixed JSON instruction plus user's stored prompt.
    func buildSystemPrompt() -> String {
        let custom = CalClaudeDefaults.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if custom.isEmpty {
            return jsonInstruction
        }
        return jsonInstruction + "\n\n" + custom
    }

    /// Cancels any running Claude process and its associated task.
    func cancel() {
        currentProcess?.terminate()
        currentProcess = nil
        currentTask?.cancel()
        currentTask = nil
    }

    /// Runs the Claude CLI with the given prompt, captures stdout, and returns JSON data.
    /// Includes a 30-second timeout, cancellation support, and stderr surfacing.
    func runClaude(prompt: String, screenshotPath: String?) async -> Result<Data, String> {
        cancel()

        var userMessage = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let path = screenshotPath, !path.isEmpty {
            userMessage += " (Screenshot saved at: \(path) — please read and consider it.)"
        }
        guard !userMessage.isEmpty else {
            return .failure("Please enter a message or attach a screenshot.")
        }

        let systemPrompt = buildSystemPrompt()

        let task = Task<Result<Data, String>, Never> {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "claude", "-p",
                "--output-format", "json",
                "--append-system-prompt", systemPrompt,
                userMessage
            ]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = nil

            await MainActor.run { self.currentProcess = process }

            // Read pipe data concurrently, then wait for process exit.
            // This avoids reading inside terminationHandler, which causes
            // "XPC connection was invalidated" when the pipe's XPC backing
            // is torn down before readDataToEndOfFile() is called.
            let result: Result<Data, String> = await withTaskCancellationHandler {
                do {
                    try process.run()
                } catch {
                    return .failure("Could not run Claude CLI: \(error.localizedDescription)")
                }

                // Collect stdout and stderr on background threads before the
                // process file handles are invalidated.
                let stdoutData: Data = await withCheckedContinuation { continuation in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    DispatchQueue.global(qos: .userInitiated).async {
                        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        continuation.resume(returning: data)
                    }
                }
                let stderrData: Data = await withCheckedContinuation { continuation in
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    DispatchQueue.global(qos: .userInitiated).async {
                        let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        continuation.resume(returning: data)
                    }
                }

                // Wait for the process to finish.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if process.isRunning {
                        process.terminationHandler = { _ in
                            continuation.resume()
                        }
                    } else {
                        continuation.resume()
                    }
                }

                guard process.terminationStatus == 0 else {
                    let stderr = String(data: stderrData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !stderr.isEmpty {
                        let authPatterns = ["auth", "API key", "token", "login", "expired"]
                        if authPatterns.contains(where: { stderr.localizedCaseInsensitiveContains($0) }) {
                            return .failure(
                                "Claude CLI returned an error: \(stderr.components(separatedBy: .newlines).first ?? stderr). Try running 'claude' in Terminal to re-authenticate."
                            )
                        }
                        let trimmed = stderr.count > 200 ? String(stderr.prefix(200)) + "…" : stderr
                        return .failure("Claude CLI error: \(trimmed)")
                    }
                    return .failure("Claude CLI exited with code \(process.terminationStatus).")
                }

                guard let json = Self.extractEventJSON(from: stdoutData) else {
                    return .failure("Could not parse Claude response as event JSON.")
                }
                return .success(json)
            } onCancel: {
                process.terminate()
            }

            await MainActor.run { self.currentProcess = nil }
            return result
        }

        currentTask = task

        // Race against timeout
        return await withTaskGroup(of: Result<Data, String>.self) { group in
            group.addTask {
                await task.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: self.timeoutSeconds * 1_000_000_000)
                if !task.isCancelled {
                    task.cancel()
                }
                return .failure("Request timed out after \(self.timeoutSeconds) seconds.")
            }

            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// Extracts event JSON from CLI --output-format json response (array with assistant message) or raw object.
    private static func extractEventJSON(from data: Data) -> Data? {
        guard let top = try? JSONSerialization.jsonObject(with: data) else { return nil }

        if let array = top as? [Any], let assistant = array.first(where: { item in
            guard let obj = item as? [String: Any],
                  (obj["role"] as? String) == "assistant",
                  (obj["type"] as? String) == "message" else { return false }
            return true
        }) as? [String: Any], let content = assistant["content"] as? [[String: Any]] {
            for block in content {
                if (block["type"] as? String) == "text", let text = block["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let d = trimmed.data(using: .utf8), (try? JSONSerialization.jsonObject(with: d)) != nil {
                        return d
                    }
                }
            }
        }

        if let obj = top as? [String: Any],
           obj["title"] != nil, obj["date"] != nil, obj["time"] != nil, obj["duration"] != nil, obj["calendar"] != nil,
           let out = try? JSONSerialization.data(withJSONObject: obj) {
            return out
        }

        return nil
    }
}
