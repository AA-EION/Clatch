// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import CGtk
import ClatchCore
import Foundation

/// The Alt-Tab-style profile switcher.
///
/// The global shortcut opens it with the next profile highlighted; pressing
/// it again moves on (Shift, ← or ↑ go back), and letting go of the keys opens
/// the highlighted profile. Esc cancels, Enter opens at once, a click works too.
///
/// Wayland lets no app place its own windows, so the switcher is a
/// transparent full-screen window with the card in the middle. When it has
/// the keyboard, releasing the modifier keys commits. When it does not (the
/// desktop gave no activation token), the portal's "released" event or, on
/// GNOME's custom shortcuts, a short pause after the last press commits.
/// The window exists only while it is shown.
@MainActor
final class Switcher {
    struct Tile {
        var account: Account
        var icon: String
        var isCurrent: Bool
        var isRunning: Bool
    }

    var onChoose: ((UUID) -> Void)?
    private var window: GPtr?
    private var tiles: [Tile] = []
    private var tileWidgets: [GPtr] = []
    private var selection = 0
    private var commitTimer: GTimer?
    private var focused = false
    private var shortcutKey: UInt32 = 0
    private var reportsRelease = false

    var isOpen: Bool { window != nil }

    /// Opens the switcher, or moves the highlight when it is open already.
    /// `reportsRelease`: the desktop will say when the shortcut is let go (the portal).
    func present(tiles: [Tile], current: UUID?, sideBySide: Bool, accelerator: String?, token: String?,
                 reportsRelease: Bool, app: GPtr) {
        if isOpen { return step(1) }
        guard tiles.count > 1 else { return }
        self.tiles = tiles
        self.reportsRelease = reportsRelease
        let start = tiles.firstIndex { $0.account.id == current } ?? -1
        selection = (start + 1) % tiles.count
        shortcutKey = accelerator.map(Self.keyval(of:)) ?? 0

        let window = g(gtk_window_new())
        self.window = window
        gtk_window_set_application(window.t(), app.t())
        gtk_window_set_title(window.t(), "Clatch profile switcher")
        gtk_window_set_decorated(window.t(), 0)
        gtk_window_set_resizable(window.t(), 0)
        UI.css(window, "clatch-switcher")
        gtk_window_set_child(window.t(), build(sideBySide: sideBySide).t())

        let keys = g(gtk_event_controller_key_new())
        onKey(keys, released: false) { [weak self] keyval, state in self?.keyPressed(keyval, state) ?? false }
        onKey(keys, released: true) { [weak self] keyval, _ in self?.keyReleased(keyval) ?? false }
        gtk_widget_add_controller(window.t(), keys.t())
        onSignal1(window, "notify::is-active") { [weak self] _ in
            guard let self, let window = self.window else { return }
            let active = gtk_window_is_active(window.t()) != 0
            if active { self.focused = true; self.commitTimer = nil }
            // Lost the keyboard to another window after having it: treat as "let go".
            else if self.focused { self.commit() }
        }
        onSignalBool(window, "close-request") { [weak self] in self?.dismiss(); return true }

        if let token { gtk_window_set_startup_id(window.t(), token) }
        gtk_window_fullscreen(window.t())
        gtk_window_present(window.t())
        select(selection)
        armCommitTimer()
    }

    /// Another press of the shortcut.
    func step(_ delta: Int) {
        guard isOpen, !tiles.isEmpty else { return }
        select(selection + delta)
        armCommitTimer()
    }

    /// The desktop says the shortcut was let go.
    func shortcutReleased() {
        guard isOpen, !focused else { return } // with the keyboard, the modifier release itself commits
        commitTimer = GTimer(0.35, repeats: false) { [weak self] in self?.commit() }
    }

    /// Without the keyboard and without release events, a pause after the last press commits.
    private func armCommitTimer() {
        guard !focused else { return }
        commitTimer = GTimer(reportsRelease ? 4 : 1.1, repeats: false) { [weak self] in self?.commit() }
    }

    func commit() {
        guard isOpen, tiles.indices.contains(selection) else { return dismiss() }
        let id = tiles[selection].account.id
        dismiss()
        onChoose?(id)
    }

