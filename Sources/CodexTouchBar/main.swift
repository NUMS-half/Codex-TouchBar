import AppKit

if CommandLine.arguments.contains("--update-check-self-test") {
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                let release = try await AppReleaseClient().latest()
                print("Live update check passed: latest public stable release \(release.tag)")
                exit(0)
            } catch { print("Live update check failed: \(error.localizedDescription)"); exit(1) }
        }
        NSApplication.shared.run()
    }
}

if CommandLine.arguments.contains("--app-menu-self-test") {
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/app-menu-previews")
            exit(await AppMenuUIDiagnostics.run(folder: folder) ? 0 : 1)
        }
        NSApplication.shared.run()
    }
}

if CommandLine.arguments.contains("--panel-motion-self-test") {
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            let outputIndex = CommandLine.arguments.firstIndex(of: "--panel-motion-output")
            let outputPath = outputIndex.flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
            let folder = outputPath.map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/panel-motion")
            exit(await PanelMotionDiagnostics.run(folder: folder) ? 0 : 1)
        }
        NSApplication.shared.run()
    }
}

if CommandLine.arguments.contains("--notification-self-test") {
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                let sent = try await UsageNotificationService().sendTestNotification()
                print(sent ? "Test notification submitted to macOS; banner visibility depends on system settings." : "Notification acceptance skipped: enable notification permission in the app first. No permission or preference changed.")
                exit(sent ? 0 : 2)
            } catch { print("Test notification failed: \(error.localizedDescription)"); exit(1) }
        }
        NSApplication.shared.run()
    }
}

if CommandLine.arguments.contains("--monitoring-ui-self-test") {
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/monitoring-previews")
            exit(await UsageMonitoringUIDiagnostics.run(folder: folder) ? 0 : 1)
        }
        NSApplication.shared.run()
    }
}

if CommandLine.arguments.contains("--settings-self-test") {
    let previewIndex = CommandLine.arguments.firstIndex(of: "--settings-preview")
    let path = previewIndex.flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
    let success = MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        return ButtonSettingsDiagnostics.run(previewPath: path)
    }
    print(success ? "Touch Bar button settings self-test passed" : "Touch Bar button settings self-test failed")
    exit(success ? 0 : 1)
}

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
