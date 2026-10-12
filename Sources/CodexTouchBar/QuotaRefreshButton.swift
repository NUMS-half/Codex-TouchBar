import AppKit
import QuartzCore

/// A composited refresh glyph; no frame timer or additional quota polling.
final class QuotaRefreshButton: NSButton {
    static let minimumFeedbackDuration: TimeInterval = 0.6
    private let glyph = CAShapeLayer()
    private let rotationKey = "quota.refresh.rotation"
    private var requestRunning = false
    private var presented = false
    private var startedAt: CFTimeInterval?
    private var finishWork: DispatchWorkItem?
    private var finishGeneration = 0
    private(set) var isRotating = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""; image = nil; isBordered = false
        wantsLayer = true
        glyph.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        glyph.path = Self.refreshPath()
        glyph.fillColor = nil
        glyph.lineWidth = 1.35
        glyph.lineCap = .round; glyph.lineJoin = .round
        layer?.addSublayer(glyph)
        setAccessibilityLabel("刷新额度")
        toolTip = "刷新额度"
        updateGlyph()
    }
    required init?(coder: NSCoder) { nil }
    deinit { finishWork?.cancel() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glyph.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); updateGlyph()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties(); updateGlyph()
    }

    func setRefreshing(_ refreshing: Bool) {
        requestRunning = refreshing
        isEnabled = !refreshing
        toolTip = refreshing ? "正在刷新额度…" : "刷新额度"
        setAccessibilityLabel(refreshing ? "正在刷新额度" : "刷新额度")
        if refreshing {
            cancelFinish()
            if presented { startRotation() }
        } else { finishAfterMinimumFeedback() }
    }

    func setPresented(_ visible: Bool) {
        presented = visible
        if !visible { stopRotation() }
        else if requestRunning { startRotation() }
    }

    /// Starts feedback synchronously with the click, including a very fast read.
    func beginInteraction() {
        guard presented else { return }
        cancelFinish()
        startedAt = CACurrentMediaTime()
        startRotation()
        if !requestRunning { finishAfterMinimumFeedback() }
    }

    private func startRotation() {
        guard !isRotating else { return }
        isRotating = true
        startedAt = CACurrentMediaTime()
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0; rotation.toValue = -2 * Double.pi
        rotation.duration = Self.minimumFeedbackDuration; rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        glyph.add(rotation, forKey: rotationKey)
    }

    private func finishAfterMinimumFeedback() {
        guard isRotating, !requestRunning else { return }
        cancelFinish()
        let remaining = Self.minimumFeedbackDuration - (CACurrentMediaTime() - (startedAt ?? 0))
        if remaining <= 0 { stopRotation(); return }
        let ticket = finishGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, ticket == self.finishGeneration, !self.requestRunning else { return }
            self.stopRotation()
        }
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }
    private func cancelFinish() {
        finishGeneration += 1
        finishWork?.cancel(); finishWork = nil
    }
    private func stopRotation() {
        cancelFinish()
        glyph.removeAnimation(forKey: rotationKey)
        isRotating = false; startedAt = nil
    }

    /// Two antipodal arcs and arrowheads share the exact same circle centre.
    /// This avoids rotating the optical padding/baseline of an SF Symbol bitmap.
    private static func refreshPath() -> CGPath {
        let path = CGMutablePath()
        let center = CGPoint(x: 8, y: 8)
        let radius: CGFloat = 5.2
        for offset in [CGFloat(0), CGFloat.pi] {
            let start: CGFloat = 150 * .pi / 180 + offset
            let end: CGFloat = 20 * .pi / 180 + offset
            path.move(to: CGPoint(x: center.x + radius * cos(start), y: center.y + radius * sin(start)))
            path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
            let tip = CGPoint(x: center.x + radius * cos(end), y: center.y + radius * sin(end))
            let tangent = CGPoint(x: sin(end), y: -cos(end))
            let normal = CGPoint(x: cos(end), y: sin(end))
            path.move(to: CGPoint(x: tip.x - 2.5 * tangent.x + 1.6 * normal.x, y: tip.y - 2.5 * tangent.y + 1.6 * normal.y))
            path.addLine(to: tip)
            path.addLine(to: CGPoint(x: tip.x - 2.5 * tangent.x - 1.6 * normal.x, y: tip.y - 2.5 * tangent.y - 1.6 * normal.y))
        }
        return path
    }

    private func updateGlyph() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glyph.contentsScale = scale
        effectiveAppearance.performAsCurrentDrawingAppearance {
            glyph.strokeColor = NSColor.secondaryLabelColor.cgColor
        }
        CATransaction.commit()
    }
}
