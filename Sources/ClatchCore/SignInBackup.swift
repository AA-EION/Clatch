// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import Foundation

/// Copies of each profile's sign-in, taken when the way profiles run changes
/// (side by side ⇄ one at a time) so no profile ever has to sign in again.
///
/// Only what makes up the sign-in is copied (a few hundred kB per profile):
/// cookies, the encryption key's container ("Local State"), the encrypted
/// token cache (config.json), preferences and local storage. Caches, Code-tab
/// data and Cowork's VM images are not, and are never touched.
public enum SignInBackup {
    public static let items = ["Local State", "Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal",
                               "config.json", "Preferences", "Local Storage"]
    public static let kept = 3

    public struct Snapshot: Identifiable, Hashable, Sendable {
        public var id: String { folder.lastPathComponent }
        public let folder: URL
        public let date: Date
        /// Profile ids with a copy in this backup.
        public let profiles: [UUID]
    }

    /// Backs up the given profiles (id → data folder). Folders that do not
    /// exist yet (a profile that never started) are skipped. Keeps the newest
    /// `kept` backups. Returns the new backup, or nil if nothing was copied.
    @discardableResult
    public static func backUp(_ profiles: [UUID: URL], into root: URL, reason: String,
                              fileManager: FileManager = .default) throws -> Snapshot? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let now = Date()
        let folder = root.appendingPathComponent(formatter.string(from: now).replacingOccurrences(of: ":", with: "-"), isDirectory: true)
        var copied: [UUID] = []
        for (id, data) in profiles {
            var any = false
            for item in items {
                let source = data.appendingPathComponent(item)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let destination = folder.appendingPathComponent(id.uuidString).appendingPathComponent(item)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
                try fileManager.copyItem(at: source, to: destination)
                any = true
            }
            if any { copied.append(id) }
        }
        guard !copied.isEmpty else { return nil }
        try reason.write(to: folder.appendingPathComponent("reason.txt"), atomically: true, encoding: .utf8)
        prune(root, fileManager: fileManager)
        return Snapshot(folder: folder, date: now, profiles: copied)
    }

    /// The backups in a folder, newest first.
    public static func list(in root: URL, fileManager: FileManager = .default) -> [Snapshot] {
        let folders = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return folders.compactMap { folder in
            let ids = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap(UUID.init(uuidString:))
            guard !ids.isEmpty else { return nil }
            let date = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return Snapshot(folder: folder, date: date, profiles: ids)
        }
        .sorted { $0.date > $1.date }
    }

    /// Puts a profile's sign-in back from a backup. Claude must not be running
    /// in that folder. Other files in the folder are left as they are.
    public static func restore(_ id: UUID, from snapshot: Snapshot, into data: URL,
                               fileManager: FileManager = .default) throws {
        let source = snapshot.folder.appendingPathComponent(id.uuidString)
        try fileManager.createDirectory(at: data, withIntermediateDirectories: true)
        for item in items {
            let from = source.appendingPathComponent(item)
            guard fileManager.fileExists(atPath: from.path) else { continue }
            let to = data.appendingPathComponent(item)
            try fileManager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: to.path) { try fileManager.removeItem(at: to) }
            try fileManager.copyItem(at: from, to: to)
        }
    }

    static func prune(_ root: URL, fileManager: FileManager) {
        for old in list(in: root, fileManager: fileManager).dropFirst(kept) {
            try? fileManager.removeItem(at: old.folder)
        }
    }
}
