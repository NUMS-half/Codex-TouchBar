import AppKit

enum UsageChartPalette {
    static let surface = MenuPanelPalette.card
    static let ink = MenuPanelPalette.adaptive(0x252A34, 0xEAEDF2)
    static let muted = MenuPanelPalette.adaptive(0x697385, 0xA8AFBC)
    static let trace = MenuPanelPalette.adaptive(0x237AD1, 0x67AAF4)
    static let event = MenuPanelPalette.adaptive(0x8B62B4, 0xC4A0E6)
    static func quota(_ value: Int) -> NSColor {
        switch UsageColorBand(remainingPercent: value) {
        case .critical: return MenuPanelPalette.adaptive(0xBD3434, 0xFF807B)
        case .low: return MenuPanelPalette.adaptive(0xA85D00, 0xFFAF61)
        case .moderate: return MenuPanelPalette.adaptive(0x8E6A00, 0xECCC54)
        case .healthy: return MenuPanelPalette.adaptive(0x237C4B, 0x64D998)
        }
    }
}

/// Labels live in a dedicated lane, and merge after clamping to its edges.
/// This tests actual label rectangles rather than assuming point spacing is enough.
enum UsageChartAnnotations {
    struct Label {
        var points: [UsageObservation]
        var rect: NSRect
        var title: String { points.count == 1 ? "刷新" : "刷新 × \(points.count)" }
    }
    static func layout(_ points: [UsageObservation], start: Date, duration: TimeInterval, plot: NSRect) -> [Label] {
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        func x(_ point: UsageObservation) -> CGFloat { plot.minX + CGFloat(point.time.timeIntervalSince(start) / duration) * plot.width }
        func label(_ points: [UsageObservation]) -> Label {
            let title = points.count == 1 ? "刷新" : "刷新 × \(points.count)"
            let width = ceil((title as NSString).size(withAttributes: [.font: font]).width) + 18
            let center = points.map(x).reduce(0, +) / CGFloat(points.count)
            let left = max(plot.minX, min(center - width / 2, plot.maxX - width))
            return Label(points: points, rect: NSRect(x: left, y: plot.maxY + 13, width: width, height: 21))
        }
        var labels: [Label] = []
        for point in points where point.rise {
            var current = label([point])
            while let previous = labels.last, previous.rect.insetBy(dx: -8, dy: 0).intersects(current.rect) {
                labels.removeLast()
                current = label(previous.points + current.points)
            }
            labels.append(current)
        }
        return labels
    }
}

final class UsageChartLegendView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 324, height: 18) }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let labels = ["末次剩余", "采样空档", "额度刷新"]
        setAccessibilityLabel("柱高为剩余额度，淡色虚线顶为非实测填补，紫色标记为额度刷新后首次观测")
        for (index, label) in labels.enumerated() {
            let x = CGFloat(index) * 108
            let path = NSBezierPath(); path.lineWidth = 1.6
            if index == 2 {
                UsageChartPalette.event.setFill()
                NSBezierPath(ovalIn: NSRect(x: x + 8, y: 6, width: 5, height: 5)).fill()
            } else {
                if index == 0 {
                    UsageChartPalette.muted.withAlphaComponent(0.7).setFill()
                    NSBezierPath(roundedRect: NSRect(x: x + 6, y: 3, width: 8, height: 11), xRadius: 2, yRadius: 2).fill()
                } else {
                    UsageChartPalette.muted.setStroke()
                    let dash: [CGFloat] = [2, 2]; path.setLineDash(dash, count: 2, phase: 0)
                    path.move(to: NSPoint(x: x + 3, y: 9)); path.line(to: NSPoint(x: x + 20, y: 9)); path.stroke()
                }
            }
            (label as NSString).draw(at: NSPoint(x: x + 27, y: 2), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: UsageChartPalette.muted])
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

