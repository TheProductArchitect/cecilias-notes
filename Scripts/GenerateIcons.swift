#!/usr/bin/env xcrun swift -sdk $(xcrun --sdk iphonesimulator --show-sdk-path) -target arm64-apple-ios17.0-simulator
// Run with: chmod +x Scripts/GenerateIcons.swift && ./Scripts/GenerateIcons.swift
// Requires Xcode command line tools. Uses the iOS simulator SDK for UIKit access.
// If that target fails on Apple Silicon, try: arm64-apple-ios17.0-macabi
import Foundation
import UIKit
import CoreGraphics

// ─────────────────────────────────────────
// MARK: - Icon Theme
// ─────────────────────────────────────────

struct IconTheme {
    var background: UIColor
    var foreground: UIColor
    var accentDot: UIColor

    static let light = IconTheme(
        background: UIColor(red: 0.980, green: 0.980, blue: 0.973, alpha: 1), // #FAFAF8
        foreground: UIColor(red: 0.114, green: 0.114, blue: 0.106, alpha: 1), // #1D1D1B
        accentDot:  UIColor(red: 0.000, green: 0.478, blue: 1.000, alpha: 1)  // #007AFF
    )
    static let dark = IconTheme(
        background: UIColor(red: 0.067, green: 0.067, blue: 0.063, alpha: 1), // #111110
        foreground: UIColor(red: 0.961, green: 0.961, blue: 0.949, alpha: 1), // #F5F5F2
        accentDot:  UIColor(red: 0.039, green: 0.518, blue: 1.000, alpha: 1)  // #0A84FF
    )
    static let tinted = IconTheme(
        background: UIColor.systemBackground,
        foreground: UIColor.label,
        accentDot:  UIColor.systemBlue
    )
}

// ─────────────────────────────────────────
// MARK: - Renderer
// ─────────────────────────────────────────

func renderIcon(size: CGSize, theme: IconTheme, cornerRadius: CGFloat) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { ctx in
        let cgCtx = ctx.cgContext
        let bounds = CGRect(origin: .zero, size: size)
        let scale  = size.width / 100.0

        // Background
        let bgPath = UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius)
        theme.background.setFill()
        bgPath.fill()

        // Scale coordinate space to 100×100
        cgCtx.scaleBy(x: scale, y: scale)

        // ── Ink drop body (stem of the i) ──
        // Teardrop: tip at (50,78), bulges symmetrically to max ~18pt wide at y≈45
        let drop = CGMutablePath()
        drop.move(to: CGPoint(x: 50, y: 78))
        drop.addCurve(
            to:       CGPoint(x: 32, y: 44),
            control1: CGPoint(x: 50, y: 72),
            control2: CGPoint(x: 32, y: 60)
        )
        drop.addCurve(
            to:       CGPoint(x: 50, y: 30),
            control1: CGPoint(x: 32, y: 30),
            control2: CGPoint(x: 38, y: 26)
        )
        drop.addCurve(
            to:       CGPoint(x: 68, y: 44),
            control1: CGPoint(x: 62, y: 26),
            control2: CGPoint(x: 68, y: 30)
        )
        drop.addCurve(
            to:       CGPoint(x: 50, y: 78),
            control1: CGPoint(x: 68, y: 60),
            control2: CGPoint(x: 50, y: 72)
        )
        drop.closeSubpath()
        cgCtx.addPath(drop)
        cgCtx.setFillColor(theme.foreground.cgColor)
        cgCtx.fillPath()

        // ── Accent dot (the dot of the i) ──
        let dotRect = CGRect(x: 43, y: 12, width: 14, height: 14)
        cgCtx.setFillColor(theme.accentDot.cgColor)
        cgCtx.fillEllipse(in: dotRect)
    }
}

// ─────────────────────────────────────────
// MARK: - Sizes
// ─────────────────────────────────────────

struct IconSpec {
    let size: CGFloat
    let filename: String
    let theme: IconTheme
}

let specs: [IconSpec] = [
    // Light
    IconSpec(size: 1024, filename: "AppIcon-1024",      theme: .light),
    IconSpec(size: 180,  filename: "AppIcon-60@3x",     theme: .light),
    IconSpec(size: 120,  filename: "AppIcon-60@2x",     theme: .light),
    IconSpec(size: 167,  filename: "AppIcon-83.5@2x",   theme: .light),
    IconSpec(size: 152,  filename: "AppIcon-76@2x",     theme: .light),
    IconSpec(size: 87,   filename: "AppIcon-29@3x",     theme: .light),
    IconSpec(size: 80,   filename: "AppIcon-40@2x",     theme: .light),
    IconSpec(size: 58,   filename: "AppIcon-29@2x",     theme: .light),
    // Dark
    IconSpec(size: 1024, filename: "AppIcon-1024-dark",    theme: .dark),
    IconSpec(size: 180,  filename: "AppIcon-60@3x-dark",   theme: .dark),
    IconSpec(size: 120,  filename: "AppIcon-60@2x-dark",   theme: .dark),
    IconSpec(size: 167,  filename: "AppIcon-83.5@2x-dark", theme: .dark),
    IconSpec(size: 152,  filename: "AppIcon-76@2x-dark",   theme: .dark),
    IconSpec(size: 87,   filename: "AppIcon-29@3x-dark",   theme: .dark),
    IconSpec(size: 80,   filename: "AppIcon-40@2x-dark",   theme: .dark),
    IconSpec(size: 58,   filename: "AppIcon-29@2x-dark",   theme: .dark),
    // Tinted (iOS 18 monochrome)
    IconSpec(size: 1024, filename: "AppIcon-1024-tinted",    theme: .tinted),
    IconSpec(size: 180,  filename: "AppIcon-60@3x-tinted",   theme: .tinted),
    IconSpec(size: 120,  filename: "AppIcon-60@2x-tinted",   theme: .tinted),
]

// ─────────────────────────────────────────
// MARK: - Output path
// ─────────────────────────────────────────

let scriptDir   = URL(fileURLWithPath: #file).deletingLastPathComponent()
let repoRoot    = scriptDir.deletingLastPathComponent()
let appiconDir  = repoRoot
    .appendingPathComponent("Ink/Ink/Resources/Assets.xcassets/AppIcon.appiconset")

try FileManager.default.createDirectory(at: appiconDir,
    withIntermediateDirectories: true)

// ─────────────────────────────────────────
// MARK: - Generate
// ─────────────────────────────────────────

var written = 0
for spec in specs {
    let cgSize = CGSize(width: spec.size, height: spec.size)
    let radius = spec.size * 0.2237
    let image  = renderIcon(size: cgSize, theme: spec.theme, cornerRadius: radius)
    guard let data = image.pngData() else {
        print("⚠️  Could not get PNG data for \(spec.filename)")
        continue
    }
    let url = appiconDir.appendingPathComponent("\(spec.filename).png")
    try data.write(to: url)
    print("✅ \(spec.filename).png  (\(Int(spec.size))pt)")
    written += 1
}

print("\n🎉 Done — \(written) PNGs written to:")
print("   \(appiconDir.path)")
