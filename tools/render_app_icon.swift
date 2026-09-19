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

let canvas = NSRect(x: 0, y: 0, width: size, height: size)
NSGradient(
    starting: NSColor(calibratedRed: 0.09, green: 0.125, blue: 0.20, alpha: 1),
    ending: NSColor(calibratedRed: 0.043, green: 0.063, blue: 0.102, alpha: 1)
)!.draw(in: NSBezierPath(roundedRect: canvas, xRadius: 224, yRadius: 224), angle: -45)

let shell = NSRect(x: 122, y: 315, width: 780, height: 394)
NSColor(calibratedWhite: 0, alpha: 0.30).setFill()
NSBezierPath(roundedRect: shell.offsetBy(dx: 0, dy: -20), xRadius: 104, yRadius: 104).fill()
NSColor(calibratedRed: 0.067, green: 0.102, blue: 0.157, alpha: 1).setFill()
NSBezierPath(roundedRect: shell, xRadius: 104, yRadius: 104).fill()
NSColor(calibratedRed: 0.20, green: 0.255, blue: 0.333, alpha: 1).setStroke()
let shellOutline = NSBezierPath(roundedRect: shell, xRadius: 104, yRadius: 104)
shellOutline.lineWidth = 18
shellOutline.stroke()

func roundedBar(_ rect: NSRect, _ color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
}

let muted = NSColor(calibratedRed: 0.15, green: 0.21, blue: 0.28, alpha: 1)
roundedBar(NSRect(x: 177, y: 385, width: 292, height: 28), NSColor(calibratedRed: 0.286, green: 0.82, blue: 0.49, alpha: 1))
roundedBar(NSRect(x: 177, y: 438, width: 218, height: 28), muted)
roundedBar(NSRect(x: 177, y: 438, width: 164, height: 28), NSColor(calibratedRed: 0.953, green: 0.788, blue: 0.302, alpha: 1))
roundedBar(NSRect(x: 555, y: 385, width: 292, height: 28), NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.97, alpha: 1))
roundedBar(NSRect(x: 555, y: 438, width: 218, height: 28), muted)
roundedBar(NSRect(x: 555, y: 438, width: 194, height: 28), NSColor(calibratedRed: 0.286, green: 0.82, blue: 0.49, alpha: 1))

func clock(at center: NSPoint) {
    NSColor(calibratedRed: 0.863, green: 0.91, blue: 0.96, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 51, y: center.y - 51, width: 102, height: 102)).fill()
    NSColor(calibratedRed: 0.09, green: 0.125, blue: 0.20, alpha: 1).setStroke()
    let hands = NSBezierPath()
    hands.move(to: NSPoint(x: center.x, y: center.y + 34))
    hands.line(to: center)
    hands.line(to: NSPoint(x: center.x + 25, y: center.y - 18))
    hands.lineCapStyle = .round
    hands.lineJoinStyle = .round
    hands.lineWidth = 14
    hands.stroke()
}

clock(at: NSPoint(x: 323, y: 549))
clock(at: NSPoint(x: 701, y: 549))
roundedBar(NSRect(x: 177, y: 631, width: 292, height: 20), muted)
roundedBar(NSRect(x: 177, y: 631, width: 210, height: 20), NSColor(calibratedRed: 0.953, green: 0.788, blue: 0.302, alpha: 1))
roundedBar(NSRect(x: 555, y: 631, width: 292, height: 20), muted)
roundedBar(NSRect(x: 555, y: 631, width: 260, height: 20), NSColor(calibratedRed: 0.286, green: 0.82, blue: 0.49, alpha: 1))

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("could not encode icon PNG\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
