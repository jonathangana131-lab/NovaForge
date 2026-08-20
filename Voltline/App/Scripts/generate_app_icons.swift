#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputDirectory = CommandLine.arguments.dropFirst().first
    ?? "Resources/Assets.xcassets/AppIcon.appiconset"
let outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

struct RGBA {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    init(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    func opacity(_ value: CGFloat) -> RGBA {
        RGBA(red, green, blue, value)
    }
}

struct IconPalette {
    let top: RGBA
    let bottom: RGBA
    let road: RGBA
    let accent: RGBA
    let foreground: RGBA
}

let palettes: [(String, IconPalette)] = [
    ("VoltlineIcon-1024.png", .init(
        top: RGBA(0.02, 0.10, 0.18),
        bottom: RGBA(0.00, 0.025, 0.055),
        road: RGBA(0.11, 0.11, 0.11),
        accent: RGBA(0.05, 0.78, 0.98),
        foreground: RGBA(1, 1, 1)
    )),
    ("VoltlineIcon-Dark-1024.png", .init(
        top: RGBA(0.045, 0.045, 0.045),
        bottom: RGBA(0, 0, 0),
        road: RGBA(0.08, 0.08, 0.08),
        accent: RGBA(0.10, 0.86, 1.0),
        foreground: RGBA(1, 1, 1)
    )),
    ("VoltlineIcon-Tinted-1024.png", .init(
        top: RGBA(0.16, 0.16, 0.16),
        bottom: RGBA(0.04, 0.04, 0.04),
        road: RGBA(0.09, 0.09, 0.09),
        accent: RGBA(1, 1, 1),
        foreground: RGBA(1, 1, 1)
    ))
]

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fill(_ path: CGPath, color: RGBA, context: CGContext) {
    context.addPath(path)
    context.setFillColor(color.cgColor)
    context.fillPath()
}

func stroke(_ path: CGPath, color: RGBA, width: CGFloat, context: CGContext) {
    context.addPath(path)
    context.setStrokeColor(color.cgColor)
    context.setLineWidth(width)
    context.strokePath()
}

func line(_ from: CGPoint, _ to: CGPoint, width: CGFloat, color: RGBA, context: CGContext) {
    context.beginPath()
    context.move(to: from)
    context.addLine(to: to)
    context.setLineCap(.round)
    context.setLineWidth(width)
    context.setStrokeColor(color.cgColor)
    context.strokePath()
}

func circle(center: CGPoint, radius: CGFloat, fillColor: RGBA, strokeColor: RGBA, strokeWidth: CGFloat, context: CGContext) {
    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    context.setFillColor(fillColor.cgColor)
    context.fillEllipse(in: rect)
    context.setStrokeColor(strokeColor.cgColor)
    context.setLineWidth(strokeWidth)
    context.strokeEllipse(in: rect)
}

func generate(filename: String, palette: IconPalette) throws {
    let width = 1024
    let height = 1024
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "VoltlineIcon", code: 1)
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    guard let background = CGGradient(
        colorsSpace: colorSpace,
        colors: [palette.bottom.cgColor, palette.top.cgColor] as CFArray,
        locations: [0, 1]
    ) else {
        throw NSError(domain: "VoltlineIcon", code: 2)
    }
    context.drawLinearGradient(
        background,
        start: CGPoint(x: 512, y: 0),
        end: CGPoint(x: 512, y: 1024),
        options: []
    )

    guard let glow = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            palette.accent.opacity(0).cgColor,
            palette.accent.opacity(0.42).cgColor,
            palette.accent.opacity(0).cgColor
        ] as CFArray,
        locations: [0, 0.52, 1]
    ) else {
        throw NSError(domain: "VoltlineIcon", code: 3)
    }
    context.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: 520, y: 520),
        startRadius: 20,
        endCenter: CGPoint(x: 520, y: 520),
        endRadius: 480,
        options: []
    )

    let road = CGMutablePath()
    road.move(to: CGPoint(x: 260, y: 0))
    road.addLine(to: CGPoint(x: 764, y: 0))
    road.addLine(to: CGPoint(x: 600, y: 610))
    road.addLine(to: CGPoint(x: 424, y: 610))
    road.closeSubpath()
    fill(road, color: palette.road, context: context)

    for index in 0..<5 {
        let y = CGFloat(70 + index * 110)
        let dashWidth = CGFloat(25 + index * 5)
        fill(
            roundedRect(CGRect(x: 512 - dashWidth / 2, y: y, width: dashWidth, height: 66), radius: dashWidth / 2),
            color: palette.foreground.opacity(0.78),
            context: context
        )
    }

    let black = RGBA(0, 0, 0)
    let rear = CGPoint(x: 355, y: 350)
    let front = CGPoint(x: 690, y: 350)
    circle(center: rear, radius: 86, fillColor: black, strokeColor: palette.accent, strokeWidth: 24, context: context)
    circle(center: front, radius: 86, fillColor: black, strokeColor: palette.accent, strokeWidth: 24, context: context)
    circle(center: rear, radius: 22, fillColor: palette.accent, strokeColor: palette.foreground, strokeWidth: 5, context: context)
    circle(center: front, radius: 22, fillColor: palette.accent, strokeColor: palette.foreground, strokeWidth: 5, context: context)

    fill(
        roundedRect(CGRect(x: 360, y: 330, width: 300, height: 52), radius: 22),
        color: palette.foreground,
        context: context
    )
    line(CGPoint(x: 635, y: 370), CGPoint(x: 605, y: 710), width: 38, color: palette.foreground, context: context)
    line(CGPoint(x: 605, y: 710), CGPoint(x: 745, y: 710), width: 34, color: palette.foreground, context: context)
    line(CGPoint(x: 657, y: 705), CGPoint(x: 700, y: 646), width: 23, color: palette.accent, context: context)

    let display = roundedRect(CGRect(x: 570, y: 685, width: 92, height: 62), radius: 21)
    fill(display, color: black, context: context)
    stroke(display, color: palette.accent, width: 7, context: context)

    let bolt = CGMutablePath()
    bolt.move(to: CGPoint(x: 287, y: 800))
    bolt.addLine(to: CGPoint(x: 470, y: 800))
    bolt.addLine(to: CGPoint(x: 390, y: 650))
    bolt.addLine(to: CGPoint(x: 525, y: 650))
    bolt.addLine(to: CGPoint(x: 315, y: 430))
    bolt.addLine(to: CGPoint(x: 370, y: 610))
    bolt.addLine(to: CGPoint(x: 250, y: 610))
    bolt.closeSubpath()
    fill(bolt, color: palette.accent, context: context)

    guard let image = context.makeImage() else {
        throw NSError(domain: "VoltlineIcon", code: 4)
    }
    let destinationURL = outputURL.appendingPathComponent(filename)
    guard let destination = CGImageDestinationCreateWithURL(
        destinationURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw NSError(domain: "VoltlineIcon", code: 5)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "VoltlineIcon", code: 6)
    }
}

for (filename, palette) in palettes {
    try generate(filename: filename, palette: palette)
}
print("Generated Voltline app icon variants in \(outputURL.path)")
