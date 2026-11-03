// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import Foundation

/// A global keyboard shortcut, stored as a Carbon virtual key code plus Carbon
/// modifier flags (the form `RegisterEventHotKey` takes).
public struct KeyCombo: Codable, Hashable, Sendable {
    // Carbon modifier bits (Events.h). Spelled out so this file needs no Carbon import.
    public static let commandKey: UInt32 = 1 << 8
    public static let shiftKey: UInt32 = 1 << 9
    public static let optionKey: UInt32 = 1 << 11
    public static let controlKey: UInt32 = 1 << 12

    public var keyCode: UInt32
    public var modifiers: UInt32
    /// What the key prints, captured when the shortcut was recorded, so the
    /// label matches the user's keyboard layout ("C", "F5", "Space").
    public var keyLabel: String

    public init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// The default: Control-Option-Command-C ("C" for Claude / Clatch).
    ///
    /// Control-Option-Command is the modifier set macOS and mainstream apps
    /// leave free; the few system shortcuts that use all three (⌃⌥⌘8 for
    /// invert colors, ⌃⌥⌘, and ⌃⌥⌘. for contrast, ⌃⌥⌘⏏ to shut down) do not
    /// involve C, and Claude Desktop's own shortcut is ⌥Space. If another app
    /// already holds it, Clatch says so and lets the user pick another.
    public static let `default` = KeyCombo(keyCode: 8 /* kVK_ANSI_C */,
                                           modifiers: controlKey | optionKey | commandKey,
                                           keyLabel: "C")

    /// "⌃⌥⌘C", in the order macOS menus use.
    public var displayString: String {
        var result = ""
        if modifiers & Self.controlKey != 0 { result += "⌃" }
        if modifiers & Self.optionKey != 0 { result += "⌥" }
        if modifiers & Self.shiftKey != 0 { result += "⇧" }
        if modifiers & Self.commandKey != 0 { result += "⌘" }
        return result + keyLabel
    }

    /// A global shortcut needs Command, Control or Option, otherwise it would
    /// steal ordinary typing. Function keys (F1–F20) are fine on their own.
    public var isAcceptable: Bool {
        let strong = modifiers & (Self.commandKey | Self.controlKey | Self.optionKey) != 0
        return strong || Self.functionKeyCodes.contains(keyCode)
    }

    /// kVK_F1 … kVK_F20.
    public static let functionKeyCodes: Set<UInt32> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    /// Labels for keys whose character is invisible or layout-independent.
    public static func specialLabel(for keyCode: UInt32) -> String? {
        let table: [UInt32: String] = [
            49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
            106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        ]
        return table[keyCode]
    }
}
