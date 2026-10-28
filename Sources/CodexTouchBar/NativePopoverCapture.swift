import AppKit
import ScreenCaptureKit

/// Captures only this diagnostic process's window, including the native arrow.
@MainActor
enum NativePopoverCapture {
    static func capture(_ window: NSWindow, to url: URL) async throws {
        // Explicit diagnostic alternative for desktops where ScreenCaptureKit does not return.
        // Use the actual window frame view. Compositor-only chrome/material can be absent;
        // this mode verifies geometry, not the final screen-composited arrow appearance.
        if CommandLine.arguments.contains("--native-frame-render") {
            guard let frame = window.contentView?.superview else {
                throw UsageMonitoringDiagnostics.CheckFailure(message: "native window frame unavailable")
            }
            try UIDiagnosticSupport.render(frame, to: url)
            print("Native frame rendered with AppKit: \(url.lastPathComponent)")
            return
        }
        guard #available(macOS 14.4, *) else {
            print("Native window capture requires macOS 14.4; geometry checks still run")
            return
        }
        let content = try await SCShareableContent.currentProcess
        guard let ownWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw UsageMonitoringDiagnostics.CheckFailure(message: "diagnostic popover unavailable for own-window capture")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * window.backingScaleFactor)
        configuration.height = Int(window.frame.height * window.backingScaleFactor)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: ownWindow), configuration: configuration)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw UIDiagnosticSupport.RenderError.pngUnavailable
        }
        try png.write(to: url)
    }
}
