import AppKit

@MainActor
enum MenuBarTPSDiagnostics {
    static func sample(rate: Double? = 49, fiveHourRemaining: Int = 78, weeklyRemaining: Int = 36) -> StatusUsageReadoutView {
        let view = StatusUsageReadoutView()
        view.update(fiveHour: .init(kind: .fiveHour, usedPercent: 100 - fiveHourRemaining, durationMinutes: 300, resetsAt: nil),
                    weekly: .init(kind: .weekly, usedPercent: 100 - weeklyRemaining, durationMinutes: 10_080, resetsAt: nil))
        view.updateSessionTPS(.init(phase: .completed, tokensPerSecond: rate, detail: "合成样本"), enabled: true)
        return view
    }
    static func run(folder: URL) throws {
        let check = UsageMonitoringDiagnostics.check
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let view = sample()
        let host = NSView(frame: .init(x: 0, y: 0, width: 170, height: 36))
        let window = NSWindow(contentRect: host.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; host.addSubview(view)
        NSLayoutConstraint.activate([view.centerXAnchor.constraint(equalTo: host.centerXAnchor), view.centerYAnchor.constraint(equalTo: host.centerYAnchor)])
        host.layoutSubtreeIfNeeded()
        let fields = view.subviews.compactMap { $0 as? NSTextField }
        let rate = fields.first { $0.accessibilityIdentifier() == "sessionTPS.menuBar.rate" }!
        let unit = fields.first { $0.accessibilityIdentifier() == "sessionTPS.menuBar.unit" }!
        let h = fields.first { $0.stringValue == "H" }!, w = fields.first { $0.stringValue == "W" }!
        try check(fields.allSatisfy { $0.font == NSFont.systemFont(ofSize: 9, weight: .semibold) }, "all menu-bar text uses the standard macOS system font")
        try check(rate.stringValue == "⚡️49" && unit.stringValue == "tok/s", "menu bar splits requested lightning speed and unit into two rows")
        try check(abs(h.frame.minX - w.frame.minX) < 0.1 && abs(h.frame.width - w.frame.width) < 0.1, "H and W share the same aligned column")
        try check(rate.frame.midY > unit.frame.midY && abs(rate.frame.maxX - unit.frame.maxX) < 0.1, "speed and unit align at their trailing edge")
        try check(view.hitTest(.init(x: 2, y: 2)) == nil, "readout preserves status-button click handling")
        try check(!view.subviews.contains { $0 is NSImageView }, "menu-bar icon is removed")
        func alignment(_ field: NSTextField) -> NSRect { view.convert(field.alignmentRect(forFrame: field.frame), from: field.superview) }
        func glyphWidth(_ field: NSTextField) -> CGFloat { (field.stringValue as NSString).size(withAttributes: [.font: field.font!]).width }
        let percent = fields.first { $0.stringValue == "78%" }!
        let gap = alignment(percent).minX - alignment(h).maxX
        try check(gap >= 1 && gap <= 2.1, "H/W to percentage gap is compact")
        try check(alignment(percent).width - ceil(glyphWidth(percent)) <= 1, "two-digit quota does not reserve a three-digit percentage")
        try check(view.menuItemWidth <= 75, "49 tok/s and 78/36 percent fit a compact status item")
        try check(alignment(rate).width - max(glyphWidth(rate), glyphWidth(unit)) <= 1,
                  "reported two-digit layout stays compact with system font")
        view.updateSessionTPS(.init(phase: .completed, tokensPerSecond: 49), enabled: true)
        let twoDigitWidth = view.menuItemWidth
        for rate in [11.0, 49, 88, 98] {
            view.updateSessionTPS(.init(phase: .completed, tokensPerSecond: rate), enabled: true)
            try check(view.menuItemWidth == twoDigitWidth, "proportional system digits do not jitter menu-bar width")
        }
        for value in [1.0, 49, 100, 243, 999, 100000, nil] {
            view.updateSessionTPS(.init(phase: .completed, tokensPerSecond: value), enabled: true)
            host.layoutSubtreeIfNeeded()
            let widestLine = max(glyphWidth(rate), glyphWidth(unit))
            let column = alignment(rate).width
            try check(column >= widestLine, "system-font speed and unit fit without clipping")
            try check(view.bounds.insetBy(dx: -1, dy: -1).contains(alignment(rate)), "rate fits the status item")
        }
        view.update(fiveHour: .init(kind: .fiveHour, usedPercent: 0, durationMinutes: 300, resetsAt: nil),
                    weekly: .init(kind: .weekly, usedPercent: 99, durationMinutes: 10_080, resetsAt: nil))
        host.layoutSubtreeIfNeeded()
        let maximumQuota = fields.filter { $0.stringValue == "100%" }
        try check(maximumQuota.count == 1 && maximumQuota.allSatisfy { glyphWidth($0) <= alignment($0).width }, "100 percent remains fully visible")
        view.update(fiveHour: .init(kind: .fiveHour, usedPercent: 22, durationMinutes: 300, resetsAt: nil),
                    weekly: .init(kind: .weekly, usedPercent: 64, durationMinutes: 10_080, resetsAt: nil))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: appearance)
            host.wantsLayer = true
            host.layer?.backgroundColor = (appearance == .aqua ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.12, alpha: 1)).cgColor
            view.updateSessionTPS(.init(phase: .completed, tokensPerSecond: 49), enabled: true)
            try UIDiagnosticSupport.render(host, to: folder.appendingPathComponent("menubar-tps-\(appearance.rawValue).png"))
            let enabledWidth = view.menuItemWidth
            view.updateSessionTPS(.init(), enabled: false)
            try check(view.menuItemWidth < enabledWidth && rate.isHidden && unit.isHidden, "disabled TPS leaves compact H/W quotas")
            try UIDiagnosticSupport.render(host, to: folder.appendingPathComponent("menubar-quota-\(appearance.rawValue).png"))
        }
        window.close()
        print("Menu bar TPS self-test passed (two rows, H/W alignment, no icon, compact widths, same-digit stability, missing/range values, disabled state, appearances)")
    }
    static func preview(folder: URL) async -> Bool {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let view = sample()
            item.length = view.menuItemWidth
            guard let button = item.button else { return false }
            button.image = nil; button.title = ""; button.addSubview(view)
            NSLayoutConstraint.activate([view.centerXAnchor.constraint(equalTo: button.centerXAnchor), view.centerYAnchor.constraint(equalTo: button.centerYAnchor)])
            try await Task.sleep(for: .milliseconds(500))
            if let window = button.window {
                let metadata = ["windowID": window.windowNumber, "pid": Int(ProcessInfo.processInfo.processIdentifier)]
                try JSONSerialization.data(withJSONObject: metadata).write(to: folder.appendingPathComponent("preview-window.json"))
            }
            try UIDiagnosticSupport.render(button, to: folder.appendingPathComponent("native-button.png"))
            print("Menu bar TPS preview ready (synthetic 49 tok/s and 78% / 36% quotas).")
            fflush(stdout)
            try await Task.sleep(for: .seconds(30))
            return true
        } catch { print("Menu bar TPS preview failed: \(error)"); return false }
    }
}
