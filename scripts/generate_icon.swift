#!/usr/bin/env swift
// generate_icon.swift — renders the AppIcon at every macOS-required size and
// writes them as PNGs to <out>/icon_<size>x<size>.png and a 2x companion.
//
// Design: indigo→violet gradient squircle background, glass-style highlight,
// central 270° gauge dial in green with a tick ring, white needle pointing at
// 67%, "AI" wordmark below. Renders crisply from 16px to 1024px.
//
// Usage: swift scripts/generate_icon.swift <output-dir>

import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: generate_icon.swift <output-dir>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// macOS .iconset required entries (size@scale).
let icnsEntries: [(name: String, size: CGFloat)] = [
    ("icon_16x16.png",     16),
    ("icon_16x16@2x.png",  32),
    ("icon_32x32.png",     32),
    ("icon_32x32@2x.png",  64),
    ("icon_128x128.png",  128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",  256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",  512),
    ("icon_512x512@2x.png", 1024),
]

// MARK: - Drawing

func draw(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    defer { img.unlockFocus() }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return img }

    // Background — Apple's squircle. Corner radius ≈ 0.225 of side.
    let cornerRadius = size * 0.225
    let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
    ctx.saveGState()
    let bgPath = CGPath(roundedRect: bgRect,
                        cornerWidth: cornerRadius,
                        cornerHeight: cornerRadius,
                        transform: nil)
    ctx.addPath(bgPath); ctx.clip()

    // Diagonal gradient: deep indigo → vivid purple.
    let cs = CGColorSpaceCreateDeviceRGB()
    let bgGradient = CGGradient(
        colorsSpace: cs,
        colors: [
            NSColor(srgbRed: 0.10, green: 0.07, blue: 0.26, alpha: 1).cgColor,
            NSColor(srgbRed: 0.42, green: 0.21, blue: 0.78, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(bgGradient,
                           start: CGPoint(x: 0, y: size),
                           end: CGPoint(x: size, y: 0),
                           options: [])

    // Soft glass highlight along the top.
    let highlightGradient = CGGradient(
        colorsSpace: cs,
        colors: [
            NSColor(white: 1.0, alpha: 0.18).cgColor,
            NSColor(white: 1.0, alpha: 0.00).cgColor,
        ] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(highlightGradient,
                           start: CGPoint(x: 0, y: size),
                           end: CGPoint(x: 0, y: size * 0.55),
                           options: [])
    ctx.restoreGState()

    // Gauge geometry. The dial sits centered slightly above middle so the
    // "AI" wordmark fits below without overlap. 270° sweep open at bottom.
    let gaugeCenter = CGPoint(x: size / 2, y: size * 0.54)
    let gaugeRadius = size * 0.27
    // Use angles in math convention (Y up, 0=right, π/2=up).
    // `clockwise: false` traces clockwise visually = angle decreasing.
    let startAngle: CGFloat = .pi * 1.25    // 225° lower-left
    let endAngle:   CGFloat = -.pi * 0.25   // -45° = 315° lower-right
    let sweep: CGFloat      = startAngle - endAngle   // 270° (3π/2)
    // Helper: position along the arc for a 0…1 progress (0 = start, 1 = end).
    let angleFor: (CGFloat) -> CGFloat = { progress in
        startAngle - sweep * progress
    }

    // Tick-mark ring around the gauge — 11 ticks, longer at quartiles.
    ctx.saveGState()
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.45).cgColor)
    let tickInner = gaugeRadius * 1.06
    let tickOuter = gaugeRadius * 1.16
    let tickLong  = gaugeRadius * 1.20
    for i in 0...10 {
        let frac = CGFloat(i) / 10.0
        let a = angleFor(frac)
        let isMajor = (i % 5 == 0)
        let outer = isMajor ? tickLong : tickOuter
        let p1 = CGPoint(x: gaugeCenter.x + cos(a) * tickInner,
                         y: gaugeCenter.y + sin(a) * tickInner)
        let p2 = CGPoint(x: gaugeCenter.x + cos(a) * outer,
                         y: gaugeCenter.y + sin(a) * outer)
        ctx.setLineWidth(size * (isMajor ? 0.018 : 0.012))
        ctx.move(to: p1); ctx.addLine(to: p2); ctx.strokePath()
    }
    ctx.restoreGState()

    // Background arc (unused portion). `clockwise: false` traces the LONG way
    // around (through the top), which is what a speedometer needs — the
    // opening should be at the bottom.
    ctx.saveGState()
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.18).cgColor)
    ctx.setLineWidth(size * 0.07)
    ctx.setLineCap(.round)
    ctx.addArc(center: gaugeCenter, radius: gaugeRadius,
               startAngle: startAngle, endAngle: endAngle, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()

    // Filled arc (67% — visually consistent with the SF Symbol we use).
    let progress: CGFloat = 0.67
    let activeEndAngle = angleFor(progress)
    ctx.saveGState()
    let arcGradient = CGGradient(
        colorsSpace: cs,
        colors: [
            NSColor(srgbRed: 0.21, green: 0.92, blue: 0.61, alpha: 1).cgColor,
            NSColor(srgbRed: 0.10, green: 0.69, blue: 0.50, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 1])!
    ctx.setLineWidth(size * 0.07)
    ctx.setLineCap(.round)
    ctx.addArc(center: gaugeCenter, radius: gaugeRadius,
               startAngle: startAngle, endAngle: activeEndAngle, clockwise: false)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(arcGradient,
                           start: CGPoint(x: 0, y: size * 0.8),
                           end: CGPoint(x: size, y: size * 0.2),
                           options: [])
    ctx.restoreGState()

    // Needle — points OUTWARD at the active arc endpoint, with a small tail.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.005),
                  blur: size * 0.012,
                  color: NSColor(white: 0, alpha: 0.45).cgColor)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(size * 0.028)
    ctx.setLineCap(.round)
    let needleLength = gaugeRadius * 0.92
    let needleTip = CGPoint(
        x: gaugeCenter.x + cos(activeEndAngle) * needleLength,
        y: gaugeCenter.y + sin(activeEndAngle) * needleLength
    )
    // Small tail past the center hub, on the opposite side, for a balanced
    // dial-needle silhouette.
    let needleTail = CGPoint(
        x: gaugeCenter.x - cos(activeEndAngle) * (gaugeRadius * 0.20),
        y: gaugeCenter.y - sin(activeEndAngle) * (gaugeRadius * 0.20)
    )
    ctx.move(to: needleTail); ctx.addLine(to: needleTip); ctx.strokePath()
    ctx.restoreGState()

    // Central hub — white circle with subtle inner shadow.
    ctx.saveGState()
    let hubRadius = size * 0.045
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: gaugeCenter.x - hubRadius,
                               y: gaugeCenter.y - hubRadius,
                               width: hubRadius * 2,
                               height: hubRadius * 2))
    ctx.setFillColor(NSColor(srgbRed: 0.42, green: 0.21, blue: 0.78, alpha: 1).cgColor)
    let innerRadius = hubRadius * 0.45
    ctx.fillEllipse(in: CGRect(x: gaugeCenter.x - innerRadius,
                               y: gaugeCenter.y - innerRadius,
                               width: innerRadius * 2,
                               height: innerRadius * 2))
    ctx.restoreGState()

    // Wordmark "AI" — heavy, slightly tracked, sits in the open mouth of
    // the gauge (between the two arc endpoints) so there's no overlap.
    let fontSize = size * 0.14
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
        .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        .kern: fontSize * 0.06,
    ]
    let label = NSAttributedString(string: "AI", attributes: attrs)
    let labelSize = label.size()
    // Place the label inside the bottom opening of the gauge.
    label.draw(at: CGPoint(x: (size - labelSize.width) / 2,
                           y: size * 0.07))

    return img
}

// MARK: - Save

func savePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "iconGen", code: 1)
    }
    try png.write(to: url)
}

for entry in icnsEntries {
    let img = draw(size: entry.size)
    let url = outDir.appendingPathComponent(entry.name)
    try savePNG(img, to: url)
    FileHandle.standardOutput.write(Data("Wrote \(url.lastPathComponent) (\(Int(entry.size))px)\n".utf8))
}
