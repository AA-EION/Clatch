// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import AppKit
import ClatchCore
import CoreServices

/// One small launcher app per profile in ~/Applications/Clatch Profiles
/// ("Claude – Work.app"), with the profile's badged icon. Opening it opens
/// clatch://launch/<id>, and Clatch does what the current mode means:
/// one at a time it switches Claude to that profile; side by side it brings
/// that profile's Claude to the front or starts it. Keep one in the Dock to
/// get a per-profile Dock icon (macOS cannot give each running Claude its own).
///
/// The launchers are created, renamed and removed as profiles change, and
/// only while the setting is on. Each one carries ClatchProfileID in its
/// Info.plist, and Clatch never touches an app without it.
@MainActor
enum ProfileShortcuts {
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Clatch Profiles", isDirectory: true)
    }

    private static let idKey = "ClatchProfileID"
    private static let lookKey = "ClatchIconLook"

    /// Brings the launchers in line with the profiles (or removes them all).
    static func sync(accounts: [Account], enabled: Bool) {
        let fm = FileManager.default
        let existing = launchers()
        guard enabled else {
            for launcher in existing.values { try? fm.removeItem(at: launcher) }
            try? fm.removeItem(at: folder.appendingPathComponent(".localized"))
            if (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? fm.removeItem(at: folder) }
            return
        }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let wanted = Set(accounts.map(\.id))
        for (id, url) in existing where !wanted.contains(id) {
            try? fm.removeItem(at: url)
            Log.write("Removed a profile launcher")
        }
        for account in accounts {
            let target = folder.appendingPathComponent("Claude – \(safeName(account.name)).app", isDirectory: true)
            let look = "\(account.badgeText)|\(account.resolvedColorHex)|\(ClaudeApp.url?.path ?? "")|\(account.name)"
            if let current = existing[account.id] {
                if current.standardizedFileURL == target.standardizedFileURL, info(at: current)?[lookKey] as? String == look { continue }
                try? fm.removeItem(at: current) // renamed or restyled: rebuild
            }
            do {
                try build(account, at: target, look: look)
            } catch {
                Log.write("Could not create the launcher for “\(account.name)”: \(error.localizedDescription)")
            }
        }
    }

    /// Clatch's launchers in the folder, by profile id.
    private static func launchers() -> [UUID: URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var result: [UUID: URL] = [:]
        for url in items where url.pathExtension == "app" {
            if let raw = info(at: url)?[idKey] as? String, let id = UUID(uuidString: raw) { result[id] = url }
        }
        return result
    }

    private static func info(at app: URL) -> [String: Any]? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }

    /// File names cannot contain "/" or ":"; keep the rest readable.
    static func safeName(_ name: String) -> String {
        let cleaned = name.map { "/:\\".contains($0) ? "-" : $0 }.map(String.init).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Profile" : String(cleaned.prefix(60))
    }

    private static func build(_ account: Account, at app: URL, look: String) throws {
        let fm = FileManager.default
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.issen.clatch.profile.\(account.id.uuidString.lowercased())",
            "CFBundleName": "Claude – \(account.name)",
            "CFBundleDisplayName": "Claude – \(account.name)",
            "CFBundleExecutable": "launch",
            "CFBundleIconFile": "Profile",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "11.0",
            // Opens Clatch's link and quits at once: no Dock icon of its own while it runs.
            "LSUIElement": true,
            idKey: account.id.uuidString,
            lookKey: look,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let script = """
        #!/bin/sh
        # Created by Clatch for the profile "\(account.name.replacingOccurrences(of: "\"", with: ""))".
        # Opening this app tells Clatch to open that profile.
        exec /usr/bin/open -g "clatch://launch/\(account.id.uuidString)"
        """
        let executable = contents.appendingPathComponent("MacOS/launch")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try ProfileIcons.writeICNS(for: account, to: contents.appendingPathComponent("Resources/Profile.icns"))

        // An ad-hoc signature keeps Gatekeeper and Launch Services content; the
        // bundle was made on this Mac, so it carries no quarantine flag.
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", app.path]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try? codesign.run()
        codesign.waitUntilExit()
        // Tell Finder, Spotlight and Launchpad about it (and its new icon).
        LSRegisterURL(app as CFURL, true)
        Log.write("Created the launcher for a profile")
    }
}
