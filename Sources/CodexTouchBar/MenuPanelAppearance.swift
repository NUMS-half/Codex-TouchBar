import AppKit

/// Card accents sit above the native popover material rather than replacing it.
enum MenuPanelPalette {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
    }
    static let inset = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.black.withAlphaComponent(dark ? 0.12 : 0.045)
    }
    static let card = adaptive(0xFFFFFF, 0x34373F)
    static let border = NSColor.labelColor.withAlphaComponent(0.10)
}
