import AppKit

@MainActor
enum MenuPanelAppearanceUIDiagnostics {
    static func run(folder: URL) throws {
        let check = UsageMonitoringDiagnostics.check
        let panel = PanelController()
        let now = Date()
        panel.update(snapshot: UsageSnapshot(
            fiveHour: .init(kind: .fiveHour, usedPercent: 42, durationMinutes: 300, resetsAt: now.addingTimeInterval(3_600)),
            weekly: .init(kind: .weekly, usedPercent: 64, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400)),
            planType: "plus", limitName: nil, creditBalance: "0", unlimitedCredits: false,
            availableResetCredits: 2, fetchedAt: now), freshness: .live, error: nil, isRefreshing: false)
        let overview = panel.makeContentView()
        overview.frame = NSRect(origin: .zero, size: overview.fittingSize)
        let host = NSWindow(contentRect: overview.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        host.contentView = overview
        let card = UIDiagnosticSupport.descendants(overview).compactMap { $0 as? QuotaCardView }.first!
        let chart = UsageChartView(frame: NSRect(x: 0, y: 0, width: 576, height: 240))
        try check(!overview.isOpaque && !(overview is NSVisualEffectView) && !chart.isOpaque,
                  "popover alone supplies the background without opaque or duplicate material layers")
        let chartHost = NSWindow(contentRect: chart.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        chartHost.contentView = chart
        func pixel(_ view: NSView, _ name: String) throws -> NSColor {
            let url = folder.appendingPathComponent(name + ".png")
            try UIDiagnosticSupport.render(view, to: url)
            guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url)),
                  let color = bitmap.colorAt(x: 8, y: 20)?.usingColorSpace(.sRGB) else {
                throw UIDiagnosticSupport.RenderError.bitmapUnavailable
            }
            return color
        }
        func difference(_ a: NSColor, _ b: NSColor) -> CGFloat {
            max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                abs(a.blueComponent - b.blueComponent), abs(a.alphaComponent - b.alphaComponent))
        }
        // Revisit light appearance to catch CGColor layers that stay stuck in dark mode.
        var firstLight: NSColor?
        for appearance in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            host.appearance = NSAppearance(named: appearance); chartHost.appearance = NSAppearance(named: appearance)
            _ = try pixel(overview, "menu-surface-\(appearance.rawValue)")
            let plot = try pixel(chart, "chart-surface-\(appearance.rawValue)")
            let raised = try pixel(card, "quota-card-\(appearance.rawValue)")
            try check(plot.alphaComponent > 0.01 && plot.alphaComponent < 0.25
                      && raised.alphaComponent > 0.01 && raised.alphaComponent < 0.25,
                      "plot and quota cards both tint the native material with translucent surfaces")
            try check(difference(plot, raised) < 0.01, "plot and quota cards share the same translucent tint")
            if appearance == .darkAqua {
                try check(raised.alphaComponent > 0.09 && raised.alphaComponent < 0.20,
                          "dark surface only slightly deepens the native material")
                try check(firstLight.map { difference($0, raised) > 0.04 } == true,
                          "surface tint adapts between light and dark")
            } else if let firstLight {
                try check(difference(firstLight, raised) < 0.01,
                          "returning to light restores the original card color")
            } else {
                firstLight = raised
            }
        }
        print("Menu panel appearance self-test passed (native material, matching translucent insets, light/dark/light)")
    }
}
