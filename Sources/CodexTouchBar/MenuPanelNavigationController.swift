import AppKit

private final class MenuPanelClipView: NSView {
    override var isFlipped: Bool { true }
}

private final class MenuPanelPageView: NSView {
    override var isFlipped: Bool { true }
    let content: NSView
    var naturalSize: NSSize

    init(content: NSView, size: NSSize) {
        self.content = content; naturalSize = size
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        content.autoresizingMask = []
        content.translatesAutoresizingMaskIntoConstraints = true
        addSubview(content)
    }
    required init?(coder: NSCoder) { nil }

    func fit(in size: NSSize) {
        // Scale a stable layout as one page instead of revealing a clipped full-size canvas.
        let scale = min(1, size.width / naturalSize.width, size.height / naturalSize.height)
        let scaled = NSSize(width: naturalSize.width * scale, height: naturalSize.height * scale)
        frame = NSRect(x: (size.width - scaled.width) / 2, y: 0, width: scaled.width, height: scaled.height)
        bounds = NSRect(origin: .zero, size: naturalSize)
        content.frame = NSRect(origin: .zero, size: naturalSize)
    }
}

/// Keeps one popover alive while its size and two local pages blend together.
@MainActor
final class MenuPanelNavigationController: NSViewController {
    enum Page { case overview, history }
    private(set) var page = Page.overview
    private(set) var isTransitioning = false
    private var pages: [Page: MenuPanelPageView] = [:]
    private var timer: Timer?
    private var transitionGeneration = 0
    private var transitionStarted = Date()
    private var fromSize = NSSize.zero
    private var toSize = NSSize.zero
    private var fromAlpha: [Page: CGFloat] = [:]
    var onResize: ((NSSize) -> Void)?

    init(overview: NSView) {
        super.init(nibName: nil, bundle: nil)
        let size = overview.fittingSize
        view = MenuPanelClipView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true; view.layer?.masksToBounds = true
        show(.overview, content: overview, size: size, animated: false)
    }
    required init?(coder: NSCoder) { nil }

    func show(_ destination: Page, content: NSView, size: NSSize, animated: Bool) {
        timer?.invalidate(); timer = nil
        transitionGeneration += 1
        let generation = transitionGeneration
        view.window?.makeFirstResponder(nil)
        fromSize = view.bounds.size; toSize = size
        if pages[destination]?.content !== content {
            pages[destination]?.removeFromSuperview()
            let host = MenuPanelPageView(content: content, size: size)
            host.alphaValue = 0
            pages[destination] = host
        }
        pages[destination]?.naturalSize = size
        for child in pages.values {
            if child.superview !== view { view.addSubview(child) }
            child.isHidden = false
            child.wantsLayer = true
            child.autoresizingMask = []
            child.translatesAutoresizingMaskIntoConstraints = true
        }
        pages[destination]?.fit(in: fromSize)
        content.layoutSubtreeIfNeeded()
        fromAlpha = pages.mapValues(\.alphaValue)
        page = destination
        isTransitioning = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard isTransitioning else { advance(to: 1); return }
        transitionStarted = Date()
        timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isTransitioning,
                      self.transitionGeneration == generation else { return }
                self.advance(to: min(1, Date().timeIntervalSince(self.transitionStarted) / 0.26))
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    /// Also used by offscreen checks to verify a real intermediate layout.
    func advance(to progress: Double) {
        let t = max(0, min(1, progress))
        let eased = CGFloat((1 - cos(t * .pi)) / 2)
        // NSPopover rounds its content size to whole points. Match that rounding so
        // the next layout pass cannot pull a fractional frame back by one pixel.
        let size = NSSize(width: (fromSize.width + (toSize.width - fromSize.width) * eased).rounded(.up),
                          height: (fromSize.height + (toSize.height - fromSize.height) * eased).rounded(.up))
        view.setFrameSize(size)
        // The popover is resized through onResize only. Updating preferredContentSize
        // as well schedules a second AppKit resize that can arrive one frame late.
        for (key, child) in pages {
            child.fit(in: size)
            let alpha = fromAlpha[key] ?? 0
            // Fade the outgoing text before revealing the next page's headings.
            if key == page {
                let reveal = max(0, min(1, (eased - 0.18) / 0.82))
                child.alphaValue = alpha + (1 - alpha) * reveal
            } else {
                child.alphaValue = alpha * max(0, 1 - eased / 0.38)
            }
            if t == 1 { child.isHidden = key != page }
        }
        onResize?(size)
        if t == 1 { timer?.invalidate(); timer = nil; isTransitioning = false }
    }

    func content(for page: Page) -> NSView? { pages[page]?.content }

    func stop() {
        transitionGeneration += 1
        timer?.invalidate(); timer = nil; isTransitioning = false
    }
}
