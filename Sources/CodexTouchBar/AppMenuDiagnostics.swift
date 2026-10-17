import AppKit

enum AppMenuChecks {
    static func run() -> Bool {
        do {
            let check = UsageMonitoringDiagnostics.check
            try check(AppVersion("v2.10.0")! > AppVersion("2.9.9")! && AppVersion("2.2.10")! > AppVersion("2.2.9")!, "numeric version ordering")
            try check(AppVersion("2.2") == AppVersion("2.2.0"), "short bundle versions normalize")
            for text in ["", "v", "2..1", "-2.1.0", "2.3.0-beta", "2.3.0/evil", "2.3.0.1", "２.３.０", "99999999999999999"] {
                try check(AppVersion(text) == nil, "malformed or prerelease versions are rejected")
            }
            let release = try AppReleaseClient.decode(Data(#"{"tag_name":"v2.3.0","draft":false,"prerelease":false,"html_url":"https://example.com/evil"}"#.utf8), status: 200)
            try check(release.compare(to: "2.2.1") == .newer && release.compare(to: "2.3.0") == .same
                      && release.compare(to: "3.0.0") == .older && release.compare(to: "开发构建") == .unknown, "new, same, ahead and unknown builds")
            try check(release.page.absoluteString == "https://github.com/NUMS-half/Codex-TouchBar/releases/tag/v2.3.0", "remote links cannot redirect the download button")
            for body in [#"{"tag_name":"v2.3.0","draft":true,"prerelease":false}"#,
                         #"{"tag_name":"v2.3.0","draft":false,"prerelease":true}"#,
                         #"{"tag_name":"v2.3.0"}"#, "invalid json"] {
                do { _ = try AppReleaseClient.decode(Data(body.utf8), status: 200); throw UsageMonitoringDiagnostics.CheckFailure(message: "invalid release accepted") }
                catch is AppUpdateError { }
            }
            for status in [403, 404, 429, 500] {
                do { _ = try AppReleaseClient.decode(Data(), status: status); throw UsageMonitoringDiagnostics.CheckFailure(message: "HTTP failure accepted") }
                catch is AppUpdateError { }
            }
            do { _ = try AppReleaseClient.decode(Data(repeating: 32, count: 1_048_577), status: 200); throw UsageMonitoringDiagnostics.CheckFailure(message: "oversized response accepted") }
            catch is AppUpdateError { }
            print("App menu self-test passed (numeric versions, official releases, response errors, trusted links)")
            return true
        } catch { print("App menu self-test failed: \(error)"); return false }
    }
}

@MainActor
enum AppMenuUIDiagnostics {
    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }
    private actor Gate {
        var pending: [CheckedContinuation<AppRelease, Never>?] = []
        var count: Int { pending.count }
        func next() async -> AppRelease { await withCheckedContinuation { pending.append($0) } }
        func finish(_ index: Int, with release: AppRelease) { pending[index]?.resume(returning: release); pending[index] = nil }
    }
    static func run(folder: URL) async -> Bool {
        let check = UsageMonitoringDiagnostics.check
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var opened: [URL] = []
            let info = AppBuildInfo(version: "2.2.1", build: "10")
            let release = AppRelease(tag: "v2.3.0", version: AppVersion("2.3.0")!)
            let menu = AppMenuController(info: info, fetch: { release }, openURL: { opened.append($0) })
            var refreshed = 0, history = 0, settings = 0, quit = 0
            menu.onRefresh = { refreshed += 1 }; menu.onHistory = { history += 1 }
            menu.onSettings = { settings += 1 }; menu.onQuit = { quit += 1 }
            let items = menu.makeMenu().items
            try check(items.filter(\.isSeparatorItem).count == 3 && items.filter { !$0.isSeparatorItem }.count == 8, "grouped native menu entries")
            for item in items where !item.isSeparatorItem {
                try check(item.target != nil && item.action != nil, "every menu item has an action")
                if item.title == "检查更新…" || item.title.hasPrefix("关于") { continue }
                NSApp.sendAction(item.action!, to: item.target, from: item)
            }
            try check(refreshed == 1 && history == 1 && settings == 1 && quit == 1, "existing menu actions remain connected")
            try check(opened == [AppProject.help, AppProject.issues], "help and feedback use fixed public destinations")
            let about = AppAboutWindowController(info: info, openURL: { opened.append($0) })
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                about.window!.appearance = NSAppearance(named: appearance)
                let content = about.window!.contentView!
                try UIDiagnosticSupport.render(content, to: folder.appendingPathComponent("about-\(appearance.rawValue).png"))
                try controlsFit(content)
            }
            let homepage = UIDiagnosticSupport.descendants(about.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "项目主页" }!
            homepage.performClick(nil)
            try check(opened.last == AppProject.repository, "about opens the project homepage through its button")
            for (name, current, expected) in [("new", "2.2.1", AppUpdateWindowController.State.available),
                ("current", "2.3.0", .current), ("ahead", "3.0.0", .ahead), ("unknown", "开发构建", .unknown)] {
                let controller = AppUpdateWindowController(info: .init(version: current, build: "10"), fetch: { release }, openURL: { opened.append($0) })
                controller.check(); await controller.waitForCheck()
                try check(controller.state == expected, "version comparison reaches the correct UI state")
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    controller.window!.appearance = NSAppearance(named: appearance)
                    let content = controller.window!.contentView!
                    try UIDiagnosticSupport.render(content, to: folder.appendingPathComponent("update-\(name)-\(appearance.rawValue).png"))
                    try controlsFit(content)
                }
                let download = UIDiagnosticSupport.descendants(controller.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.title.contains("发布页面") || $0.title == "查看更新并下载" }!
                download.performClick(nil)
                try check(opened.last == release.page, "release action uses the verified project tag")
            }
            let failed = AppUpdateWindowController(info: info, fetch: { throw AppUpdateError.rateLimited }, openURL: { opened.append($0) })
            failed.check(); await failed.waitForCheck()
            try check(failed.state == .failed, "network/rate errors do not claim the app is up to date")
            try UIDiagnosticSupport.render(failed.window!.contentView!, to: folder.appendingPathComponent("update-error.png"))
            let fallback = UIDiagnosticSupport.descendants(failed.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "打开发布页面" }!
            fallback.performClick(nil)
            try check(opened.last == AppProject.releases, "failed check still offers the public release page")
            let calls = Counter()
            let pending = AppUpdateWindowController(info: info, fetch: {
                await calls.increment()
                // Deliberately ignore cancellation to exercise the late-result guard.
                try? await Task.sleep(for: .milliseconds(100))
                return release
            }, openURL: { _ in })
            pending.check(); pending.check()
            try check(pending.state == .checking, "checking state is immediate")
            try await Task.sleep(for: .milliseconds(20))
            pending.window!.close()
            try await Task.sleep(for: .milliseconds(120))
            let count = await calls.value
            try check(count == 1 && pending.state == .idle, "duplicate checks are coalesced and closed windows reject late results")
            pending.check(); await pending.waitForCheck()
            try check(pending.state == .available, "a cancelled window can check again")
            let gate = Gate()
            let racing = AppUpdateWindowController(info: info, fetch: { await gate.next() }, openURL: { _ in })
            racing.check()
            for _ in 0..<100 { if await gate.count == 1 { break }; await Task.yield() }
            let firstCount = await gate.count
            try check(firstCount == 1, "first request entered the transport")
            racing.window!.close(); racing.check()
            for _ in 0..<100 { if await gate.count == 2 { break }; await Task.yield() }
            let secondCount = await gate.count
            try check(secondCount == 2, "reopened window starts a new request while old request is pending")
            await gate.finish(1, with: release); await racing.waitForCheck()
            await gate.finish(0, with: AppRelease(tag: "v2.0.0", version: AppVersion("2.0.0")!))
            for _ in 0..<10 { await Task.yield() }
            try check(racing.state == .available, "late response from old window cannot replace the newer result")
            print("App menu UI self-test passed (actions, about, update states, errors, cancellation, light/dark)")
            return true
        } catch { print("App menu UI self-test failed: \(error)"); return false }
    }
    private static func controlsFit(_ root: NSView) throws {
        for control in UIDiagnosticSupport.descendants(root).compactMap({ $0 as? NSControl }) where !control.isHiddenOrHasHiddenAncestor {
            let rect = root.convert(control.alignmentRect(forFrame: control.frame), from: control.superview)
            try UsageMonitoringDiagnostics.check(root.bounds.insetBy(dx: -1, dy: -1).contains(rect), "about/update controls fit the window")
        }
    }
}
