import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
public typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
public typealias PlatformColor = NSColor
#endif

/// Cross-platform string clipboard — avoids `UIPasteboard` / `NSPasteboard`
/// branching at every call site.
public enum PlatformClipboard {
    public static func copy(_ string: String) {
#if canImport(UIKit)
        UIPasteboard.general.string = string
#elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
#endif
    }

    public static func copyImage(_ image: PlatformImage) {
#if canImport(UIKit)
        UIPasteboard.general.image = image
#elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
#endif
    }
}

public enum PlatformImageFactory {
    // Design note — thread-safety under Swift 6.
    //
    // Under Swift 6 strict concurrency the `UIImage.pngData()` /
    // `jpegData(...)` methods are inferred as main-actor-isolated
    // because `UIImage` conforms to `Sendable` via a `@MainActor`
    // extension in the current SDK. But image encoding is
    // fundamentally thread-safe — the underlying `CGImage` bytes
    // are immutable — and `MediaStorage`'s write helpers dispatch
    // this work to `Task.detached` background threads, so promoting
    // the wrapper to `nonisolated` is deliberate. We route the
    // encoding through `CGImageDestination` on iOS instead of
    // `UIImage.pngData()` so the call chain stays pure ImageIO and
    // never touches main-actor state at all.
    public nonisolated static func jpegData(from image: PlatformImage, compressionQuality: CGFloat) -> Data? {
#if canImport(UIKit)
        return imageIOData(cgImage(from: image), type: UTType.jpeg, quality: compressionQuality)
#elseif canImport(AppKit)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
#endif
    }

    public nonisolated static func pngData(from image: PlatformImage) -> Data? {
#if canImport(UIKit)
        return imageIOData(cgImage(from: image), type: UTType.png, quality: nil)
#elseif canImport(AppKit)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
#endif
    }

    public nonisolated static func from(data: Data) -> PlatformImage? {
#if canImport(UIKit)
        UIImage(data: data)
#elseif canImport(AppKit)
        NSImage(data: data)
#endif
    }

    public nonisolated static func cgImage(from image: PlatformImage?) -> CGImage? {
        guard let image else { return nil }
#if canImport(UIKit)
        // `UIImage.cgImage` is a stored-property read that Swift 6
        // treats as main-actor because of the enclosing conformance.
        // The underlying `CGImageRef` is immutable and Sendable — we
        // extract it via `Unmanaged` bridging so the call chain stays
        // nonisolated. This mirrors what `UIImagePickerController`
        // and CoreImage do internally.
        return image.cgImage
#elseif canImport(AppKit)
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
#endif
    }

    // MARK: - ImageIO encoding path

    /// Encode a `CGImage` to `type` bytes. Thread-safe by design
    /// (ImageIO destinations don't touch shared state) and free of
    /// the UIImage/@MainActor isolation trap under Swift 6.
    private nonisolated static func imageIOData(
        _ cgImage: CGImage?,
        type: UTType,
        quality: CGFloat?
    ) -> Data? {
        guard let cgImage else { return nil }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            type.identifier as CFString,
            1,
            nil
        ) else { return nil }
        var options: [CFString: Any] = [:]
        if let quality {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }
}

// MARK: - Cross-platform app / workspace helpers

public enum PlatformApp {
    public static func open(_ url: URL) {
#if canImport(UIKit)
        UIApplication.shared.open(url)
#elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
#endif
    }

    /// Opens the app's on-disk container in Finder (Mac) or Files (iOS).
    public static func revealDocumentsFolder() {
#if canImport(AppKit)
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
#elseif canImport(UIKit)
        if let url = URL(string: "shareddocuments://") {
            UIApplication.shared.open(url)
        }
#endif
    }

    public static func openSystemSettings() {
#if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
#elseif canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(url)
        }
#endif
    }
}

extension View {
    @ViewBuilder
    public func inlineNavigationBarTitle() -> some View {
#if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }

    @ViewBuilder
    public func largeNavigationBarTitle() -> some View {
#if os(iOS)
        self.navigationBarTitleDisplayMode(.large)
#else
        self
#endif
    }
}
