#!/usr/bin/env swift
// Generates the RoadSense NS app icon at 1024×1024 and writes it to
// ios/RoadSenseNS/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png.
//
// Design: warm canvas background, deep-teal road ribbon with a pothole dot,
// signal-amber dashed center line, small mint tick. Rendered directly into a
// CGContext bitmap (no NSImage lockFocus) so it works headless.
//
// Run: swift scripts/generate-app-icon.swift

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Colors (matches docs/design-tokens.md)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255.0,
        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
        blue: CGFloat(hex & 0xFF) / 255.0,
        alpha: alpha
    )
}

let canvas = color(0xF6F1E8)
let canvasLight = color(0xFFF8EC)
let deep = color(0x0E3B4A)
let deepHighlight = color(0x1C556A)
let deepShadow = color(0x07222C, alpha: 0.28)
let signal = color(0xE9A23B, alpha: 0.9)
let smooth = color(0x2F8F6D)
let pothole = color(0xC04242)
let potholeGloss = color(0xDB5A5A)
let monogram = color(0x0F1E26, alpha: 0.10)

// MARK: - Render

let size: CGFloat = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()

guard let ctx = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Could not create bitmap context")
}

let rect = CGRect(x: 0, y: 0, width: size, height: size)

// Background: warm canvas
ctx.setFillColor(canvas)
ctx.fill(rect)

// Radial highlight
if let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [canvasLight, canvas] as CFArray,
    locations: [0, 1]
) {
    ctx.drawRadialGradient(
        gradient,
        startCenter: CGPoint(x: size * 0.32, y: size * 0.72),
        startRadius: 40,
        endCenter: CGPoint(x: size * 0.5, y: size * 0.5),
        endRadius: size * 0.8,
        options: []
    )
}

// === Road ribbon ===
let ribbonPath = CGMutablePath()
ribbonPath.move(to: CGPoint(x: 180, y: 184))   // bottom-left (origin bottom-left since we flip later)
ribbonPath.addCurve(
    to: CGPoint(x: 844, y: 840),
    control1: CGPoint(x: 320, y: 504),
    control2: CGPoint(x: 700, y: 520)
)

// Shadow under ribbon
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 32, color: deepShadow)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setStrokeColor(deep)
ctx.setLineWidth(178)
ctx.addPath(ribbonPath)
ctx.strokePath()
ctx.restoreGState()

// Highlight on top edge of ribbon
ctx.saveGState()
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.addPath(ribbonPath)
ctx.setLineWidth(178)
ctx.replacePathWithStrokedPath()
ctx.clip()
ctx.setFillColor(deepHighlight)
ctx.fill(CGRect(x: 0, y: size * 0.56, width: size, height: size * 0.44))
ctx.restoreGState()

// Center dashed line
ctx.saveGState()
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setStrokeColor(signal)
ctx.setLineWidth(22)
ctx.setLineDash(phase: 0, lengths: [48, 52])
ctx.addPath(ribbonPath)
ctx.strokePath()
ctx.restoreGState()

// === Pothole dot ===
let potholeCenter = CGPoint(x: 456, y: 496)
let potholeRadius: CGFloat = 66

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 18, color: CGColor(gray: 0, alpha: 0.38))
ctx.setFillColor(pothole)
ctx.fillEllipse(in: CGRect(
    x: potholeCenter.x - potholeRadius,
    y: potholeCenter.y - potholeRadius,
    width: potholeRadius * 2,
    height: potholeRadius * 2
))
ctx.restoreGState()

// Pothole gloss
ctx.setFillColor(potholeGloss)
ctx.fillEllipse(in: CGRect(
    x: potholeCenter.x - 36,
    y: potholeCenter.y + 6,
    width: 40,
    height: 26
))

// Signal ring around pothole
ctx.setStrokeColor(color(0xE9A23B, alpha: 0.82))
ctx.setLineWidth(12)
ctx.strokeEllipse(in: CGRect(
    x: potholeCenter.x - potholeRadius - 50,
    y: potholeCenter.y - potholeRadius - 50,
    width: (potholeRadius + 50) * 2,
    height: (potholeRadius + 50) * 2
))

// === Mint smooth tick (top-right) ===
let tickPath = CGMutablePath()
tickPath.move(to: CGPoint(x: 820, y: 836))
tickPath.addLine(to: CGPoint(x: 868, y: 876))
tickPath.addLine(to: CGPoint(x: 940, y: 804))
ctx.saveGState()
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setLineWidth(28)
ctx.setStrokeColor(smooth)
ctx.addPath(tickPath)
ctx.strokePath()
ctx.restoreGState()

// === Subtle "R" monogram bottom-left ===
// Using CoreText for the glyph; flip Y around a transform so our bottom-up
// coordinate system prints the letter right-side up.
let font = CTFontCreateWithName("SFPro-Heavy" as CFString, 160, nil)
let attrs: [CFString: Any] = [
    kCTFontAttributeName: font,
    kCTForegroundColorAttributeName: monogram,
]
let line = CTLineCreateWithAttributedString(
    CFAttributedStringCreate(nil, "R" as CFString, attrs as CFDictionary)
)
ctx.textMatrix = CGAffineTransform(scaleX: 1, y: 1)
ctx.textPosition = CGPoint(x: 96, y: 108)
CTLineDraw(line, ctx)

// MARK: - Write PNG

guard let cgImage = ctx.makeImage() else {
    fatalError("Could not materialize CGImage from context")
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let repoRoot = scriptURL.deletingLastPathComponent()
let outDir = repoRoot
    .appendingPathComponent("ios/RoadSenseNS/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let outFile = outDir.appendingPathComponent("AppIcon-1024.png")
guard let dest = CGImageDestinationCreateWithURL(
    outFile as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else {
    fatalError("Could not create PNG destination")
}
CGImageDestinationAddImage(dest, cgImage, nil)
if !CGImageDestinationFinalize(dest) {
    fatalError("Could not finalize PNG")
}

print("Wrote \(outFile.path)")
