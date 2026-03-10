import Foundation

/// Writes NDJSON to the debug session log for instrumentation. Remove after debugging.
enum DebugLog {
    static let path = "/Users/darshpoddar/Coding/CalClaude/.cursor/debug-17b4a3.log"

    static func log(location: String, message: String, hypothesisId: String, data: [String: Any]? = nil) {
        var payload: [String: Any] = [
            "sessionId": "17b4a3",
            "location": location,
            "message": message,
            "hypothesisId": hypothesisId,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]
        if let d = data { d.forEach { payload[$0.key] = $0.value } }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: jsonData, encoding: .utf8).map({ $0 + "\n" }),
              let lineData = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: nil)
        }
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(lineData)
    }
}
