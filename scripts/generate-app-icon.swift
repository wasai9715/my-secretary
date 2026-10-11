#!/usr/bin/env swift
// Generates the editable concept as macOS app and menu-bar image assets.
// Run: swift scripts/generate-app-icon.swift
import AppKit
import CoreGraphics
import Foundation

let resources = URL(fileURLWithPath: "Sources/SecretaryMac/Resources", isDirectory: true)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("MySecretary-\(UUID().uuidString).iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

func render(_ pixels: Int, draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(context)
    context.flush()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func roundRect(_ ctx: CGContext, _ rect: CGRect, _ radius: CGFloat, _ fill: CGColor) {
    ctx.setFillColor(fill)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
}

func appIcon(_ ctx: CGContext) {
    let tile = CGPath(roundedRect: CGRect(x: 48, y: 48, width: 928, height: 928), cornerWidth: 214, cornerHeight: 214, transform: nil)
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [color(0x66B9F3), color(0x287BD5), color(0x195BB0)] as CFArray,
                              locations: [0, 0.58, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 130, y: 970), end: CGPoint(x: 860, y: 60), options: [])
    // A little breathing room and depth keep the mark legible at Dock sizes.
    ctx.setFillColor(color(0xFFFFFF, alpha: 0.10))
    ctx.fillEllipse(in: CGRect(x: -280, y: 660, width: 800, height: 800))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -23), blur: 35, color: color(0x0C356A, alpha: 0.35))
    roundRect(ctx, CGRect(x: 230, y: 192, width: 564, height: 652), 66, color(0xFFFFFF))
    ctx.restoreGState()
    // A neatly folded note corner.
    ctx.setFillColor(color(0xD9EBFC))
    ctx.move(to: CGPoint(x: 650, y: 844))
    ctx.addLine(to: CGPoint(x: 794, y: 700))
    ctx.addLine(to: CGPoint(x: 690, y: 700))
    ctx.addQuadCurve(to: CGPoint(x: 650, y: 740), control: CGPoint(x: 650, y: 700))
    ctx.closePath()
    ctx.fillPath()
    roundRect(ctx, CGRect(x: 315, y: 581, width: 270, height: 29), 14, color(0x377FC6))
    roundRect(ctx, CGRect(x: 315, y: 495, width: 390, height: 25), 12, color(0xBDD4E8))
    roundRect(ctx, CGRect(x: 315, y: 418, width: 328, height: 25), 12, color(0xBDD4E8))
    // A reminder dot, rather than an alarming badge or a second app symbol.
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillEllipse(in: CGRect(x: 688, y: 731, width: 174, height: 174))
    ctx.setFillColor(color(0xFF9B59))
    ctx.fillEllipse(in: CGRect(x: 705, y: 748, width: 140, height: 140))
}

func menuIcon(_ ctx: CGContext) {
    // Template asset: macOS supplies the appropriate menu-bar color in light/dark mode.
    let ink = CGColor(gray: 0, alpha: 1)
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(78)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 181, y: 110, width: 616, height: 794), cornerWidth: 94, cornerHeight: 94, transform: nil))
    ctx.strokePath()
    roundRect(ctx, CGRect(x: 292, y: 603, width: 312, height: 69), 34, ink)
    roundRect(ctx, CGRect(x: 292, y: 451, width: 394, height: 69), 34, ink)
    roundRect(ctx, CGRect(x: 292, y: 299, width: 310, height: 69), 34, ink)
    ctx.setFillColor(ink)
    ctx.fillEllipse(in: CGRect(x: 684, y: 682, width: 250, height: 250))
}

let sizes = [(16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
             (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
             (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
             (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
             (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")]
for (size, name) in sizes {
    try render(size, draw: appIcon).write(to: iconset.appendingPathComponent(name))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
try render(72, draw: menuIcon).write(to: resources.appendingPathComponent("MenuIcon.png"))
print("Generated AppIcon.icns and MenuIcon.png")
