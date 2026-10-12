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

final class UsageChartView: NSView {
    var points: [UsageObservation] = [] { didSet { hovered = nil; needsDisplay = true } }
    var kind = UsageWindowKind.fiveHour { didSet { needsDisplay = true } }
    var end = Date() { didSet { needsDisplay = true } }
    private var hovered: UsageObservation?
    private var tracking: NSTrackingArea?
    private var plot: NSRect { bounds.insetBy(dx: 48, dy: 40) }
    private var start: Date { end.addingTimeInterval(-kind.historyDuration) }
    override var isOpaque: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("剩余额度随时间变化；实线连接连续查询记录，虚线是采样空档、口径变化或额度回升之间的估计连接")
    }
    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard plot.contains(location), !points.isEmpty else { hovered = nil; needsDisplay = true; return }
        let target = start.addingTimeInterval(Double((location.x - plot.minX) / plot.width) * kind.historyDuration)
        // Binary search the raw minute samples, not the reduced drawing series.
        var lower = 0, upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].time < target { lower = middle + 1 } else { upper = middle }
        }
        let indices = [max(0, lower - 1), min(points.count - 1, lower)]
        hovered = indices.map { points[$0] }.min { abs($0.time.timeIntervalSince(target)) < abs($1.time.timeIntervalSince(target)) }
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true }

    private func location(_ point: UsageObservation) -> NSPoint {
        NSPoint(x: plot.minX + CGFloat(point.time.timeIntervalSince(start) / kind.historyDuration) * plot.width,
                y: plot.minY + CGFloat(point.remaining) / 100 * plot.height)
    }
    private func text(_ value: String, at position: NSPoint, color: NSColor = .secondaryLabelColor, size: CGFloat = 10) {
        (value as NSString).draw(at: position, withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular), .foregroundColor: color])
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        guard plot.width > 0, plot.height > 0 else { return }
        for value in stride(from: 0, through: 100, by: 20) {
            let y = plot.minY + CGFloat(value) / 100 * plot.height
            NSColor.separatorColor.setStroke()
            let line = NSBezierPath(); line.move(to: NSPoint(x: plot.minX, y: y)); line.line(to: NSPoint(x: plot.maxX, y: y)); line.stroke()
            text("\(value)%", at: NSPoint(x: 6, y: y - 6))
        }
        let formatter = DateFormatter(); formatter.dateFormat = kind == .fiveHour ? "MM/dd HH:mm" : "MM/dd"
        for index in 0...4 {
            let fraction = Double(index) / 4
            let label = formatter.string(from: start.addingTimeInterval(kind.historyDuration * fraction))
            text(label, at: NSPoint(x: plot.minX + plot.width * fraction - (kind == .fiveHour ? 33 : 15), y: 16))
        }
        let visible = points.filter { $0.time >= start && $0.time <= end }
        guard !visible.isEmpty else {
            text("尚无历史记录，成功查询后将开始绘制", at: NSPoint(x: plot.midX - 115, y: plot.midY), size: 12)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plot.insetBy(dx: -4, dy: -4)).addClip()
        NSColor.controlAccentColor.setStroke(); NSColor.controlAccentColor.setFill()
        let segments = UsageChartSeries.segments(visible)
        for connection in UsageChartSeries.estimatedConnections(segments) {
            let path = NSBezierPath(); path.lineWidth = 1.8
            let dash: [CGFloat] = [4, 3]
            path.setLineDash(dash, count: dash.count, phase: 0)
            path.move(to: location(connection.from)); path.line(to: location(connection.to))
            path.stroke()
        }
        for segment in segments {
            let reduced = UsageChartSeries.reduced(segment, start: start, duration: kind.historyDuration, width: plot.width)
            let path = NSBezierPath(); path.lineWidth = 1.8
            for (index, point) in reduced.enumerated() {
                if index == 0 { path.move(to: location(point)) } else { path.line(to: location(point)) }
            }
            path.stroke()
            if reduced.count == 1, let point = reduced.first {
                let p = location(point)
                NSBezierPath(ovalIn: NSRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        var lastLabelX = -CGFloat.greatestFiniteMagnitude
        for point in visible where point.rise {
            let p = location(point)
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
            if p.x - lastLabelX >= 75 {
                text("额度回升", at: NSPoint(x: min(p.x + 4, plot.maxX - 46), y: min(p.y + 7, plot.maxY + 10)))
                lastLabelX = p.x
            }
        }
        if let hovered, hovered.time >= start, hovered.time <= end {
            let p = location(hovered)
            NSColor.labelColor.setStroke()
            let line = NSBezierPath(); line.move(to: NSPoint(x: p.x, y: plot.minY)); line.line(to: NSPoint(x: p.x, y: plot.maxY)); line.lineWidth = 0.5; line.stroke()
            formatter.dateFormat = "MM/dd HH:mm:ss"
            let label = "\(formatter.string(from: hovered.time)) · 实测 \(hovered.remaining)%"
            let box = NSRect(x: max(plot.minX, min(p.x - 100, plot.maxX - 220)), y: plot.maxY - 28, width: 220, height: 24)
            NSColor.controlBackgroundColor.setFill(); NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
            text(label, at: NSPoint(x: box.minX + 8, y: box.minY + 6), color: .labelColor, size: 11)
        }
    }
}
