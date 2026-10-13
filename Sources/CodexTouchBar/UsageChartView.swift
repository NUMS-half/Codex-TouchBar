import AppKit

enum UsageChartSeries {
    struct EstimatedConnection {
        let from: UsageObservation
        let to: UsageObservation
    }

    static func segments(_ points: [UsageObservation]) -> [[UsageObservation]] {
        var result: [[UsageObservation]] = []
        for point in points {
            if let previous = result.last?.last,
               !point.discontinuity, !point.rise, !point.changedScope(from: previous),
               point.time.timeIntervalSince(previous.time) <= 900 {
                result[result.count - 1].append(point)
            } else { result.append([point]) }
        }
        return result
    }

    /// Connect every break between real samples without adding invented observations.
    static func estimatedConnections(_ segments: [[UsageObservation]]) -> [EstimatedConnection] {
        zip(segments, segments.dropFirst()).compactMap { previous, next in
            guard let from = previous.last, let to = next.first else { return nil }
            return EstimatedConnection(from: from, to: to)
        }
    }

    /// Retain first/last and both extrema per pixel column; never interpolate values.
    static func reduced(_ points: [UsageObservation], start: Date, duration: TimeInterval, width: Double) -> [UsageObservation] {
        guard points.count > Int(width) * 4 else { return points }
        var result: [UsageObservation] = []
        var group: [UsageObservation] = []
        var column = Int.min
        func flush() {
            guard let first = group.first, let last = group.last,
                  let low = group.min(by: { $0.remaining < $1.remaining }),
                  let high = group.max(by: { $0.remaining < $1.remaining }) else { return }
            var times = Set<Date>()
            for point in [first, low, high, last].sorted(by: { $0.time < $1.time }) where times.insert(point.time).inserted {
                result.append(point)
            }
            group.removeAll(keepingCapacity: true)
        }
        for point in points {
            let next = Int(point.time.timeIntervalSince(start) / duration * width)
            if next != column { flush(); column = next }
            group.append(point)
        }
        flush()
        return result
    }
}

enum UsageChartPalette {
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
    }
    static let canvas = adaptive(0xF5F6F8, 0x202126)
    static let surface = adaptive(0xFFFFFF, 0x292B31)
    static let ink = adaptive(0x252A34, 0xEAEDF2)
    static let muted = adaptive(0x697385, 0xA8AFBC)
    static let trace = adaptive(0x237AD1, 0x67AAF4)
    static let event = adaptive(0x8B62B4, 0xC4A0E6)
    static func quota(_ value: Int) -> NSColor {
        switch UsageColorBand(remainingPercent: value) {
        case .critical: return adaptive(0xBD3434, 0xFF807B)
        case .low: return adaptive(0xA85D00, 0xFFAF61)
        case .moderate: return adaptive(0x8E6A00, 0xECCC54)
        case .healthy: return adaptive(0x237C4B, 0x64D998)
        }
    }
}

