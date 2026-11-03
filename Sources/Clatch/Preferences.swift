// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import ClatchCore
import Foundation

/// The user's settings, in the app's standard `UserDefaults` domain.
@MainActor
struct Preferences {
    private let defaults = UserDefaults.standard

    private enum Key {
        static let hotKey = "hotKey"
        static let hotKeyDisabled = "hotKeyDisabled"
        static let reopenClaude = "reopenClaudeAfterSwitch"
        static let shareToolSettings = "shareToolSettings"
        static let sideBySide = "sideBySide"
        static let profileShortcuts = "profileShortcuts"
        static let routeSignIns = "routeSignIns"
        static let watchdog = "watchdog"
        static let checkForUpdates = "checkForUpdates"
    }

    private func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }

    /// Profiles run side by side (each its own Claude) instead of one at a time.
    /// Off by default: one at a time keeps a single account active at a time.
    var sideBySide: Bool {
        get { bool(Key.sideBySide, default: false) }
        nonmutating set { defaults.set(newValue, forKey: Key.sideBySide) }
    }

    /// A launcher per profile in ~/Applications/Clatch Profiles.
    var profileShortcuts: Bool {
        get { bool(Key.profileShortcuts, default: false) }
        nonmutating set { defaults.set(newValue, forKey: Key.profileShortcuts) }
    }

    /// Side by side: send claude:// sign-ins to the profile that asked.
    var routeSignIns: Bool {
        get { bool(Key.routeSignIns, default: false) }
        nonmutating set { defaults.set(newValue, forKey: Key.routeSignIns) }
    }

    /// Side by side: reopen profiles that Claude's own update closed.
    var watchdog: Bool {
        get { bool(Key.watchdog, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.watchdog) }
    }

    var checkForUpdates: Bool {
        get { bool(Key.checkForUpdates, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.checkForUpdates) }
    }

    /// nil when the user turned the shortcut off.
    var hotKey: KeyCombo? {
        get {
            if defaults.bool(forKey: Key.hotKeyDisabled) { return nil }
            guard let data = defaults.data(forKey: Key.hotKey),
                  let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) else { return .default }
            return combo
        }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.hotKey)
                defaults.set(false, forKey: Key.hotKeyDisabled)
            } else {
                defaults.set(true, forKey: Key.hotKeyDisabled)
            }
        }
    }

    /// Open Claude again after switching (when it was open before).
    var reopenClaude: Bool {
        get { defaults.object(forKey: Key.reopenClaude) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.reopenClaude) }
    }

    /// Carry MCP servers and other tool settings to every account.
    var shareToolSettings: Bool {
        get { defaults.object(forKey: Key.shareToolSettings) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.shareToolSettings) }
    }
}
