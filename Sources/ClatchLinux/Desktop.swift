// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import CGtk
import ClatchCore
import Foundation
import Glibc

/// Clatch's place on the desktop: its desktop entry id, profile launchers,
/// start at login, and the claude:// link handler.
@MainActor
enum Desktop {
    static let appID = "com.issensoftware.Clatch"
    static var desktopEntry: String { "\(appID).desktop" }

    /// How to start Clatch from a desktop entry: "clatch" when the package's
    /// /usr/bin/clatch is this program, else the full path.
    static var clatchCommand: String {
        let me = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath().path
        let installed = URL(fileURLWithPath: "/usr/bin/clatch").resolvingSymlinksInPath().path
        return me == installed ? "/usr/bin/clatch" : me
    }

    static var dataHome: URL { ClatchPaths.xdg("XDG_DATA_HOME", ".local/share") }

    static var applicationsFolder: URL { dataHome.appendingPathComponent("applications", isDirectory: true) }

    /// The user's Desktop folder (xdg-user-dirs), or nil when there is none.
    static var desktopFolder: URL? {
        guard let dir = String(gstring: g_get_user_special_dir(G_USER_DIRECTORY_DESKTOP)) else { return nil }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        guard url.standardizedFileURL.path != ClatchPaths.home.standardizedFileURL.path,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

/// One launcher per profile, in the app grid / menu (~/.local/share/applications)
/// and on the Desktop when there is one. Each opens Claude as that profile
/// (`clatch --launch <id>`), with Claude's icon and the profile's badge. They
/// follow the profiles: created, renamed and removed with them, and all
/// removed when the setting is turned off.
@MainActor
enum ProfileShortcuts {
    static let prefix = "clatch-profile-"

    static func fileName(_ id: UUID) -> String { "\(prefix)\(id.uuidString.lowercased()).desktop" }

    static func sync(accounts: [Account], enabled: Bool) {
        let folders = [Desktop.applicationsFolder] + (Desktop.desktopFolder.map { [$0] } ?? [])
        var wanted: Set<String> = []
        if enabled {
            for account in accounts {
                let name = fileName(account.id)
                wanted.insert(name)
                let content = LinuxClaude.profileLauncher(name: account.name, profile: account.id,
                                                         executable: Desktop.clatchCommand,
                                                         icon: ProfileIcons.png(for: account))
                for folder in folders { write(content, to: folder.appendingPathComponent(name), onDesktop: folder != folders[0]) }
            }
        }
        for folder in folders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            where name.hasPrefix(prefix) && name.hasSuffix(".desktop") && !wanted.contains(name) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                Log.write("Removed a profile shortcut")
            }
        }
        if !enabled { accounts.forEach { ProfileIcons.prune($0) } }
    }

    private static func write(_ content: String, to file: URL, onDesktop: Bool) {
        if (try? String(contentsOf: file, encoding: .utf8)) == content { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
            // Launchers must be executable, and desktop icons (GNOME) also trusted, to open with one click.
            chmod(file.path, 0o755)
            if onDesktop {
                let gfile = g_file_new_for_path(file.path)
                var error: UnsafeMutablePointer<GError>?
                g_file_set_attribute_string(gfile, "metadata::trusted", "true", G_FILE_QUERY_INFO_NONE, nil, &error)
                g_clear_error(&error)
                g_object_unref(gfile.map { GPtr($0) })
            }
            Log.write("Wrote a profile shortcut")
        } catch {
            Log.write("Could not write a profile shortcut: \(error.localizedDescription)")
        }
    }
}

/// "Open Clatch when I log in": an XDG autostart entry.
@MainActor
enum StartAtLogin {
    static var file: URL {
        ClatchPaths.configHome.appendingPathComponent("autostart/\(Desktop.desktopEntry)")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: file.path) }

    static func setEnabled(_ on: Bool) throws {
        if on {
            let content = """
            [Desktop Entry]
            Type=Application
            Name=Clatch
            Comment=Switch Claude Desktop accounts
            Exec=\(LinuxClaude.execArgument(Desktop.clatchCommand)) --background
            Icon=\(Desktop.appID)
            Terminal=false
            X-GNOME-Autostart-enabled=true

            """
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
        } else if isEnabled {
            try FileManager.default.removeItem(at: file)
        }
    }
}