final class UsageChartView: NSView {
    var points: [UsageObservation] = [] { didSet { invalidateSeries() } }
    var range = UsageChartRange.sixHours { didSet { invalidateSeries() } }
    var kind: UsageWindowKind {
        get { range.kind }
        set { if range.kind != newValue { range = .defaultRange(for: newValue) } }
    }
    var end = Date() { didSet { invalidateSeries() } }
    private var hovered: UsageObservation?
    private var hoverCount: Int?
    private var hoveredBucket: UsageChartBucket?
    private var bucketCache: [UsageChartBucket]?
    private var tracking: NSTrackingArea?
    private var plot: NSRect { NSRect(x: 50, y: 37, width: max(0, bounds.width - 70), height: max(0, bounds.height - 89)) }
    private var start: Date { end.addingTimeInterval(-range.duration) }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        updateAccessibility()
    }
    required init?(coder: NSCoder) { nil }
    private func updateAccessibility() {
        setAccessibilityLabel("剩余额度柱状图；实测柱高为末次查询剩余，淡色填补采样空档，跨刷新沿用前值，非实测不参与提醒，0%显示底线")
    }
    private func clearHover() { hovered = nil; hoverCount = nil; hoveredBucket = nil; setAccessibilityHelp(nil) }
    private func invalidateSeries() { clearHover(); bucketCache = nil; needsDisplay = true }
    private func buckets() -> [UsageChartBucket] {
        if let bucketCache { return bucketCache }
        let result = UsageChartBucket.make(points, range: range, start: start, end: end)
        bucketCache = result
        return result
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    func updateHover(at location: NSPoint) {
        defer {
            if let hovered {
                var description = "\(kind.accessibleTitle)，剩余\(hovered.remaining)%，查询于\(formatResetDate(hovered.time))"
                if let bucket = hoveredBucket {
                    if bucket.isEstimated {
                        description = bucket.estimateKind == .lastKnown
                            ? "沿用前次剩余\(bucket.remaining)%，采样空档，刷新时刻未观测，非实测"
                            : "估计剩余\(bucket.remaining)%，同一周期下降区间估计，非实测"
                    }
                    else { description += "，记录范围\(bucket.minimum)%至\(bucket.maximum)%，\(bucket.count)条记录" }
                }
                if hoverCount != nil { description += "，额度刷新后首次观测" }
                setAccessibilityHelp(description)
            }
        }
        clearHover()
        let visible = points.filter { $0.time >= start && $0.time <= end }
        let labels = UsageChartAnnotations.layout(visible, start: start, duration: range.duration, plot: plot)
        if let label = labels.first(where: { $0.rect.contains(location) }) {
            hovered = label.points.last; hoverCount = label.points.count; needsDisplay = true; return
        }
        guard plot.contains(location) else { needsDisplay = true; return }
        let time = start.addingTimeInterval(Double((location.x - plot.minX) / plot.width) * range.duration)
        hoveredBucket = buckets().first { $0.start <= time && time < $0.end }
        if location.x >= plot.maxX - 2, let last = buckets().last, last.last.time == end { hoveredBucket = last }
        hovered = hoveredBucket?.last
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { clearHover(); needsDisplay = true }
    private func position(_ point: UsageObservation) -> NSPoint {
        NSPoint(x: plot.minX + CGFloat(point.time.timeIntervalSince(start) / range.duration) * plot.width,
                y: plot.minY + CGFloat(point.remaining) / 100 * plot.height)
    }
    private func text(_ value: String, at position: NSPoint, color: NSColor = UsageChartPalette.muted, size: CGFloat = 10, weight: NSFont.Weight = .regular) {
        (value as NSString).draw(at: position, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }
    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        MenuPanelPalette.inset.setFill(); card.fill()
        MenuPanelPalette.border.setStroke(); card.stroke()
        guard plot.width > 0, plot.height > 0 else { return }
        for value in stride(from: 0, through: 100, by: 25) {
            let y = plot.minY + CGFloat(value) / 100 * plot.height
            UsageChartPalette.muted.withAlphaComponent(value == 0 ? 0.22 : 0.11).setStroke()
            let line = NSBezierPath(); line.lineWidth = 0.5
            line.move(to: NSPoint(x: plot.minX, y: y)); line.line(to: NSPoint(x: plot.maxX, y: y)); line.stroke()
            let label = "\(value)%"
            let width = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width
            text(label, at: NSPoint(x: plot.minX - width - 12, y: y - 6))
        }
        let formatter = DateFormatter(); formatter.dateFormat = kind == .weekly ? "MM/dd" : (range.duration <= 86_400 ? "HH:mm" : "MM/dd HH:mm")
        for index in 0...4 {
            let fraction = Double(index) / 4
            let label = formatter.string(from: start.addingTimeInterval(range.duration * fraction))
            let width = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width
            let x = max(8, min(plot.minX + plot.width * fraction - width / 2, bounds.maxX - width - 8))
            text(label, at: NSPoint(x: x, y: 13))
        }
        let visible = points.filter { $0.time >= start && $0.time <= end }
        guard !visible.isEmpty else {
            let hasEarlierHistory = points.contains { $0.kind == kind && $0.time < start }
            let heading = hasEarlierHistory ? "当前范围内没有记录" : "还没有额度记录"
            let width = (heading as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium)]).width
            text(heading, at: NSPoint(x: plot.midX - width / 2, y: plot.midY + 9), color: UsageChartPalette.ink, size: 15, weight: .medium)
            let hint = hasEarlierHistory ? (range == .sixHours ? "可切换至近12小时查看更早记录。" : "可在菜单栏刷新额度，记录新的变化。") : "首次成功查询后自动记录，可在菜单栏点击刷新。"
            let hintWidth = (hint as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
            text(hint, at: NSPoint(x: plot.midX - hintWidth / 2, y: plot.midY - 13), size: 11)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plot.insetBy(dx: -4, dy: -4)).addClip()
        drawBars()
        NSGraphicsContext.restoreGraphicsState()
        for point in visible where point.rise {
            let p = position(point)
            UsageChartPalette.surface.setFill(); UsageChartPalette.event.setStroke()
            let marker = NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
            marker.lineWidth = 1.6; marker.fill(); marker.stroke()
        }
        for label in UsageChartAnnotations.layout(visible, start: start, duration: range.duration, plot: plot) {
            UsageChartPalette.event.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: label.rect, xRadius: 6, yRadius: 6).fill()
            text(label.title, at: NSPoint(x: label.rect.minX + 9, y: label.rect.minY + 4), color: UsageChartPalette.event, size: 10, weight: .medium)
        }
        if let hovered { drawHover(hovered, formatter: formatter) }
    }
    private func barRect(_ bucket: UsageChartBucket) -> NSRect {
        let left = max(plot.minX, plot.minX + CGFloat(bucket.start.timeIntervalSince(start) / range.duration) * plot.width)
        let right = min(plot.maxX, plot.minX + CGFloat(bucket.end.timeIntervalSince(start) / range.duration) * plot.width)
        let width = max(2, min(16, (right - left) * 0.78))
        return NSRect(x: max(plot.minX, min((left + right - width) / 2, plot.maxX - width)), y: plot.minY,
                      width: width, height: max(2, CGFloat(bucket.remaining) / 100 * plot.height))
    }

    private func drawBars() {
        for bucket in buckets() {
            let rect = barRect(bucket)
            let tint = UsageChartPalette.quota(bucket.remaining)
            if hoveredBucket?.start == bucket.start {
                UsageChartPalette.muted.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.midX - max(6, rect.width), y: plot.minY,
                    width: max(12, rect.width * 2), height: plot.height), xRadius: 3, yRadius: 3).fill()
            }
            let radius = min(4, rect.width / 2, rect.height / 2)
            let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSGradient(starting: tint.withAlphaComponent(bucket.isEstimated ? 0.08 : 0.22),
                       ending: tint.withAlphaComponent(bucket.isEstimated ? 0.45 : 0.92))?.draw(in: shape, angle: 90)
            if bucket.maximum > bucket.minimum {
                let whisker = NSBezierPath(); whisker.lineWidth = 1
                whisker.move(to: NSPoint(x: rect.midX, y: plot.minY + CGFloat(bucket.minimum) / 100 * plot.height))
                whisker.line(to: NSPoint(x: rect.midX, y: plot.minY + CGFloat(bucket.maximum) / 100 * plot.height))
                UsageChartPalette.ink.withAlphaComponent(0.35).setStroke(); whisker.stroke()
            }
            // A real zero remains distinct from an absent observation.
            if bucket.isEstimated {
                NSGraphicsContext.saveGraphicsState(); shape.addClip()
                tint.withAlphaComponent(0.65).setStroke()
                let cap = NSBezierPath(); cap.lineWidth = 1
                let dash: [CGFloat] = [2, 2]; cap.setLineDash(dash, count: 2, phase: 0)
                cap.move(to: NSPoint(x: rect.minX, y: rect.maxY - 0.5)); cap.line(to: NSPoint(x: rect.maxX, y: rect.maxY - 0.5)); cap.stroke()
                NSGraphicsContext.restoreGraphicsState()
            } else {
                NSGraphicsContext.saveGraphicsState(); shape.addClip()
                tint.withAlphaComponent(0.92).setFill()
                NSRect(x: rect.minX, y: rect.maxY - radius - 1, width: rect.width, height: radius + 1).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
    private func drawHover(_ point: UsageObservation, formatter: DateFormatter) {
        var p = position(point)
        if let hoveredBucket {
            p.x = barRect(hoveredBucket).midX
            p.y = plot.minY + CGFloat(hoveredBucket.remaining) / 100 * plot.height
        }
        UsageChartPalette.muted.withAlphaComponent(0.5).setStroke()
        let crosshair = NSBezierPath(); crosshair.lineWidth = 0.7
        crosshair.move(to: NSPoint(x: p.x, y: plot.minY)); crosshair.line(to: NSPoint(x: p.x, y: plot.maxY)); crosshair.stroke()
        UsageChartPalette.surface.setFill(); UsageChartPalette.trace.setStroke()
        let marker = NSBezierPath(ovalIn: NSRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
        marker.lineWidth = 2; marker.fill(); marker.stroke()
        let estimateLabel = hoveredBucket?.estimateKind == .lastKnown ? "前值延续 · 非实测" : "下降估计 · 非实测"
        let label = hoverCount.map { $0 > 1 ? "\($0)次刷新，最近一次" : "额度刷新 · 首次观测" }
            ?? (hoveredBucket?.isEstimated == true ? estimateLabel : "时段内末次查询剩余")
        let width: CGFloat = 208, height: CGFloat = hoveredBucket == nil ? 67 : 90
        let x = max(plot.minX + 3, min(p.x + 12, plot.maxX - width - 3))
        let y = p.y > plot.midY ? max(plot.minY + 4, p.y - height - 12) : min(plot.maxY - height - 4, p.y + 12)
        let box = NSRect(x: x, y: y, width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowBlurRadius = 8; shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.10); shadow.set()
        UsageChartPalette.surface.setFill(); NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        NSGraphicsContext.restoreGraphicsState()
        UsageChartPalette.muted.withAlphaComponent(0.2).setStroke(); NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).stroke()
        text(label, at: NSPoint(x: x + 12, y: y + height - 20), size: 10)
        let value = hoveredBucket?.remaining ?? point.remaining
        text("\(hoveredBucket?.isEstimated == true ? "≈" : "")\(value)%", at: NSPoint(x: x + 12, y: y + height - 43), color: UsageChartPalette.quota(value), size: 18, weight: .semibold)
        formatter.dateFormat = "MM/dd HH:mm:ss"
        text(formatter.string(from: hoveredBucket?.estimatedAt ?? point.time), at: NSPoint(x: x + 12, y: y + height - 58), size: 10)
        if let bucket = hoveredBucket {
            let detail = bucket.isEstimated ? "两端实测 \(bucket.last.remaining)% / \(bucket.nextObservation?.remaining ?? bucket.remaining)%" : "记录范围 \(bucket.minimum)%–\(bucket.maximum)% · \(bucket.count)条记录"
            text(detail, at: NSPoint(x: x + 12, y: y + 9), size: 10)
        }
    }
}
