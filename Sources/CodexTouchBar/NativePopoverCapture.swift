import AppKit
import ScreenCaptureKit

/// Captures only this diagnostic process's window, including the native arrow.
@MainActor
enum NativePopoverCapture {
    static func capture(_ window: NSWindow, to url: URL) async throws {
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
