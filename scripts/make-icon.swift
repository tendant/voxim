#!/usr/bin/env swift
// Renders voxim's app icon (original artwork, no SF Symbols) into the asset catalog and docs.
//
//   swift scripts/make-icon.swift
//
// Design: macOS icon grid (824 pt body on a 1024 canvas), indigo→violet gradient, and a
// white five-bar voice waveform with a short text cursor — "speak, and it types".

import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconSet = root.appending(path: "voxim/Assets.xcassets/AppIcon.appiconset")
let docsIcon = root.appending(path: "docs/images/icon.png")

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    let scale = CGFloat(pixels) / 1024
    cg.scaleBy(x: scale, y: scale)

    // Body with soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.30).cgColor)
    cg.addPath(bodyPath)
    cg.setFillColor(NSColor.black.cgColor)
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(bodyPath)
    cg.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(srgbRed: 0.42, green: 0.36, blue: 0.98, alpha: 1).cgColor,  // violet (top)
            NSColor(srgbRed: 0.17, green: 0.20, blue: 0.62, alpha: 1).cgColor,  // deep indigo (bottom)
        ] as CFArray,
        locations: [0, 1]
    )!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Subtle top highlight.
    let highlight = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor.white.withAlphaComponent(0.16).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
        locations: [0, 1]
    )!
    cg.drawLinearGradient(highlight, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    cg.restoreGState()

    // Waveform: five rounded bars, centered vertically, shifted left to leave room for the cursor.
    let heights: [CGFloat] = [0.30, 0.62, 0.92, 0.58, 0.34]
    let barWidth: CGFloat = 64, gap: CGFloat = 40, maxHeight: CGFloat = 420
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    let cursorGap: CGFloat = 54, cursorWidth: CGFloat = 26
    let groupWidth = totalWidth + cursorGap + cursorWidth
    var x = 512 - groupWidth / 2
    cg.setFillColor(NSColor.white.cgColor)
    for h in heights {
        let height = maxHeight * h
        let bar = CGRect(x: x, y: 512 - height / 2, width: barWidth, height: height)
        cg.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        x += barWidth + gap
    }
    cg.fillPath()

    // Text cursor: thin bar, slightly translucent.
    let cursor = CGRect(x: x - gap + cursorGap, y: 512 - maxHeight * 0.5, width: cursorWidth, height: maxHeight)
    cg.setFillColor(NSColor.white.withAlphaComponent(0.55).cgColor)
    cg.addPath(CGPath(roundedRect: cursor, cornerWidth: cursorWidth / 2, cornerHeight: cursorWidth / 2, transform: nil))
    cg.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

struct Slot { let size: Int; let scale: Int }
let slots = [16, 32, 128, 256, 512].flatMap { [Slot(size: $0, scale: 1), Slot(size: $0, scale: 2)] }

var images: [[String: String]] = []
for slot in slots {
    let pixels = slot.size * slot.scale
    let name = "icon_\(slot.size)x\(slot.size)\(slot.scale == 2 ? "@2x" : "").png"
    try render(pixels: pixels).write(to: iconSet.appending(path: name))
    images.append(["idiom": "mac", "scale": "\(slot.scale)x", "size": "\(slot.size)x\(slot.size)", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconSet.appending(path: "Contents.json"))

try FileManager.default.createDirectory(at: docsIcon.deletingLastPathComponent(), withIntermediateDirectories: true)
try render(pixels: 512).write(to: docsIcon)
print("Wrote \(slots.count) icon sizes and \(docsIcon.path)")
