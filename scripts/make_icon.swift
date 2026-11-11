// Draws the app icon and writes Assets/AppIcon.icns.   Run: swift scripts/make_icon.swift
// The design is a stylised bench-meter display (reading, bar, soft keys) on a light tile.
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024  // design units are for a 1024 canvas
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: s, y: s)

    // Tile: the standard macOS icon shape (824 pt square, centred, continuous-looking corners).
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.white.setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(white: 1.0, alpha: 1), NSColor(white: 0.90, alpha: 1)])!.draw(in: tilePath, angle: -90)

    // Display.
    let screen = NSRect(x: 176, y: 392, width: 672, height: 420)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: 54, yRadius: 54)
    NSGradient(colors: [
        NSColor(red: 0.20, green: 0.34, blue: 0.47, alpha: 1), NSColor(red: 0.13, green: 0.24, blue: 0.35, alpha: 1),
    ])!.draw(in: screenPath, angle: -90)

    // Reading.
    let amber = NSColor(red: 1.0, green: 0.74, blue: 0.16, alpha: 1)
    let digits = NSAttributedString(string: "1.000", attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 172, weight: .semibold), .foregroundColor: amber, .kern: -2,
    ])
    digits.draw(at: NSPoint(x: 222, y: 560))
    let unit = NSAttributedString(string: "V", attributes: [
        .font: NSFont.systemFont(ofSize: 92, weight: .semibold), .foregroundColor: amber.withAlphaComponent(0.85),
    ])
    unit.draw(at: NSPoint(x: 722, y: 582))

    // Bar meter under the reading.
    let track = NSRect(x: 226, y: 452, width: 572, height: 44)
    NSColor.white.withAlphaComponent(0.16).setFill()
    NSBezierPath(roundedRect: track, xRadius: 22, yRadius: 22).fill()
    NSColor(red: 0.33, green: 0.72, blue: 1.0, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: 372, height: 44), xRadius: 22, yRadius: 22).fill()

    // Soft keys.
    let keyWidth: CGFloat = 112, gap: CGFloat = 28
    for index in 0..<5 {
        let key = NSRect(x: 176 + CGFloat(index) * (keyWidth + gap), y: 236, width: keyWidth, height: 84)
        let path = NSBezierPath(roundedRect: key, xRadius: 22, yRadius: 22)
        NSGradient(colors: [NSColor(white: 0.80, alpha: 1), NSColor(white: 0.66, alpha: 1)])!.draw(in: path, angle: -90)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Assets/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = CGFloat(points * scale)
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try draw(size: pixels).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Assets/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
try? FileManager.default.copyItem(at: iconset.appendingPathComponent("icon_512x512.png"), to: root.appendingPathComponent("Assets/AppIcon.png"))
try? FileManager.default.removeItem(at: iconset)
print(process.terminationStatus == 0 ? "Wrote Assets/AppIcon.icns" : "iconutil failed")
