// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import ClatchCore
import Foundation

/// The user's settings, in `~/.config/Clatch/settings.json`.
struct Settings: Codable, Equatable {
    /// GTK accelerator for the profile switcher; nil when turned off.
    var hotKey: String? = Settings.defaultHotKey
    var sideBySide = false
    var reopenClaude = true
    var shareToolSettings = true
    var profileShortcuts = false
    var routeSignIns = false
    var watchdog = true
    var checkForUpdates = true
    var lastUpdateCheck: Date?
    /// The desktop entry that handled claude:// links before routing took over.
    var claudeLinkHandlerBackup: String?

    /// Ctrl+Alt+Super+C: the Windows default (Ctrl+Alt+Win+C), for the same
    /// reasons: Ctrl+Alt alone is AltGr on many layouts, and most Super+letter
    /// combinations belong to the desktop.
    static let defaultHotKey = "<Control><Alt><Super>c"

    static var file: URL { ClatchPaths.standard.clatchRoot.appendingPathComponent("settings.json") }

    static func load() -> Settings {
        guard let data = FileManager.default.contents(atPath: file.path) else { return Settings() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Settings.self, from: data)) ?? Settings()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: Settings.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Settings.file, options: .atomic)
    }

    enum CodingKeys: String, CodingKey {
        case hotKey, sideBySide, reopenClaude, shareToolSettings, profileShortcuts, routeSignIns, watchdog,
             checkForUpdates, lastUpdateCheck, claudeLinkHandlerBackup
    }

    // Missing keys (older files) keep their defaults.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        hotKey = c.contains(.hotKey) ? try c.decodeIfPresent(String.self, forKey: .hotKey) : d.hotKey
        sideBySide = try c.decodeIfPresent(Bool.self, forKey: .sideBySide) ?? d.sideBySide
        reopenClaude = try c.decodeIfPresent(Bool.self, forKey: .reopenClaude) ?? d.reopenClaude
        shareToolSettings = try c.decodeIfPresent(Bool.self, forKey: .shareToolSettings) ?? d.shareToolSettings
        profileShortcuts = try c.decodeIfPresent(Bool.self, forKey: .profileShortcuts) ?? d.profileShortcuts
        routeSignIns = try c.decodeIfPresent(Bool.self, forKey: .routeSignIns) ?? d.routeSignIns
        watchdog = try c.decodeIfPresent(Bool.self, forKey: .watchdog) ?? d.watchdog
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? d.checkForUpdates
        lastUpdateCheck = try c.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
        claudeLinkHandlerBackup = try c.decodeIfPresent(String.self, forKey: .claudeLinkHandlerBackup)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Written even when nil: "off" must not read back as "default".
        try c.encode(hotKey, forKey: .hotKey)
        try c.encode(sideBySide, forKey: .sideBySide)
        try c.encode(reopenClaude, forKey: .reopenClaude)
        try c.encode(shareToolSettings, forKey: .shareToolSettings)
        try c.encode(profileShortcuts, forKey: .profileShortcuts)
        try c.encode(routeSignIns, forKey: .routeSignIns)
        try c.encode(watchdog, forKey: .watchdog)
        try c.encode(checkForUpdates, forKey: .checkForUpdates)
        try c.encodeIfPresent(lastUpdateCheck, forKey: .lastUpdateCheck)
        try c.encodeIfPresent(claudeLinkHandlerBackup, forKey: .claudeLinkHandlerBackup)
    }
}
