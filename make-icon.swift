import AppKit

// Draws the app icon: a dark rounded tile with a grid of blue usage squares.
let out = CommandLine.arguments[1]
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
rgb(0x1C1C1B).setFill()
NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185).fill()
let colors: [UInt32] = [0x2E2E2D, 0x27509F, 0x3168CC, 0x4A8BEC, 0xA9C8F5]
let pattern = [[0, 0, 1, 2], [0, 1, 3, 4], [1, 2, 4, 3], [2, 4, 3, 4]]
let cell: CGFloat = 128, gap: CGFloat = 32
let origin = (size - (cell * 4 + gap * 3)) / 2
for (r, row) in pattern.enumerated() {
    for (c, level) in row.enumerated() {
        rgb(colors[level]).setFill()
        let rect = NSRect(x: origin + CGFloat(c) * (cell + gap), y: size - origin - cell - CGFloat(r) * (cell + gap), width: cell, height: cell)
        NSBezierPath(roundedRect: rect, xRadius: 30, yRadius: 30).fill()
    }
}
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
