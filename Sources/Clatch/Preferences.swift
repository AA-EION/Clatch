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
