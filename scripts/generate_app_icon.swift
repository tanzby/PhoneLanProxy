#!/usr/bin/env swift
// Draws the PhoneLanProxy app icon (a router with two antennas, signal arcs
// and status LEDs) in the three iOS appearances and writes the asset catalog
// icon set.
//
// The glyph is drawn from paths on purpose: SF Symbols may not be used in app
// icons under their license.
//
// Usage: swift scripts/generate_app_icon.swift [App/Assets.xcassets/AppIcon.appiconset]

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let canvas = CGFloat(size)

enum Variant: CaseIterable {
    case light
    case dark
    case tinted

    var filename: String {
        switch self {
        case .light: return "AppIcon-Light.png"
        case .dark: return "AppIcon-Dark.png"
        case .tinted: return "AppIcon-Tinted.png"
        }
    }
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// Layout numbers below use a top-left origin; these convert to Core Graphics.
func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(x: x, y: canvas - y - height, width: width, height: height)
}

func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: x, y: canvas - y)
}

func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> CGRect {
    rect(x - radius, y - radius, radius * 2, radius * 2)
}

func linearGradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: colors as CFArray,
        locations: nil
    )!
}

/// Router silhouette: body, antennas, signal source and two arcs.
func routerPath() -> CGPath {
    let path = CGMutablePath()
    path.addPath(CGPath(roundedRect: rect(202, 530, 620, 240), cornerWidth: 80, cornerHeight: 80, transform: nil))
    path.addPath(CGPath(roundedRect: rect(282, 300, 48, 260), cornerWidth: 24, cornerHeight: 24, transform: nil))
    path.addPath(CGPath(roundedRect: rect(694, 300, 48, 260), cornerWidth: 24, cornerHeight: 24, transform: nil))
    path.addEllipse(in: circle(512, 448, 34))

    for radius: CGFloat in [92, 172] {
        let arc = CGMutablePath()
        arc.addArc(
            center: point(512, 448),
            radius: radius,
            startAngle: .pi * 50 / 180,
            endAngle: .pi * 130 / 180,
            clockwise: false
        )
        path.addPath(arc.copy(strokingWithWidth: 46, lineCap: .round, lineJoin: .round, miterLimit: 10))
    }
    return path
}

struct Palette {
    var background: [CGColor]?
    var glyph: [CGColor]
    var glyphShadow: CGColor?
    var socket: CGColor
    var led: CGColor

    static func forVariant(_ variant: Variant) -> Palette {
        switch variant {
        case .light:
            return Palette(
                background: [color(0x1B6CF2), color(0x12B8A6)],
                glyph: [color(0xFFFFFF), color(0xE3EEFF)],
                glyphShadow: color(0x0A2A5E, 0.35),
                socket: color(0x0B2545),
                led: color(0x34C759)
            )
        case .dark:
            // Transparent background: the system supplies the dark backdrop.
            return Palette(
                background: nil,
                glyph: [color(0x6FD3FF), color(0x2FD8C0)],
                glyphShadow: nil,
                socket: color(0x0B2545),
                led: color(0x34C759)
            )
        case .tinted:
            // Grayscale; the system applies the user's tint by luminance.
            return Palette(
                background: nil,
                glyph: [color(0xFFFFFF), color(0xE6E6E6)],
                glyphShadow: nil,
                socket: color(0x1C1C1C),
                led: color(0x9A9A9A)
            )
        }
    }
}

func render(_ variant: Variant) -> CGImage {
    let palette = Palette.forVariant(variant)
    // The light icon must be opaque (no alpha channel); the others need it.
    let alphaInfo: CGImageAlphaInfo = palette.background == nil ? .premultipliedLast : .noneSkipLast
    let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: alphaInfo.rawValue
    )!
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    if let background = palette.background {
        context.drawLinearGradient(
            linearGradient(background),
            start: point(0, 0),
            end: point(canvas, canvas),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    } else {
        context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    }

    let glyph = routerPath()

    if let shadowColor = palette.glyphShadow {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: shadowColor)
        context.addPath(glyph)
        context.setFillColor(palette.glyph[0])
        context.fillPath()
        context.restoreGState()
    }

    context.saveGState()
    context.addPath(glyph)
    context.clip()
    context.drawLinearGradient(
        linearGradient(palette.glyph),
        start: point(512, 250),
        end: point(512, 780),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.restoreGState()

    // Status LEDs sit in dark sockets so they read on any glyph color.
    for x: CGFloat in [310, 395, 480] {
        context.setFillColor(palette.socket)
        context.fillEllipse(in: circle(x, 650, 31))
        context.setFillColor(palette.led)
        context.fillEllipse(in: circle(x, 650, 21))
    }
    context.setFillColor(palette.socket)
    context.addPath(CGPath(roundedRect: rect(578, 632, 166, 36), cornerWidth: 18, cornerHeight: 18, transform: nil))
    context.fillPath()

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

let contentsJSON = """
{
  "images" : [
    {
      "filename" : "AppIcon-Light.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "AppIcon-Dark.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "tinted"
        }
      ],
      "filename" : "AppIcon-Tinted.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""

let outputPath = CommandLine.arguments.dropFirst().first ?? "App/Assets.xcassets/AppIcon.appiconset"
let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for variant in Variant.allCases {
    let url = outputDirectory.appendingPathComponent(variant.filename)
    try writePNG(render(variant), to: url)
    print("wrote \(url.path)")
}
try contentsJSON.write(
    to: outputDirectory.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)
print("wrote \(outputDirectory.appendingPathComponent("Contents.json").path)")
