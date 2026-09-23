import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("usage: render_app_icon.swift OUTPUT.png\n", stderr)
    exit(64)
}

let size = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("could not create icon bitmap\n", stderr)
    exit(1)
}

let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

// A restrained, large Touch Bar silhouette echoes the menu-bar mark. Two
// coloured strokes communicate the two quota windows without tiny lettering.
let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 206, yRadius: 206)
NSGradient(
    starting: NSColor(calibratedRed: 0.13, green: 0.18, blue: 0.29, alpha: 1),
    ending: NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.17, alpha: 1)
)!.draw(in: background, angle: 90)

let shell = NSBezierPath(roundedRect: NSRect(x: 153, y: 357, width: 718, height: 310), xRadius: 105, yRadius: 105)
NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.33, alpha: 1).setFill()
shell.fill()
NSColor(calibratedRed: 0.85, green: 0.90, blue: 0.96, alpha: 1).setStroke()
shell.lineWidth = 30
shell.stroke()

func stroke(_ rect: NSRect, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
}

let track = NSColor(calibratedRed: 0.34, green: 0.42, blue: 0.55, alpha: 1)
stroke(NSRect(x: 239, y: 482, width: 234, height: 60), color: track)
stroke(NSRect(x: 551, y: 482, width: 234, height: 60), color: track)
stroke(NSRect(x: 239, y: 482, width: 177, height: 60), color: NSColor(calibratedRed: 0.38, green: 0.77, blue: 0.97, alpha: 1))
stroke(NSRect(x: 551, y: 482, width: 192, height: 60), color: NSColor(calibratedRed: 0.37, green: 0.88, blue: 0.69, alpha: 1))

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("could not encode icon PNG\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
