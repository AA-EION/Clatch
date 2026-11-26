// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import Foundation

/// Facts about Claude Desktop for Linux that Clatch reads from files.
/// Plain Foundation, so they are unit-tested on every platform.
///
/// Claude for Linux (Anthropic's .deb, `/usr/lib/claude-desktop`) is an
/// Electron app. Each running Claude holds Chromium's single-instance lock in
/// its data folder: a symlink `SingletonLock` → "<hostname>-<pid>", removed
/// when it closes. A Claude started on another folder (`--user-data-dir`) is a
/// separate instance with its own lock. Every helper process carries the
/// folder in its arguments (`--user-data-dir=…`; the crash reporter
/// `--database=<folder>/Crashpad`), including the crash reporter, which is
/// not a child of Claude.
public enum LinuxClaude {
    // MARK: - The single-instance lock

    public struct LockOwner: Equatable, Sendable {
        public var host: String
        public var pid: Int32
        public init(host: String, pid: Int32) { self.host = host; self.pid = pid }
    }

    /// Who holds a data folder's `SingletonLock`, if anyone ("<host>-<pid>"; hosts may contain "-").
    public static func lockOwner(of dataFolder: URL, fileManager: FileManager = .default) -> LockOwner? {
        let lock = dataFolder.appendingPathComponent("SingletonLock").path
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: lock) else { return nil }
        return parseLock(target)
    }

    public static func parseLock(_ target: String) -> LockOwner? {
        guard let dash = target.lastIndex(of: "-"), let pid = Int32(target[target.index(after: dash)...]), pid > 0 else {
            return nil
        }
        return LockOwner(host: String(target[..<dash]), pid: pid)
    }

    // MARK: - Claude's log: did it agree to quit?

    /// What Claude's own log says about a quit that was asked for at `since`.
    public enum QuitProgress: Equatable, Sendable {
        /// Nothing logged yet.
        case none
        /// Claude is asking the user first (a session is running, an update is pending…).
        case asking
        /// Claude agreed and has finished saving ("marking readyForQuit"): what
        /// is left of it can be ended without losing anything.
        case readyToQuit
    }

    /// Reads the newest lines of the profile's logs (`<folder>/logs/*.log`).
    public static func quitProgress(dataFolder: URL, since: Date, fileManager: FileManager = .default) -> QuitProgress {
        let logs = dataFolder.appendingPathComponent("logs", isDirectory: true)
        guard let names = try? fileManager.contentsOfDirectory(atPath: logs.path) else { return .none }
        var result = QuitProgress.none
        for name in names where name.hasSuffix(".log") {
            let file = logs.appendingPathComponent(name)
            guard let modified = (try? fileManager.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
                  modified >= since.addingTimeInterval(-1),
                  let tail = readTail(of: file, bytes: 256 * 1024) else { continue }
            let progress = quitProgress(inLog: tail, since: since)
            if progress == .readyToQuit { return .readyToQuit }
            if progress == .asking { result = .asking }
        }
        return result
    }

    /// The same, on log text ("2026-11-26 10:16:23 [info] …" lines, local time).
    public static func quitProgress(inLog text: String, since: Date) -> QuitProgress {
        // The log has whole seconds: accept lines from the second the request was made.
        let floor = Date(timeIntervalSince1970: since.timeIntervalSince1970.rounded(.down))
        var result = QuitProgress.none
        for line in text.split(separator: "\n") {
            guard line.count > 19, let date = logDate(line.prefix(19)), date >= floor else { continue }
            if line.contains("marking readyForQuit") { return .readyToQuit }
            if line.contains("vetoed by before-quit interceptor") { result = .asking }
        }
        return result
    }

    private static func logDate(_ text: Substring) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: String(text))
    }

    private static func readTail(of file: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Installed version (dpkg)

    /// The installed `claude-desktop` version from dpkg's status database.
    public static func installedVersion(statusFile: URL = URL(fileURLWithPath: "/var/lib/dpkg/status")) -> String? {
        guard let data = FileManager.default.contents(atPath: statusFile.path) else { return nil }
        return packageVersion("claude-desktop", inDpkgStatus: String(decoding: data, as: UTF8.self))
    }

    public static func packageVersion(_ package: String, inDpkgStatus text: String) -> String? {
        for stanza in text.components(separatedBy: "\n\n") {
            var name: String?, version: String?, installed = false
            for line in stanza.split(separator: "\n") {
                if line.hasPrefix("Package: ") { name = String(line.dropFirst(9)) }
                if line.hasPrefix("Version: ") { version = String(line.dropFirst(9)) }
                if line.hasPrefix("Status: ") { installed = line.hasSuffix(" installed") }
            }
            if name == package && installed { return version }
        }
        return nil
    }

    // MARK: - Desktop entries

    /// Escapes a value for a .desktop file (spec: \s \n \t \r \\).
    public static func desktopValue(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    /// Quotes one argument of an Exec= line (spec: double quotes; ", `, $ and \ escaped; % doubled).
    public static func execArgument(_ argument: String) -> String {
        let reserved = CharacterSet(charactersIn: " \t\n\"'\\><~|&;$*?#()`")
        var escaped = argument.replacingOccurrences(of: "%", with: "%%")
        guard escaped.rangeOfCharacter(from: reserved) != nil || escaped.isEmpty else { return escaped }
        for c in ["\\", "\"", "`", "$"] { escaped = escaped.replacingOccurrences(of: c, with: "\\" + c) }
        // Inside a desktop file value, every backslash is escaped once more.
        return "\"" + escaped.replacingOccurrences(of: "\\", with: "\\\\") + "\""
    }

    /// A launcher (.desktop) for one profile.
    public static func profileLauncher(name: String, profile: UUID, executable: String, icon: String) -> String {
        """
        [Desktop Entry]
        Type=Application
        Version=1.0
        Name=\(desktopValue("Claude – \(name)"))
        Comment=\(desktopValue("Open Claude as \(name) (Clatch)"))
        Exec=\(execArgument(executable)) --launch \(profile.uuidString.lowercased())
        Icon=\(desktopValue(icon))
        Terminal=false
        Categories=Utility;
        StartupNotify=true
        X-Clatch-Profile=\(profile.uuidString.lowercased())

        """
    }
}