    func dismiss() {
        commitTimer = nil
        focused = false
        if let window {
            self.window = nil
            gtk_window_destroy(window.t())
        }
        tileWidgets = []
    }

    // MARK: - Content

    private func build(sideBySide: Bool) -> GPtr {
        let row = UI.hbox(6)
        tileWidgets = []
        for (index, tile) in tiles.enumerated() {
            let icon = UI.image(file: tile.icon, size: 72)
            let overlay = g(gtk_overlay_new())
            gtk_overlay_set_child(overlay.t(), icon.t())
            if tile.isRunning && sideBySide {
                let dot = UI.align(UI.css(g(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)), "clatch-dot"), h: GTK_ALIGN_END, v: GTK_ALIGN_START)
                gtk_overlay_add_overlay(overlay.t(), dot.t())
            }
            let name = UI.ellipsized((tile.isCurrent && !sideBySide ? "✓ " : "") + tile.account.name)
            gtk_label_set_xalign(name.t(), 0.5)
            gtk_label_set_max_width_chars(name.t(), 14)
            let content = UI.vbox(8, [UI.align(overlay, h: GTK_ALIGN_CENTER), name])
            gtk_widget_set_size_request(content.t(), 112, -1)
            let button = UI.button(content: content, ["flat", "clatch-tile"]) { [weak self] in
                self?.select(index)
                self?.commit()
            }
            tileWidgets.append(button)
            UI.append(row, button)
        }
        let hint = UI.label(sideBySide ? "Release to open · Esc to cancel" : "Release to switch · Esc to cancel",
                            ["caption", "dim-label"], wrap: false, xalign: 0.5)
        let surface = UI.css(UI.vbox(10, [row, hint]), "clatch-switcher-surface")
        return UI.align(surface, h: GTK_ALIGN_CENTER, v: GTK_ALIGN_CENTER)
    }

    private func select(_ index: Int) {
        guard !tiles.isEmpty else { return }
        selection = (index % tiles.count + tiles.count) % tiles.count
        for (i, widget) in tileWidgets.enumerated() {
            if i == selection { gtk_widget_add_css_class(widget.t(), "selected") } else { gtk_widget_remove_css_class(widget.t(), "selected") }
        }
    }

    // MARK: - Keys

    private static let modifierKeys: Set<UInt32> = [
        0xffe3, 0xffe4, // Control_L/R
        0xffe9, 0xffea, // Alt_L/R
        0xffe7, 0xffe8, // Meta_L/R
        0xffeb, 0xffec, // Super_L/R
        0xffe1, 0xffe2, // Shift_L/R
        0xfe03,         // ISO_Level3_Shift (AltGr)
    ]

    private func keyPressed(_ keyval: UInt32, _ state: UInt32) -> Bool {
        focused = true
        commitTimer = nil
        let shift = state & GDK_SHIFT_MASK.rawValue != 0
        switch keyval {
        case 0xff1b: dismiss()                                  // Escape
        case 0xff0d, 0xff8d, 0x020: commit()                    // Return, KP_Enter, space
        case 0xff51, 0xff52: step(-1)                           // Left, Up
        case 0xff53, 0xff54: step(1)                            // Right, Down
        case 0xff09: step(shift ? -1 : 1)                       // Tab
        case 0xfe20: step(-1)                                   // ISO_Left_Tab (Shift+Tab)
        default:
            if keyval == shortcutKey || gdk_keyval_to_lower(keyval) == shortcutKey { step(shift ? -1 : 1) }
            else { return false }
        }
        return true
    }

    private func keyReleased(_ keyval: UInt32) -> Bool {
        guard Self.modifierKeys.contains(keyval), keyval != 0xffe1, keyval != 0xffe2 else { return false }
        commit()
        return true
    }

    /// The key of a GTK accelerator ("<Control><Alt><Super>c" → c).
    static func keyval(of accelerator: String) -> UInt32 {
        var key: guint = 0
        var mods = GdkModifierType(rawValue: 0)
        gtk_accelerator_parse(accelerator, &key, &mods)
        return gdk_keyval_to_lower(key)
    }
}
