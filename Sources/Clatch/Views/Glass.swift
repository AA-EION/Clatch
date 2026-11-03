// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import AppKit
import SwiftUI

// MARK: - Liquid Glass, with a fallback
//
// macOS 26 and later: real Liquid Glass (`glassEffect`, `GlassEffectContainer`,
// the `.glass` button styles). The panel itself is an NSPopover, which the
// system already renders as glass there.
//
// macOS 11 – 15: the popover is a vibrant material; cards and rows get a soft
// translucent fill and a hairline stroke, which reads the same way.
//
// Every new API is gated twice: `#if compiler(>=6.2)` so older toolchains can
// still build, and `#available(macOS 26, *)` so the app runs back to Big Sur.

enum Design {
    static let panelWidth: CGFloat = 312
    static let rowRadius: CGFloat = 12
    static let cardRadius: CGFloat = 16
    static let padding: CGFloat = 12

    /// A stable color per account, picked from the system palette.
    static func color(for id: UUID) -> Color {
        let palette: [NSColor] = [.systemOrange, .systemBlue, .systemPurple, .systemGreen,
                                  .systemPink, .systemTeal, .systemIndigo, .systemBrown]
        let hash = id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(palette[hash % palette.count])
    }

    static var hasLiquidGlass: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }
}

extension View {
    /// A card or row surface: Liquid Glass on macOS 26+, translucent fill before.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = Design.cardRadius, tint: Color? = nil,
                      interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(Self.makeGlass(tint: tint, interactive: interactive),
                             in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.fallbackSurface(cornerRadius: cornerRadius, tint: tint)
        }
        #else
        self.fallbackSurface(cornerRadius: cornerRadius, tint: tint)
        #endif
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    fileprivate static func makeGlass(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint.opacity(0.35)) }
        if interactive { glass = glass.interactive() }
        return glass
    }
    #endif

    fileprivate func fallbackSurface(cornerRadius: CGFloat, tint: Color?) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(shape.fill(tint.map { $0.opacity(0.16) } ?? Color(NSColor.labelColor).opacity(0.05)))
            .overlay(shape.stroke(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 0.5))
    }

    /// Groups glass shapes so they blend and morph together (macOS 26+).
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 8) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// The main call to action.
    @ViewBuilder
    func primaryButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent).controlSize(.large)
        } else if #available(macOS 12.0, *) {
            self.buttonStyle(.borderedProminent).controlSize(.large)
        } else {
            self.buttonStyle(DefaultButtonStyle()).controlSize(.large)
        }
        #else
        if #available(macOS 12.0, *) {
            self.buttonStyle(.borderedProminent).controlSize(.large)
        } else {
            self.buttonStyle(DefaultButtonStyle()).controlSize(.large)
        }
        #endif
    }

    /// Secondary actions next to a primary one.
    @ViewBuilder
    func secondaryButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass).controlSize(.large)
        } else {
            self.buttonStyle(DefaultButtonStyle()).controlSize(.large)
        }
        #else
        self.buttonStyle(DefaultButtonStyle()).controlSize(.large)
        #endif
    }

    /// Hides the dropdown arrow of a `Menu` where the OS allows it (macOS 12+).
    @ViewBuilder
    func hiddenMenuIndicator() -> some View {
        if #available(macOS 12.0, *) {
            self.menuIndicator(.hidden)
        } else {
            self
        }
    }
}

/// A full-width row that highlights on hover, like a menu item.
struct HoverRow<Content: View>: View {
    var action: () -> Void
    var isEnabled = true
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: Design.rowRadius - 3, style: .continuous)
                        .fill(Color(NSColor.labelColor).opacity(hovering && isEnabled ? 0.08 : 0)))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
    }
}

/// An item in the panel's action list.
struct ActionRow: View {
    var title: String
    var systemImage: String
    var shortcutHint: String? = nil
    var tint: Color? = nil
    var isEnabled = true
    var action: () -> Void

    var body: some View {
        HoverRow(action: action, isEnabled: isEnabled) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(tint ?? Color(NSColor.secondaryLabelColor))
                    .frame(width: 18)
                Text(title)
                    .foregroundColor(isEnabled ? Color(NSColor.labelColor) : Color(NSColor.tertiaryLabelColor))
                Spacer(minLength: 4)
                if let shortcutHint {
                    Text(shortcutHint)
                        .font(.system(size: 12))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
            }
        }
    }
}

/// The round avatar with an account's initials.
struct Avatar: View {
    var initials: String
    var color: Color
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.9))
            Text(initials)
                .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}

/// A heading with an optional back button, for the sub-pages.
struct PageHeader: View {
    var title: String
    var back: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if let back {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .help("Back")
            }
            Text(title).font(.headline)
            Spacer()
        }
    }
}
