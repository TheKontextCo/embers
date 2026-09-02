#!/usr/bin/env swift
// Original, deterministic AppKit vector renderer for Embers' application icon.
// The SVG source documents the same art direction; this renderer avoids external
// converters and creates the exact PNG inputs accepted by iconutil.
import AppKit
import Foundation

guard CommandLine.arguments.count == 3,
      let pixels = Int(CommandLine.arguments[1]), pixels > 0 else {
    fputs("usage: render-app-icon.swift PIXELS output.png\\n", stderr)
    exit(64)
}

let output = URL(fileURLWithPath: CommandLine.arguments[2])
let size = NSSize(width: pixels, height: pixels)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixels,
    pixelsHigh: pixels,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bitmapFormat: [],
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Unable to create app icon bitmap.\\n", stderr)
    exit(70)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
defer { NSGraphicsContext.restoreGraphicsState() }

let scale = CGFloat(pixels) / 1024
func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
    NSRect(x: x * scale, y: y * scale, width: width * scale, height: height * scale)
}
func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
    NSPoint(x: x * scale, y: y * scale)
}

let background = NSBezierPath(roundedRect: rect(40, 40, 944, 944), xRadius: 222 * scale, yRadius: 222 * scale)
NSGradient(
    starting: NSColor(red: 0.145, green: 0.067, blue: 0.035, alpha: 1),
    ending: NSColor(red: 0.083, green: 0.039, blue: 0.027, alpha: 1)
)!.draw(in: background, angle: -45)

let glow = NSBezierPath(ovalIn: rect(312, 292, 400, 520))
NSColor(red: 1, green: 0.32, blue: 0.07, alpha: 0.16).setFill()
glow.fill()

let flame = NSBezierPath()
flame.move(to: point(516, 174))
flame.curve(to: point(370, 542), controlPoint1: point(464, 286), controlPoint2: point(370, 390))
flame.curve(to: point(512, 735), controlPoint1: point(370, 649), controlPoint2: point(433, 735))
flame.curve(to: point(654, 542), controlPoint1: point(591, 735), controlPoint2: point(654, 649))
flame.curve(to: point(516, 174), controlPoint1: point(654, 400), controlPoint2: point(579, 295))
flame.close()
NSGradient(
    starting: NSColor(red: 1, green: 0.42, blue: 0.10, alpha: 1),
    ending: NSColor(red: 1, green: 0.94, blue: 0.66, alpha: 1)
)!.draw(in: flame, angle: 90)

let innerFlame = NSBezierPath()
innerFlame.move(to: point(512, 336))
innerFlame.curve(to: point(439, 552), controlPoint1: point(482, 412), controlPoint2: point(439, 467))
innerFlame.curve(to: point(512, 656), controlPoint1: point(439, 610), controlPoint2: point(470, 656))
innerFlame.curve(to: point(585, 552), controlPoint1: point(554, 656), controlPoint2: point(585, 610))
innerFlame.curve(to: point(512, 336), controlPoint1: point(585, 470), controlPoint2: point(542, 412))
innerFlame.close()
NSColor(red: 0.29, green: 0.10, blue: 0.03, alpha: 0.92).setFill()
innerFlame.fill()

NSColor(red: 1, green: 0.42, blue: 0.10, alpha: 0.9).setFill()
NSBezierPath(ovalIn: rect(470, 744, 84, 84)).fill()

guard let data = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
    fputs("Unable to render app icon PNG.\\n", stderr)
    exit(70)
}
try data.write(to: output, options: Data.WritingOptions.atomic)
