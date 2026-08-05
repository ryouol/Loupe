#!/usr/bin/env swift
// Renders the Loupe app icon (a loupe over a decode-rate trace) and writes
// every size the AppIcon.appiconset needs. Run once, commit the PNGs:
//   swift scripts/generate-app-icon.swift Resources/Assets.xcassets/AppIcon.appiconset

import AppKit

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/Assets.xcassets/AppIcon.appiconset"

func drawIcon(canvas: CGFloat) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }

    let scale = canvas / 1024.0
    func pt(_ value: CGFloat) -> CGFloat { value * scale }

    // macOS icon grid: 824pt squircle centered in a 1024pt canvas.
    let plate = NSRect(x: pt(100), y: pt(100), width: pt(824), height: pt(824))
    let platePath = NSBezierPath(roundedRect: plate, xRadius: pt(186), yRadius: pt(186))

    context.saveGState()
    platePath.addClip()
    let background = NSGradient(
        colors: [
            NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.24, alpha: 1),
            NSColor(calibratedRed: 0.16, green: 0.13, blue: 0.38, alpha: 1),
            NSColor(calibratedRed: 0.24, green: 0.16, blue: 0.52, alpha: 1),
        ])
    background?.draw(in: plate, angle: 75)

    // Faint plot grid behind everything.
    NSColor.white.withAlphaComponent(0.06).setStroke()
    for line in 1..<5 {
        let y = plate.minY + plate.height * CGFloat(line) / 5
        let grid = NSBezierPath()
        grid.move(to: NSPoint(x: plate.minX + pt(60), y: y))
        grid.line(to: NSPoint(x: plate.maxX - pt(60), y: y))
        grid.lineWidth = pt(4)
        grid.stroke()
    }

    // Decode-rate trace running under the lens.
    let trace = NSBezierPath()
    let points: [(CGFloat, CGFloat)] = [
        (150, 380), (260, 420), (340, 400), (430, 520), (520, 500),
        (610, 640), (700, 600), (790, 700), (874, 660),
    ]
    trace.move(to: NSPoint(x: pt(points[0].0), y: pt(points[0].1)))
    for point in points.dropFirst() {
        trace.line(to: NSPoint(x: pt(point.0), y: pt(point.1)))
    }
    trace.lineWidth = pt(30)
    trace.lineCapStyle = .round
    trace.lineJoinStyle = .round
    NSColor(calibratedRed: 0.29, green: 0.87, blue: 0.83, alpha: 0.9).setStroke()
    trace.stroke()
    context.restoreGState()

    // Lens: ring, glass, and a magnified segment of the trace inside.
    let lensCenter = NSPoint(x: pt(460), y: pt(560))
    let lensRadius = pt(220)
    let lensRect = NSRect(
        x: lensCenter.x - lensRadius, y: lensCenter.y - lensRadius,
        width: lensRadius * 2, height: lensRadius * 2)

    context.saveGState()
    NSBezierPath(ovalIn: lensRect).addClip()
    NSColor(calibratedWhite: 1, alpha: 0.10).setFill()
    context.fill(lensRect)
    let magnified = NSBezierPath()
    magnified.move(to: NSPoint(x: lensRect.minX, y: lensCenter.y - pt(60)))
    magnified.line(to: NSPoint(x: lensCenter.x - pt(70), y: lensCenter.y + pt(10)))
    magnified.line(to: NSPoint(x: lensCenter.x + pt(30), y: lensCenter.y - pt(40)))
    magnified.line(to: NSPoint(x: lensRect.maxX, y: lensCenter.y + pt(90)))
    magnified.lineWidth = pt(44)
    magnified.lineCapStyle = .round
    magnified.lineJoinStyle = .round
    NSColor(calibratedRed: 0.35, green: 0.96, blue: 0.90, alpha: 1).setStroke()
    magnified.stroke()
    let peak = NSRect(
        x: lensCenter.x + pt(30) - pt(34), y: lensCenter.y - pt(40) - pt(34),
        width: pt(68), height: pt(68))
    NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.26, alpha: 1).setFill()
    NSBezierPath(ovalIn: peak).fill()
    context.restoreGState()

    let ring = NSBezierPath(ovalIn: lensRect.insetBy(dx: pt(-6), dy: pt(-6)))
    ring.lineWidth = pt(58)
    NSColor(calibratedWhite: 0.98, alpha: 1).setStroke()
    ring.stroke()

    // Handle at the lower right of the ring.
    let handle = NSBezierPath()
    let angle = -0.72
    let start = NSPoint(
        x: lensCenter.x + cos(angle) * (lensRadius + pt(24)),
        y: lensCenter.y + sin(angle) * (lensRadius + pt(24)))
    let end = NSPoint(
        x: lensCenter.x + cos(angle) * (lensRadius + pt(210)),
        y: lensCenter.y + sin(angle) * (lensRadius + pt(210)))
    handle.move(to: start)
    handle.line(to: end)
    handle.lineWidth = pt(86)
    handle.lineCapStyle = .round
    NSColor(calibratedWhite: 0.98, alpha: 1).setStroke()
    handle.stroke()
}

// Draw into an explicit bitmap so PNGs land at exact pixel sizes: lockFocus
// on a Retina display renders at 2x and actool rejects the oversized files.
func writePNG(pixels: Int, to url: URL) {
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let graphics = NSGraphicsContext(bitmapImageRep: rep)
    else {
        fatalError("bitmap context failed for \(pixels)px")
    }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    drawIcon(canvas: CGFloat(pixels))
    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encode failed for \(pixels)px")
    }
    try? png.write(to: url)
    print("wrote \(url.lastPathComponent) (\(pixels)px)")
}

let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

for (name, pixels) in [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
] {
    writePNG(pixels: pixels, to: directory.appendingPathComponent("\(name).png"))
}
