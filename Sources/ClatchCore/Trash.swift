// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// Moves a folder to the user's Trash, following the freedesktop.org Trash
/// specification (the one GNOME Files, KDE Dolphin and `gio trash` use):
/// the item goes to `$XDG_DATA_HOME/Trash/files/<name>` with a matching
/// `info/<name>.trashinfo` that records where it came from and when, so the
/// file manager can restore it. Used on Linux; macOS uses `trashItem`.
public enum Trash {
    public static var home: URL {
        ClatchPaths.xdg("XDG_DATA_HOME", ".local/share").appendingPathComponent("Trash", isDirectory: true)
    }

    /// Returns where the item now is.
    @discardableResult
    public static func move(_ item: URL, trash: URL = Trash.home, fileManager: FileManager = .default,
                            now: Date = Date()) throws -> URL {
        let files = trash.appendingPathComponent("files", isDirectory: true)
        let info = trash.appendingPathComponent("info", isDirectory: true)
        try fileManager.createDirectory(at: files, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(at: info, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let base = item.lastPathComponent
        var name = base
        var counter = 1
        // Claim the name with the .trashinfo first (O_EXCL), as the spec asks.
        while true {
            let infoFile = info.appendingPathComponent(name + ".trashinfo")
            let destination = files.appendingPathComponent(name, isDirectory: true)
            let fd = open(infoFile.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd >= 0 {
                close(fd)
                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: infoFile) // a stray file without info: skip that name
                } else {
                    let text = "[Trash Info]\nPath=\(encode(item.standardizedFileURL.path))\nDeletionDate=\(date(now))\n"
                    do {
                        try Data(text.utf8).write(to: infoFile)
                        try fileManager.moveItem(at: item, to: destination)
                    } catch {
                        try? fileManager.removeItem(at: infoFile)
                        throw error
                    }
                    return destination
                }
            } else if errno != EEXIST {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: infoFile.path])
            }
            counter += 1
            name = "\(base).\(counter)"
        }
    }

    /// Percent-encodes the path as the spec requires (RFC 2396 style, "/" kept).
    static func encode(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "/-._~!$&'()*+,;=:@")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }
}
