// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import Foundation

/// A chat from Claude Desktop's Code tab.
///
/// Claude Desktop keeps one small file per Code-tab chat inside the profile:
/// `claude-code-sessions/<account id>/<organisation id>/local_<id>.json`. The
/// conversation itself lives in Claude Code's own history (shared by every
/// profile on this computer), so copying that file into another profile, under
/// the account and organisation that profile is signed in to, makes the chat
/// show up there and lets it carry on.
///
/// Regular claude.ai chats are stored on Anthropic's servers per account and
/// cannot be moved by any app.
public struct CodeSession: Identifiable, Hashable, Sendable {
    public var id: String { file.lastPathComponent }
    public let file: URL
    public let accountID: String
    public let organisationID: String
    public let title: String
    public let folder: String
    public let updated: Date
}

public enum CodeSessionError: LocalizedError, Equatable {
    case targetNeverOpenedCodeTab(String)
    case alreadyThere

    public var errorDescription: String? {
        switch self {
        case .targetNeverOpenedCodeTab(let name):
            return "Open the Code tab once in “\(name)” first, so Claude creates its chat folder there."
        case .alreadyThere:
            return "That chat is already in this profile."
        }
    }
}

public enum CodeSessions {
    public static let folderName = "claude-code-sessions"

    /// Every Code-tab chat in a profile's data folder, newest first. The same
    /// chat under two accounts (after an earlier copy) is listed once.
    public static func discover(inProfile dataFolder: URL, fileManager: FileManager = .default) -> [CodeSession] {
        let root = dataFolder.appendingPathComponent(folderName, isDirectory: true)
        var found: [String: CodeSession] = [:]
        for account in directories(in: root, fileManager) {
            for organisation in directories(in: account, fileManager) {
                let files = (try? fileManager.contentsOfDirectory(at: organisation, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for file in files where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    let session = read(file, account: account.lastPathComponent, organisation: organisation.lastPathComponent)
                    if let existing = found[session.id], existing.updated >= session.updated { continue }
                    found[session.id] = session
                }
            }
        }
        return found.values.sorted { $0.updated > $1.updated }
    }

    /// Copies a chat into another profile, under the account and organisation
    /// that profile used most recently. Returns the new file.
    @discardableResult
    public static func copy(_ session: CodeSession, toProfile dataFolder: URL, profileName: String,
                            fileManager: FileManager = .default) throws -> URL {
        let root = dataFolder.appendingPathComponent(folderName, isDirectory: true)
        let organisations = directories(in: root, fileManager).flatMap { directories(in: $0, fileManager) }
        guard let target = organisations.max(by: { modified($0, fileManager) < modified($1, fileManager) }) else {
            throw CodeSessionError.targetNeverOpenedCodeTab(profileName)
        }
        let destination = target.appendingPathComponent(session.file.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            if (try? Data(contentsOf: destination)) == (try? Data(contentsOf: session.file)) {
                throw CodeSessionError.alreadyThere
            }
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: session.file, to: destination)
        return destination
    }

    // MARK: - Helpers

    static func read(_ file: URL, account: String, organisation: String) -> CodeSession {
        let updated = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        var title = ""
        var folder = ""
        if let data = try? Data(contentsOf: file),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            title = firstString(object, ["title", "name", "summary", "customTitle", "displayName"]) ?? ""
            let path = firstString(object, ["cwd", "workingDirectory", "projectPath", "folder", "path"]) ?? ""
            if path.contains("scratch-workspaces") {
                folder = "(no folder)"
            } else if !path.isEmpty {
                folder = URL(fileURLWithPath: path.replacingOccurrences(of: "\\", with: "/")).lastPathComponent
            }
        }
        if title.isEmpty {
            let base = file.deletingPathExtension().lastPathComponent.dropFirst("local_".count)
            title = "Chat \(base.prefix(8))"
        }
        return CodeSession(file: file, accountID: account, organisationID: organisation,
                           title: title, folder: folder, updated: updated)
    }

    private static func firstString(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func directories(in folder: URL, _ fileManager: FileManager) -> [URL] {
        let items = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    private static func modified(_ url: URL, _ fileManager: FileManager) -> Date {
        // The organisation folder's newest file says when this account last used the Code tab.
        let files = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dates = files.compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        return dates.max() ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
}
