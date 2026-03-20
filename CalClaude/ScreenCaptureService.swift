import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import VideoToolbox

enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case noWindowFound
    case captureTimeout
    case captureError(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission is required."
        case .noWindowFound:
            return "No eligible window found to capture."
        case .captureTimeout:
            return "Screen capture timed out."
        case .captureError(let error):
            return "Capture failed: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class ScreenCaptureService: ObservableObject {
    static let shared = ScreenCaptureService()

    @Published var capturedImage: NSImage?
    @Published var screenshotPath: String?

    private init() {}

    func captureFrontmostWindow() async throws {
        guard ScreenRecordingPermission.isAuthorized else {
            throw ScreenCaptureError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownBundleID = Bundle.main.bundleIdentifier

        // Get window IDs in front-to-back z-order from CGWindowList
        let frontToBackIDs = Self.windowIDsInZOrder(excludingBundleID: ownBundleID)

        // Build a lookup from SCShareableContent windows
        let scWindowsByID: [CGWindowID: SCWindow] = Dictionary(
            uniqueKeysWithValues: content.windows
                .filter { $0.owningApplication?.bundleIdentifier != ownBundleID }
                .filter { $0.frame.width > 0 && $0.frame.height > 0 }
                .map { ($0.windowID, $0) }
        )

        // Pick the first (frontmost) window that exists in both lists
        let eligibleWindow = frontToBackIDs.lazy.compactMap { scWindowsByID[$0] }.first

        let cgImage: CGImage

        if let window = eligibleWindow {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            cgImage = try await captureWithFilter(filter, width: window.frame.width, height: window.frame.height)
        } else {
            // Fall back to full display capture
            guard let display = content.displays.first else {
                throw ScreenCaptureError.noWindowFound
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            cgImage = try await captureWithFilter(filter, width: display.frame.width, height: display.frame.height)
        }

        // Convert to PNG and save
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            throw ScreenCaptureError.captureError(NSError(domain: "ScreenCaptureService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG data"]))
        }

        // Clean up previous temp file
        if let oldPath = screenshotPath {
            try? FileManager.default.removeItem(atPath: oldPath)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalClaude_screenshot_\(UUID().uuidString.prefix(8)).png")
        try pngData.write(to: tempURL)

        self.capturedImage = nsImage
        self.screenshotPath = tempURL.path
    }

    func clearCapture() {
        if let path = screenshotPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        capturedImage = nil
        screenshotPath = nil
    }

    /// Returns on-screen window IDs in front-to-back z-order, excluding windows from the given bundle ID.
    private static func windowIDsInZOrder(excludingBundleID: String?) -> [CGWindowID] {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] else {
            return []
        }
        return infoList.compactMap { info -> CGWindowID? in
            guard let windowID = info[kCGWindowNumber] as? CGWindowID,
                  let layer = info[kCGWindowLayer] as? Int, layer == 0 else {
                return nil
            }
            if let excludeID = excludingBundleID,
               let ownerBundle = info[kCGWindowOwnerName] as? String {
                // CGWindowList doesn't provide bundle IDs directly, so filter by PID
                if let ownerPID = info[kCGWindowOwnerPID] as? pid_t,
                   let app = NSRunningApplication(processIdentifier: ownerPID),
                   app.bundleIdentifier == excludeID {
                    return nil
                }
            }
            return windowID
        }
    }

    private func captureWithFilter(_ filter: SCContentFilter, width: CGFloat, height: CGFloat) async throws -> CGImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let config = SCStreamConfiguration()
        config.width = Int(width * scale)
        config.height = Int(height * scale)
        config.showsCursor = false

        if #available(macOS 14.0, *) {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } else {
            return try await captureSingleFrame(filter: filter, configuration: config)
        }
    }

    // macOS 13 fallback: use SCStream to grab a single frame
    private func captureSingleFrame(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let output = SingleFrameStreamOutput()
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()

        let image: CGImage
        do {
            image = try await withCheckedThrowingContinuation { continuation in
                output.continuation = continuation

                // Timeout after 5 seconds
                DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
                    output.timeout()
                }
            }
        } catch {
            try? await stream.stopCapture()
            throw error
        }
        try? await stream.stopCapture()
        return image
    }
}

// MARK: - macOS 13 single-frame helper

private final class SingleFrameStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    var continuation: CheckedContinuation<CGImage, Error>?
    private var hasResumed = false
    private let lock = NSLock()

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)

        guard let image = cgImage else { return }
        resume(with: .success(image))
    }

    func timeout() {
        resume(with: .failure(ScreenCaptureError.captureTimeout))
    }

    private func resume(with result: Result<CGImage, Error>) {
        lock.lock()
        guard !hasResumed else {
            lock.unlock()
            return
        }
        hasResumed = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(with: result)
    }
}
