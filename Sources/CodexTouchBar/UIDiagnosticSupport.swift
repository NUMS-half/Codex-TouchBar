import AppKit

/// Offscreen UI checks share this harness; it never presents a Touch Bar or acts on another app.
@MainActor
enum UIDiagnosticSupport {
    enum RenderError: Error { case bitmapUnavailable, pngUnavailable }

    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static func layoutContainer(for control: NSView, root: NSView) -> NSView {
        if let document = control.enclosingScrollView?.documentView, control.isDescendant(of: document) { return document }
        return root
    }
    static func render(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw RenderError.bitmapUnavailable
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.pngUnavailable
        }
        try data.write(to: url)
    }
}
