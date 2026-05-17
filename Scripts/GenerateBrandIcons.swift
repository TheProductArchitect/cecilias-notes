#!/usr/bin/env swift
//
// Scripts/GenerateBrandIcons.swift
//
// One-off generator that produces the 26 × 7 = 182 alternate-app-icon
// PNGs (one per Latin lowercase letter at every iOS-required pixel
// size). Output goes to `CeciliasNotes/CeciliasNotes/Resources/AppIcons/Icon-<letter>-<size>.png`
// and `Icon-<letter>.png` is also written for the size iOS expects to
// find at the bare key name (1024×1024 master).
//
// Usage
//   swift Scripts/GenerateBrandIcons.swift
//
// Run once after dropping `BricolageGrotesque-VariableFont_*.ttf` into
// `CeciliasNotes/CeciliasNotes/Resources/Fonts/`. The script registers the font from disk
// at runtime via CoreText so it doesn't need to live inside an app
// bundle. If the font isn't present, the script falls back to the
// system bold (San Francisco) so you still get usable placeholder
// icons — re-run after the font lands to regenerate.
//
// Once generated, commit the contents of `CeciliasNotes/CeciliasNotes/Resources/AppIcons/`
// into the repo. iOS expects them on disk at app launch — runtime
// generation isn't supported by `setAlternateIconName`.

import AppKit
import CoreGraphics
import CoreText
import Foundation

// MARK: - Config

/// Dot colour comes from the design system's existing accent (#007AFF /
/// #0A84FF). The script uses the light-mode value because app icons
/// don't theme on iOS — the same icon ships for light and dark.
let backgroundHex = "#F4F3EE"
let letterHex     = "#06060A"
let dotHex        = "#007AFF"

let outputSizes: [CGFloat] = [60, 76, 83.5, 120, 152, 167, 1024]
let letters: [Character] = (UnicodeScalar("a").value...UnicodeScalar("z").value)
    .compactMap { UnicodeScalar($0).map { Character($0) } }

// MARK: - Paths

let scriptURL  = URL(fileURLWithPath: CommandLine.arguments[0])
let scriptDir  = scriptURL.deletingLastPathComponent()
let repoRoot   = scriptDir.deletingLastPathComponent()
let fontDir    = repoRoot.appendingPathComponent("CeciliasNotes/CeciliasNotes/Resources/Fonts")
let outputDir  = repoRoot.appendingPathComponent("CeciliasNotes/CeciliasNotes/Resources/AppIcons")

try? FileManager.default.createDirectory(at: outputDir,
                                         withIntermediateDirectories: true)

// MARK: - Font registration

func registerBricolage() -> String? {
    guard FileManager.default.fileExists(atPath: fontDir.path) else { return nil }
    let candidates = (try? FileManager.default
        .contentsOfDirectory(at: fontDir, includingPropertiesForKeys: nil)) ?? []
    let ttfs = candidates.filter { $0.pathExtension.lowercased() == "ttf" }
    for url in ttfs where url.lastPathComponent.contains("Bricolage") {
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            else { continue }
        // Find the registered PostScript name. Variable fonts often
        // expose a single "Bold" name or use a default style.
        if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] {
            for d in descriptors {
                if let name = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String {
                    if name.lowercased().contains("bold") { return name }
                }
            }
            // No explicit Bold variant — return the first descriptor's name.
            if let first = descriptors.first,
               let name  = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String {
                return name
            }
        }
    }
    return nil
}

let resolvedFontName: String? = registerBricolage()
if let name = resolvedFontName {
    print("[icons] Registered font: \(name)")
} else {
    print("[icons] Bricolage Grotesque not found — falling back to system bold.")
}

// MARK: - Colour helper

func nsColor(hex: String) -> NSColor {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    let v = UInt32(s, radix: 16) ?? 0
    let r = CGFloat((v >> 16) & 0xFF) / 255
    let g = CGFloat((v >>  8) & 0xFF) / 255
    let b = CGFloat( v        & 0xFF) / 255
    return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

// MARK: - Render

func renderIcon(letter: Character, size: CGFloat) -> CGImage? {
    let pixelSize = Int(size)
    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // 1. Background.
    ctx.setFillColor(nsColor(hex: backgroundHex).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

    // 2. Compose letter + dot via CoreText so kerning & baseline match.
    let fontSize: CGFloat = size * 0.78
    let baseFont: CTFont = {
        if let name = resolvedFontName {
            return CTFontCreateWithName(name as CFString, fontSize, nil)
        }
        // Fallback: macOS bold system font. The PostScript name path
        // returns a usable font even without registration.
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: "Helvetica Neue",
            kCTFontStyleNameAttribute:  "Bold",
        ] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, fontSize, nil)
    }()

    let kern = NSNumber(value: Double(-0.03 * fontSize))

    let letterAttr: [NSAttributedString.Key: Any] = [
        .font: baseFont,
        .foregroundColor: nsColor(hex: letterHex),
        .kern: kern,
    ]
    let dotAttr: [NSAttributedString.Key: Any] = [
        .font: baseFont,
        .foregroundColor: nsColor(hex: dotHex),
        .kern: kern,
    ]

    let composed = NSMutableAttributedString()
    composed.append(NSAttributedString(string: String(letter).lowercased(),
                                       attributes: letterAttr))
    composed.append(NSAttributedString(string: ".", attributes: dotAttr))

    let line = CTLineCreateWithAttributedString(composed)
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let typoWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

    let drawX = (size - typoWidth) / 2
    let drawY = (size - (ascent - descent)) / 2  // baseline placement

    // CoreText origin is bottom-left in CG context. We're rendering into
    // a CGContext with default y-up orientation here, so place the
    // baseline directly without flipping.
    ctx.textPosition = CGPoint(x: drawX, y: drawY)
    CTLineDraw(line, ctx)

    return ctx.makeImage()
}

// MARK: - Write

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GenerateBrandIcons", code: 1)
    }
    try data.write(to: url)
}

print("[icons] Output → \(outputDir.path)")

var written = 0
for letter in letters {
    for size in outputSizes {
        guard let image = renderIcon(letter: letter, size: size) else { continue }
        // Filename pattern: Icon-a-120.png, Icon-z-1024.png. The bare
        // `Icon-a.png` (no size) points at the 1024 master so iOS can
        // resolve `<base name>` → image.
        let suffix = size == 83.5 ? "835" : String(Int(size))
        let url = outputDir.appendingPathComponent("Icon-\(letter)-\(suffix).png")
        try writePNG(image, to: url)
        written += 1
        // Also write Icon-<letter>.png (= 1024×1024) for the bare key.
        if size == 1024 {
            let bareURL = outputDir.appendingPathComponent("Icon-\(letter).png")
            try writePNG(image, to: bareURL)
            written += 1
        }
    }
}

print("[icons] Wrote \(written) PNGs.")
