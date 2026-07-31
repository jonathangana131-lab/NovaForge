#!/usr/bin/env swift
import AppKit
import Foundation

let outputDirectory = CommandLine.arguments.dropFirst().first
    ?? "Resources/Assets.xcassets/AppIcon.appiconset"
let outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

struct IconPalette {
    let top: NSColor
    let bottom: NSColor
    let road: NSColor
    let accent: NSColor
    let foreground: NSColor
}

let palettes: [(String, IconPalette)] = [
    ("VoltlineIcon-1024.png", .init(
        top: NSColor(calibratedRed: 0.02, green: 0.10, blue: 0.18, alpha: 1),
        bottom: NSColor(calibratedRed: 0.00, green: 0.025, blue: 0.055, alpha: 1),
        road: NSColor(calibratedWhite: 0.11, alpha: 1),
        accent: NSColor(calibratedRed: 0.05, green: 0.78, blue: 0.98, alpha: 1),
        foreground: .white
    )),
    ("VoltlineIcon-Dark-1024.png", .init(
        top: NSColor(calibratedWhite: 0.045, alpha: 1),
        bottom: .black,
        road: NSColor(calibratedWhite: 0.08, alpha: 1),
        accent: NSColor(calibratedRed: 0.10, green: 0.86, blue: 1.0, alpha: 1),
        foreground: .white
    )),
    ("VoltlineIcon-Tinted-1024.png", .init(
        top: NSColor(calibratedWhite: 0.16, alpha: 1),
        bottom: NSColor(calibratedWhite: 0.04, alpha: 1),
        road: NSColor(calibratedWhite: 0.09, alpha: 1),
        accent: .white,
        foreground: .white
    ))
]

func line(_ from: CGPoint, _ to: CGPoint, width: CGFloat, color: NSColor, cap: NSBezierPath.LineCapStyle = .round) {
    let path = NSBezierPath()
    path.move(to: from)
    path.line(to: to)
    path.lineWidth = width
    path.lineCapStyle = cap
    color.setStroke()
    path.stroke()
}

func circle(center: CGPoint, radius: CGFloat, fill: NSColor, stroke: NSColor, strokeWidth: CGFloat) {
    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    let path = NSBezierPath(ovalIn: rect)
    fill.setFill()
    path.fill()
    stroke.setStroke()
    path.lineWidth = strokeWidth
    path.stroke()
}

func generate(filename: String, palette: IconPalette) throws {
    let size = NSSize(width: 1024, height: 1024)
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else {
        throw NSError(domain: "VoltlineIcon", code: 1)
    }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [palette.top.cgColor, palette.bottom.cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 512, y: 1024),
        end: CGPoint(x: 512, y: 0),
        options: []
    )

    // Speed glow.
    let glowColors = [palette.accent.withAlphaComponent(0.0).cgColor,
                      palette.accent.withAlphaComponent(0.42).cgColor,
                      palette.accent.withAlphaComponent(0.0).cgColor] as CFArray
    let glow = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0, 0.5, 1])!
    context.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: 520, y: 520),
        startRadius: 30,
        endCenter: CGPoint(x: 520, y: 520),
        endRadius: 470,
        options: []
    )

    // Perspective road.
    let road = NSBezierPath()
    road.move(to: CGPoint(x: 260, y: 0))
    road.line(to: CGPoint(x: 764, y: 0))
    road.line(to: CGPoint(x: 600, y: 610))
    road.line(to: CGPoint(x: 424, y: 610))
    road.close()
    palette.road.setFill()
    road.fill()

    for index in 0..<5 {
        let y = CGFloat(70 + index * 110)
        let width = CGFloat(25 + index * 5)
        let dash = NSBezierPath(roundedRect: CGRect(x: 512 - width / 2, y: y, width: width, height: 66), xRadius: width / 2, yRadius: width / 2)
        palette.foreground.withAlphaComponent(0.78).setFill()
        dash.fill()
    }

    // Scooter silhouette.
    let rear = CGPoint(x: 355, y: 350)
    let front = CGPoint(x: 690, y: 350)
    circle(center: rear, radius: 86, fill: .black, stroke: palette.accent, strokeWidth: 24)
    circle(center: front, radius: 86, fill: .black, stroke: palette.accent, strokeWidth: 24)
    circle(center: rear, radius: 22, fill: palette.accent, stroke: palette.foreground, strokeWidth: 5)
    circle(center: front, radius: 22, fill: palette.accent, stroke: palette.foreground, strokeWidth: 5)

    let deck = NSBezierPath(roundedRect: CGRect(x: 360, y: 330, width: 300, height: 52), xRadius: 22, yRadius: 22)
    palette.foreground.setFill()
    deck.fill()
    line(CGPoint(x: 635, y: 370), CGPoint(x: 605, y: 710), width: 38, color: palette.foreground)
    line(CGPoint(x: 605, y: 710), CGPoint(x: 745, y: 710), width: 34, color: palette.foreground)
    line(CGPoint(x: 657, y: 705), CGPoint(x: 700, y: 646), width: 23, color: palette.accent)

    let display = NSBezierPath(roundedRect: CGRect(x: 570, y: 685, width: 92, height: 62), xRadius: 21, yRadius: 21)
    NSColor.black.setFill()
    display.fill()
    palette.accent.setStroke()
    display.lineWidth = 7
    display.stroke()

    // Electric bolt / V mark.
    let bolt = NSBezierPath()
    bolt.move(to: CGPoint(x: 287, y: 800))
    bolt.line(to: CGPoint(x: 470, y: 800))
    bolt.line(to: CGPoint(x: 390, y: 650))
    bolt.line(to: CGPoint(x: 525, y: 650))
    bolt.line(to: CGPoint(x: 315, y: 430))
    bolt.line(to: CGPoint(x: 370, y: 610))
    bolt.line(to: CGPoint(x: 250, y: 610))
    bolt.close()
    palette.accent.setFill()
    bolt.fill()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "VoltlineIcon", code: 2)
    }
    try png.write(to: outputURL.appendingPathComponent(filename), options: .atomic)
}

for (filename, palette) in palettes {
    try generate(filename: filename, palette: palette)
}
print("Generated Voltline app icon variants in \(outputURL.path)")
