import AppKit

if CommandLine.arguments.contains("--self-test") {
    let success = SelfTest.run()
    print(success ? "CodexTouchBar self-test passed" : "CodexTouchBar self-test failed")
    exit(success ? 0 : 1)
}

// Top-level code in main.swift runs on the main thread, but the compiler
// treats it as nonisolated; assume isolation so we can touch the
// @MainActor-isolated AppDelegate.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // Hold a strong reference: NSApplication.delegate is weak.
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
