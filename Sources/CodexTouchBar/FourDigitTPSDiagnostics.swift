import AppKit

/// Verifies the shipping views using synthetic values; never presents hardware.
@MainActor
enum FourDigitTPSDiagnostics {
    static func run(folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rates = [999, 1000, 1111, 8888, 9999, 10000]
        let rowHeight: CGFloat = 52
        let stage = NSView(frame: .init(x: 0, y: 0, width: 280, height: CGFloat(rates.count) * rowHeight + 28))
        stage.wantsLayer = true
        let window = NSWindow(contentRect: stage.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = stage
        defer { window.close() }
        func label(_ title: String, x: CGFloat, y: CGFloat, size: CGFloat = 10) {
            let field = NSTextField(labelWithString: title)
            field.font = .systemFont(ofSize: size); field.textColor = .labelColor
            field.frame = .init(x: x, y: y, width: 100, height: 16)
            stage.addSubview(field)
        }
        label("TPS", x: 8, y: stage.bounds.height - 22)
        label("Menu bar", x: 70, y: stage.bounds.height - 22)
        label("Touch Bar", x: 190, y: stage.bounds.height - 22)
        var views: [(Int, StatusUsageReadoutView, TouchBarActionSlotView, NSButton)] = []
        let slotWidth = TouchBarLayout.actionWidth(for: TouchBarLayout.width)
        for (index, rate) in rates.enumerated() {
            let y = stage.bounds.height - 28 - CGFloat(index + 1) * rowHeight
            label(String(rate), x: 8, y: y + 23)
            let menu = MenuBarTPSDiagnostics.sample(rate: Double(rate), fiveHourRemaining: 100, weeklyRemaining: 100)
            let menuHost = NSView(frame: .init(x: 70, y: y + 20, width: 110, height: 20))
            stage.addSubview(menuHost)
            menuHost.addSubview(menu)
            NSLayoutConstraint.activate([
                menu.leadingAnchor.constraint(equalTo: menuHost.leadingAnchor),
                menu.centerYAnchor.constraint(equalTo: menuHost.centerYAnchor),
            ])
            let background = NSView(frame: .init(x: 188, y: y + 12, width: slotWidth + 4, height: 36))
            background.wantsLayer = true; background.layer?.backgroundColor = NSColor.black.cgColor
            background.appearance = NSAppearance(named: .darkAqua); stage.addSubview(background)
            let slot = TouchBarActionSlotView(frame: .init(x: 2, y: 3, width: slotWidth, height: TouchBarLayout.height))
            background.addSubview(slot)
            slot.update(.init(action: .sessionTPS))
            slot.updateSessionTPS(.init(phase: .completed, tokensPerSecond: Double(rate)))
            slot.layoutSubtreeIfNeeded()
            let button = slot.subviews.compactMap { $0 as? NSButton }.first { !$0.isHidden }!
            views.append((rate, menu, slot, button))
            label(String(format: "%.1f pt", button.font!.pointSize), x: 190, y: y, size: 8)
        }
        stage.layoutSubtreeIfNeeded()
        var metrics: [[String: Any]] = [], failures: [String] = []
        var fourDigitMenuWidth: CGFloat?
        for (rate, menu, slot, button) in views {
            if !stage.bounds.contains(menu.convert(menu.bounds, to: stage)) { failures.append("menu preview outside stage for \(rate)") }
            let rateField = menu.subviews.compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "sessionTPS.menuBar.rate" }!
            let menuWidth = rateField.alignmentRect(forFrame: rateField.frame).width
            let menuTextWidth = (rateField.stringValue as NSString).size(withAttributes: [.font: rateField.font!]).width
            let textWidth = (button.title as NSString).size(withAttributes: [.font: button.font!]).width
            let titleRect = button.cell!.titleRect(forBounds: button.bounds)
            let menuFits = rateField.stringValue == "⚡️\(rate)" && menuTextWidth <= menuWidth + 0.5
            let slotFits = button.title == "⚡ \(rate) tok/s" && textWidth <= titleRect.width + 0.5
            if !menuFits { failures.append("menu bar clips \(rate)") }
            if !slotFits { failures.append("Touch Bar clips \(rate)") }
            if (1000...9999).contains(rate) {
                if let previous = fourDigitMenuWidth, previous != menu.menuItemWidth { failures.append("four-digit menu width changes") }
                fourDigitMenuWidth = menu.menuItemWidth
            }
            metrics.append(["rate": rate, "menuItemWidth": menu.menuItemWidth, "menuFont": rateField.font!.pointSize,
                            "menuTextWidth": menuTextWidth, "menuColumnWidth": menuWidth, "menuFits": menuFits,
                            "touchBarSlotWidth": slot.bounds.width, "touchBarFont": button.font!.pointSize,
                            "touchBarTextWidth": textWidth, "touchBarTitleRectWidth": titleRect.width, "touchBarFits": slotFits])
            print(String(format: "%d: menu %.0fpt, font %.1fpt, fits=%@; Touch Bar font %.1fpt, text %.2f / titleRect %.2fpt, fits=%@",
                         rate, menu.menuItemWidth, rateField.font!.pointSize, String(menuFits), button.font!.pointSize,
                         textWidth, titleRect.width, String(slotFits)))
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            stage.layer?.backgroundColor = (appearance == .aqua ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.12, alpha: 1)).cgColor
            try UIDiagnosticSupport.render(stage, to: folder.appendingPathComponent("four-digit-\(appearance.rawValue).png"))
        }
        try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("metrics.json"))
        try UsageMonitoringDiagnostics.check(failures.isEmpty, failures.joined(separator: "; "))
        print("Four-digit TPS display self-test passed (shipping views, actual NSButton title rectangles, appearances; no physical Touch Bar)")
    }
}
