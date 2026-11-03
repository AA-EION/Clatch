// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import AppKit
import ClatchCore
import ImageIO
import UniformTypeIdentifiers

/// Profile icons: the installed Claude's own icon with a coloured badge
/// holding the profile's letter (or emoji). Drawn on this Mac from the app
/// that is installed, so Clatch never ships Anthropic's artwork.
@MainActor
enum ProfileIcons {
    private static var cache: [String: NSImage] = [:]

    /// The base picture: Claude's icon, or Clatch's own if Claude is missing.
    static func baseIcon() -> NSImage {
        if let url = ClaudeApp.url { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSApp.applicationIconImage
    }

    static func color(for account: Account) -> NSColor {
        NSColor(hex: account.resolvedColorHex) ?? .systemOrange
    }

    /// The badged icon at a given point size (cached per profile look), drawn at 2× for Retina.
    static func icon(for account: Account, size: CGFloat) -> NSImage {
        let key = "\(account.badgeText)|\(account.resolvedColorHex)|\(Int(size))|\(ClaudeApp.url?.path ?? "")"
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: size, height: size))
        if let rep = render(account, pixels: Int(size * 2)) {
            rep.size = NSSize(width: size, height: size)
            image.addRepresentation(rep)
        }
        cache[key] = image
        return image
    }

    /// Draws the badged icon into a bitmap of the given pixel size.
    static func render(_ account: Account, pixels: Int) -> NSBitmapImageRep? {
        guard pixels > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        baseIcon().draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)

        // Badge in the lower right corner, over a soft shadow, with a white ring.
        let diameter = rect.width * 0.5
        let badge = NSRect(x: rect.maxX - diameter - rect.width * 0.02, y: rect.minY + rect.height * 0.02,
                           width: diameter, height: diameter)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = rect.width * 0.03
        shadow.shadowOffset = NSSize(width: 0, height: -rect.width * 0.01)
        shadow.set()
        color(for: account).setFill()
        NSBezierPath(ovalIn: badge).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: badge.insetBy(dx: rect.width * 0.012, dy: rect.width * 0.012))
        ring.lineWidth = max(1, rect.width * 0.024)
        ring.stroke()

        let text = account.badgeText
        let fontSize = diameter * (text.count > 1 ? 0.42 : 0.56)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? font
        let label = NSAttributedString(string: text, attributes: [.font: rounded, .foregroundColor: NSColor.white])
        let size = label.size()
        label.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func clearCache() { cache.removeAll() }

    /// Writes an .icns with every size macOS uses (for the profile launchers).
    static func writeICNS(for account: Account, to url: URL) throws {
        let sizes: [CGFloat] = [16, 32, 64, 128, 256, 512, 1024]
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, sizes.count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for size in sizes {
            if let cgImage = render(account, pixels: Int(size))?.cgImage {
                CGImageDestinationAddImage(destination, cgImage, nil)
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let body = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard body.count == 6, let value = UInt32(body, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
