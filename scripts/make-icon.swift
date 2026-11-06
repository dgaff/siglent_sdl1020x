// Draws the LoadLab app icon and writes an .icns (macOS 1024-grid layout).
// Usage: swift scripts/make-icon.swift <out.icns>
import AppKit

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)

    // Tile: 824 pt rounded square centred on the 1024 grid, with a soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(red: 0.07, green: 0.16, blue: 0.36, alpha: 1).cgColor,
                                   NSColor(red: 0.05, green: 0.45, blue: 0.62, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Faint grid, like a chart.
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
    ctx.setLineWidth(4)
    for k in 1..<6 {
        let y = 100 + CGFloat(k) * 824 / 6
        ctx.move(to: CGPoint(x: 100, y: y)); ctx.addLine(to: CGPoint(x: 924, y: y))
    }
    ctx.strokePath()

    // Discharge curve: flat plateau, then the knee.
    ctx.setStrokeColor(NSColor(red: 0.45, green: 0.95, blue: 0.85, alpha: 0.9).cgColor)
    ctx.setLineWidth(26); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 170, y: 330))
    ctx.addCurve(to: CGPoint(x: 600, y: 255), control1: CGPoint(x: 330, y: 290), control2: CGPoint(x: 480, y: 280))
    ctx.addCurve(to: CGPoint(x: 850, y: 150), control1: CGPoint(x: 720, y: 235), control2: CGPoint(x: 800, y: 215))
    ctx.strokePath()
    ctx.restoreGState()

    // Battery outline.
    let body = CGRect(x: 250, y: 420, width: 470, height: 270)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(34)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 56, cornerHeight: 56, transform: nil))
    ctx.strokePath()
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 735, y: 505, width: 52, height: 100), cornerWidth: 18, cornerHeight: 18, transform: nil))
    ctx.fillPath()

    // Lightning bolt.
    let bolt = CGMutablePath()
    bolt.addLines(between: [CGPoint(x: 520, y: 650), CGPoint(x: 400, y: 545), CGPoint(x: 478, y: 545),
                            CGPoint(x: 445, y: 455), CGPoint(x: 575, y: 575), CGPoint(x: 495, y: 575)])
    bolt.closeSubpath()
    ctx.addPath(bolt)
    ctx.setFillColor(NSColor(red: 1.0, green: 0.78, blue: 0.2, alpha: 1).cgColor)
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.dropFirst().first ?? "LoadLab.icns"
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("LoadLab-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(px).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out]
try p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
print("Wrote \(out)")
