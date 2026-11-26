// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import CGtk
import ClatchCore
import Foundation

/// Profile icons: Claude's own icon with a round badge (the profile's letter
/// or emoji, in its colour) on the corner. Drawn with cairo and pango and
/// cached as PNG in ~/.local/share/Clatch/icons, keyed by the look, so a
/// launcher keeps pointing at a stable file until the profile changes.
@MainActor
enum ProfileIcons {
    static var folder: URL {
        ClatchPaths.xdg("XDG_DATA_HOME", ".local/share").appendingPathComponent("Clatch/icons", isDirectory: true)
    }

    /// The 256 px icon for a profile (drawn when missing).
    static func png(for account: Account) -> String {
        let base = Claude.iconFile
        let stamp = base.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
            .map { Int($0.timeIntervalSince1970) } ?? 0
        let look = "\(account.badgeText)|\(account.resolvedColorHex)|\(base ?? "")|\(stamp)"
        let hash = look.unicodeScalars.reduce(UInt32(17)) { ($0 &* 31) &+ $1.value }
        let file = folder.appendingPathComponent("\(account.id.uuidString.lowercased())-\(String(hash, radix: 16)).png")
        if !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            render(account, base: base, size: 256, to: file.path)
            prune(account, keeping: file.lastPathComponent)
        }
        return file.path
    }

    /// Removes a profile's older icons (or all of them, for a removed profile).
    static func prune(_ account: Account, keeping: String? = nil) {
        let prefix = account.id.uuidString.lowercased() + "-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix(prefix) && name != keeping {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private static func render(_ account: Account, base: String?, size: Int32, to path: String) {
        guard let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, size, size), let cr = cairo_create(surface) else { return }
        defer { cairo_destroy(cr); cairo_surface_destroy(surface) }
        let s = Double(size)

        // Claude's icon, scaled to fit.
        if let base, let icon = cairo_image_surface_create_from_png(base),
           cairo_surface_status(icon) == CAIRO_STATUS_SUCCESS {
            let w = Double(cairo_image_surface_get_width(icon)), h = Double(cairo_image_surface_get_height(icon))
            cairo_save(cr)
            let scale = s / max(w, h)
            cairo_scale(cr, scale, scale)
            cairo_set_source_surface(cr, icon, (max(w, h) - w) / 2, (max(w, h) - h) / 2)
            cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_BEST)
            cairo_paint(cr)
            cairo_restore(cr)
            cairo_surface_destroy(icon)
        } else {
            // No Claude icon found: a rounded square in Claude's colour.
            roundedRect(cr, 0.06 * s, 0.06 * s, 0.88 * s, 0.88 * s, 0.2 * s)
            cairo_set_source_rgb(cr, 0.85, 0.47, 0.34)
            cairo_fill(cr)
        }

        // The badge: a circle on the lower right with a ring that separates it from the icon.
        let radius = 0.24 * s, cx = s - radius - 0.02 * s, cy = s - radius - 0.02 * s
        cairo_arc(cr, cx, cy, radius + 0.035 * s, 0, 2 * .pi)
        cairo_set_source_rgba(cr, 1, 1, 1, 0.95)
        cairo_fill(cr)
        let (r, g, b) = rgb(account.resolvedColorHex)
        cairo_arc(cr, cx, cy, radius, 0, 2 * .pi)
        cairo_set_source_rgb(cr, r, g, b)
        cairo_fill(cr)

        // The letter or emoji, centred (pango: real fonts, emoji and every script).
        let layout = pango_cairo_create_layout(cr)
        let font = pango_font_description_from_string("Sans Bold")
        pango_font_description_set_absolute_size(font, radius * 1.05 * Double(PANGO_SCALE))
        pango_layout_set_font_description(layout, font)
        pango_font_description_free(font)
        pango_layout_set_text(layout, account.badgeText, -1)
        var ink = PangoRectangle(), logical = PangoRectangle()
        pango_layout_get_pixel_extents(layout, &ink, &logical)
        cairo_move_to(cr, cx - Double(ink.width) / 2 - Double(ink.x), cy - Double(ink.height) / 2 - Double(ink.y))
        cairo_set_source_rgb(cr, 1, 1, 1)
        pango_cairo_show_layout(cr, layout)
        g_object_unref(GPtr(layout!))

        cairo_surface_flush(surface)
        cairo_surface_write_to_png(surface, path)
    }

    private static func roundedRect(_ cr: OpaquePointer, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) {
        cairo_new_sub_path(cr)
        cairo_arc(cr, x + w - r, y + r, r, -.pi / 2, 0)
        cairo_arc(cr, x + w - r, y + h - r, r, 0, .pi / 2)
        cairo_arc(cr, x + r, y + h - r, r, .pi / 2, .pi)
        cairo_arc(cr, x + r, y + r, r, .pi, 3 * .pi / 2)
        cairo_close_path(cr)
    }

    static func rgb(_ hex: String) -> (Double, Double, Double) {
        let body = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard body.count == 6, let value = UInt32(body, radix: 16) else { return (0.85, 0.47, 0.34) }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}
