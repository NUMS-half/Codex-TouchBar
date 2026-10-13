import Foundation

/// Stable identifiers are shared by foreground checks and local persistence.
enum ApplicationIdentity {
    static let bundleIdentifier = "com.wyx.CodexTouchBar"
    static let chatGPTBundleIdentifier = "com.openai.codex"

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }
}