/// Labels live in a dedicated lane, and merge after clamping to its edges.
/// This tests actual label rectangles rather than assuming point spacing is enough.
enum UsageChartAnnotations {
    struct Label {
        var points: [UsageObservation]
        var rect: NSRect
        var title: String { points.count == 1 ? "回升" : "回升 × \(points.count)" }
    }
    static func layout(_ points: [UsageObservation], start: Date, duration: TimeInterval, plot: NSRect) -> [Label] {
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        func x(_ point: UsageObservation) -> CGFloat { plot.minX + CGFloat(point.time.timeIntervalSince(start) / duration) * plot.width }
        func label(_ points: [UsageObservation]) -> Label {
            let title = points.count == 1 ? "回升" : "回升 × \(points.count)"
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
    override var intrinsicContentSize: NSSize { NSSize(width: 278, height: 18) }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true); setAccessibilityLabel("实线为查询记录，虚线为估计连接，紫色标记为额度回升")
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        for (index, label) in ["查询记录", "估计连接", "回升标记"].enumerated() {
            let x = CGFloat(index) * 94
            let path = NSBezierPath(); path.lineWidth = 1.6
            if index == 2 {
                UsageChartPalette.event.setFill()
                NSBezierPath(ovalIn: NSRect(x: x + 8, y: 6, width: 5, height: 5)).fill()
            } else {
                UsageChartPalette.trace.setStroke()
                if index == 1 { let dash: [CGFloat] = [3, 3]; path.setLineDash(dash, count: 2, phase: 0) }
                path.move(to: NSPoint(x: x, y: 8)); path.line(to: NSPoint(x: x + 21, y: 8)); path.stroke()
            }
            (label as NSString).draw(at: NSPoint(x: x + 27, y: 2), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: UsageChartPalette.muted])
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

final class UsageChartView: NSView {
    var points: [UsageObservation] = [] { didSet { hovered = nil; hoverCount = nil; needsDisplay = true } }
    var kind = UsageWindowKind.fiveHour { didSet { needsDisplay = true } }
    var end = Date() { didSet { needsDisplay = true } }
    private var hovered: UsageObservation?
    private var hoverCount: Int?
    private var tracking: NSTrackingArea?
    private var plot: NSRect { NSRect(x: 50, y: 37, width: max(0, bounds.width - 70), height: max(0, bounds.height - 89)) }
    private var start: Date { end.addingTimeInterval(-kind.historyDuration) }
    override var isOpaque: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("剩余额度变化；实线为查询记录，虚线为估计连接，密集回升标记合并显示，悬停查看实测值")
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    func updateHover(at location: NSPoint) {
        hoverCount = nil
        let visible = points.filter { $0.time >= start && $0.time <= end }
        let labels = UsageChartAnnotations.layout(visible, start: start, duration: kind.historyDuration, plot: plot)
        if let label = labels.first(where: { $0.rect.contains(location) }) {
            hovered = label.points.last; hoverCount = label.points.count; needsDisplay = true; return
        }
        guard plot.contains(location), let first = visible.first, let last = visible.last,
              location.x >= position(first).x - 8, location.x <= position(last).x + 8 else {
            hovered = nil; needsDisplay = true; return
        }
        let target = start.addingTimeInterval(Double((location.x - plot.minX) / plot.width) * kind.historyDuration)
        var lower = 0, upper = visible.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if visible[middle].time < target { lower = middle + 1 } else { upper = middle }
        }
        let indices = [max(0, lower - 1), min(visible.count - 1, lower)]
        hovered = indices.map { visible[$0] }.min { abs($0.time.timeIntervalSince(target)) < abs($1.time.timeIntervalSince(target)) }
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { hovered = nil; hoverCount = nil; needsDisplay = true }
    private func position(_ point: UsageObservation) -> NSPoint {
        NSPoint(x: plot.minX + CGFloat(point.time.timeIntervalSince(start) / kind.historyDuration) * plot.width,
                y: plot.minY + CGFloat(point.remaining) / 100 * plot.height)
    }
    private func text(_ value: String, at position: NSPoint, color: NSColor = UsageChartPalette.muted, size: CGFloat = 10, weight: NSFont.Weight = .regular) {
        (value as NSString).draw(at: position, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }
    override func draw(_ dirtyRect: NSRect) {
        UsageChartPalette.canvas.setFill(); bounds.fill()
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        UsageChartPalette.surface.setFill(); card.fill()
        UsageChartPalette.muted.withAlphaComponent(0.13).setStroke(); card.stroke()
        guard plot.width > 0, plot.height > 0 else { return }
        for value in stride(from: 0, through: 100, by: 20) {
            let y = plot.minY + CGFloat(value) / 100 * plot.height
            UsageChartPalette.muted.withAlphaComponent(value == 0 ? 0.22 : 0.11).setStroke()
            let line = NSBezierPath(); line.lineWidth = 0.5
            line.move(to: NSPoint(x: plot.minX, y: y)); line.line(to: NSPoint(x: plot.maxX, y: y)); line.stroke()
            let label = "\(value)%"
            let width = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width
            text(label, at: NSPoint(x: plot.minX - width - 12, y: y - 6))
        }
        let formatter = DateFormatter(); formatter.dateFormat = kind == .fiveHour ? "MM/dd HH:mm" : "MM/dd"
        for index in 0...4 {
            let fraction = Double(index) / 4
            let label = formatter.string(from: start.addingTimeInterval(kind.historyDuration * fraction))
            let width = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width
            let x = max(8, min(plot.minX + plot.width * fraction - width / 2, bounds.maxX - width - 8))
            text(label, at: NSPoint(x: x, y: 13))
        }
        let visible = points.filter { $0.time >= start && $0.time <= end }
        guard !visible.isEmpty else {
            let heading = "还没有额度记录"
            let width = (heading as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium)]).width
            text(heading, at: NSPoint(x: plot.midX - width / 2, y: plot.midY + 9), color: UsageChartPalette.ink, size: 15, weight: .medium)
            let hint = "首次成功查询后自动记录，可在菜单栏点击刷新。"
            let hintWidth = (hint as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
            text(hint, at: NSPoint(x: plot.midX - hintWidth / 2, y: plot.midY - 13), size: 11)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plot.insetBy(dx: -4, dy: -4)).addClip()
        UsageChartPalette.trace.setStroke(); UsageChartPalette.trace.setFill()
        let segments = UsageChartSeries.segments(visible)
        for connection in UsageChartSeries.estimatedConnections(segments) {
            let path = NSBezierPath(); path.lineWidth = 1.7
            let dash: [CGFloat] = [4, 4]; path.setLineDash(dash, count: 2, phase: 0)
            path.move(to: position(connection.from)); path.line(to: position(connection.to)); path.stroke()
        }
        for segment in segments {
            let reduced = UsageChartSeries.reduced(segment, start: start, duration: kind.historyDuration, width: plot.width)
            let path = NSBezierPath(); path.lineWidth = 2; path.lineJoinStyle = .round
            for (index, point) in reduced.enumerated() {
                if index == 0 { path.move(to: position(point)) } else { path.line(to: position(point)) }
            }
            path.stroke()
            if reduced.count == 1, let point = reduced.first {
                let p = position(point); NSBezierPath(ovalIn: NSRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        for point in visible where point.rise {
            let p = position(point)
            UsageChartPalette.surface.setFill(); UsageChartPalette.event.setStroke()
            let marker = NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
            marker.lineWidth = 1.6; marker.fill(); marker.stroke()
        }
        for label in UsageChartAnnotations.layout(visible, start: start, duration: kind.historyDuration, plot: plot) {
            UsageChartPalette.event.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: label.rect, xRadius: 6, yRadius: 6).fill()
            text(label.title, at: NSPoint(x: label.rect.minX + 9, y: label.rect.minY + 4), color: UsageChartPalette.event, size: 10, weight: .medium)
        }
        if let hovered { drawHover(hovered, formatter: formatter) }
    }
    private func drawHover(_ point: UsageObservation, formatter: DateFormatter) {
        let p = position(point)
        UsageChartPalette.muted.withAlphaComponent(0.5).setStroke()
        let crosshair = NSBezierPath(); crosshair.lineWidth = 0.7
        crosshair.move(to: NSPoint(x: p.x, y: plot.minY)); crosshair.line(to: NSPoint(x: p.x, y: plot.maxY)); crosshair.stroke()
        UsageChartPalette.surface.setFill(); UsageChartPalette.trace.setStroke()
        let marker = NSBezierPath(ovalIn: NSRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
        marker.lineWidth = 2; marker.fill(); marker.stroke()
        let label = hoverCount.map { $0 > 1 ? "\($0)次回升，最近一次" : "额度回升" } ?? (point.rise ? "额度回升" : "实测剩余额度")
        let width: CGFloat = 190, height: CGFloat = 67
        let x = max(plot.minX + 3, min(p.x + 12, plot.maxX - width - 3))
        let y = p.y > plot.midY ? max(plot.minY + 4, p.y - height - 12) : min(plot.maxY - height - 4, p.y + 12)
        let box = NSRect(x: x, y: y, width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowBlurRadius = 8; shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.10); shadow.set()
        UsageChartPalette.surface.setFill(); NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        NSGraphicsContext.restoreGraphicsState()
        UsageChartPalette.muted.withAlphaComponent(0.2).setStroke(); NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).stroke()
        text(label, at: NSPoint(x: x + 12, y: y + 47), size: 10)
        text("\(point.remaining)%", at: NSPoint(x: x + 12, y: y + 24), color: UsageChartPalette.quota(point.remaining), size: 18, weight: .semibold)
        formatter.dateFormat = "MM/dd HH:mm:ss"
        text(formatter.string(from: point.time), at: NSPoint(x: x + 12, y: y + 9), size: 10)
    }
}
