import AppKit
import ApplicationServices

enum SessionWindowSelection {
    case title(String)
    case temporaryUnavailable
    case unavailable(String)
}

/// Read only the single visible Codex window's title. No AX tree, chat text,
/// activation, screen capture, permission prompt, or modification of Codex.
enum SessionVisibleConversation {
    static func sample() -> SessionWindowSelection {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: ApplicationIdentity.chatGPTBundleIdentifier).first else { return .unavailable("Codex 未运行") }
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).filter {
            guard ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = $0[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect.width >= 320 && rect.height >= 200
        }
        if windows.count > 1 { return .unavailable("多个 Codex 窗口，无法确认当前对话") }
        guard windows.count == 1 else { return .temporaryUnavailable }
        if let title = normalized(windows[0][kCGWindowName as String] as? String) { return .title(title) }
        // macOS may redact other apps' window titles. Reuse Accessibility access
        // if already granted; do not ask for screen recording or expand the AX tree.
        guard AXIsProcessTrusted() else { return .temporaryUnavailable }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &raw) == .success,
              let axWindows = raw as? [AXUIElement], axWindows.count == 1 else { return .temporaryUnavailable }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindows[0], kAXTitleAttribute as CFString, &title) == .success else { return .temporaryUnavailable }
        return normalized(title as? String).map(SessionWindowSelection.title) ?? .temporaryUnavailable
    }
    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 4_096, !["Codex", "ChatGPT"].contains(title) else { return nil }
        return title
    }
    static func requestAccessibilityAccess() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
}
