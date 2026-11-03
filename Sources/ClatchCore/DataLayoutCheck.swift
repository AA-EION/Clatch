// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import Foundation

/// Fail-safe against Claude Desktop changing where or how it stores its data.
///
/// Clatch relies on facts nobody guarantees: that Claude keeps its sign-in in
/// one Electron user-data folder at a known path. Before every switch Clatch
/// checks that the folder still looks like that. When it doesn't, the switch
/// stops and the user decides whether to continue anyway.
public struct DataLayoutCheck: Equatable, Sendable {
    public var problems: [String]
    public var isRecognized: Bool { problems.isEmpty }

    /// Files Chromium/Electron always creates in a user-data folder (newer
    /// Chromium keeps cookies under `Network/`).
    static let electronMarkers = ["Local State", "Cookies", "Network/Cookies", "Preferences"]
    /// Files Claude itself writes there.
    static let claudeMarkers = ["config.json", "claude_desktop_config.json"]

    /// - Parameters:
    ///   - claudeData: Claude's live data folder.
    ///   - claudeHasRunSinceLastSwitch: Claude was open on this account (it was
    ///     running when the switch started, or the account is not brand new).
    ///     If so, the folder must exist: Claude creates it on first launch.
    ///   - alternatives: other folders where a future Claude might keep its
    ///     data; any that exist are mentioned to help the user.
    public static func inspect(claudeData: URL,
                               claudeHasRunSinceLastSwitch: Bool,
                               alternatives: [URL] = [],
                               fileManager: FileManager = .default) -> DataLayoutCheck {
        var problems: [String] = []
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: claudeData.path, isDirectory: &isDirectory)

        if exists && !isDirectory.boolValue {
            problems.append("\(claudeData.path) is no longer a folder.")
        } else if exists {
            // A folder that only holds files Clatch put there (shared settings)
            // belongs to an account that has not signed in yet.
            let contents = (try? fileManager.contentsOfDirectory(atPath: claudeData.path)) ?? []
            let onlyShared = contents.allSatisfy { AccountStore.defaultSharedItems.contains($0) || $0.hasPrefix(".") }
            if !onlyShared {
                let has = { (name: String) in fileManager.fileExists(atPath: claudeData.appendingPathComponent(name).path) }
                if !electronMarkers.contains(where: has) {
                    problems.append("Claude's data folder no longer contains the browser storage files Clatch expects (\(electronMarkers.joined(separator: ", "))).")
                }
                if !claudeMarkers.contains(where: has) {
                    problems.append("Claude's data folder no longer contains \(claudeMarkers.joined(separator: " or ")).")
                }
            }
        } else if claudeHasRunSinceLastSwitch {
            problems.append("Claude was used, but its data folder was not found at \(claudeData.path).")
        }

        if !problems.isEmpty {
            let found = alternatives.filter { fileManager.fileExists(atPath: $0.path) }
            if !found.isEmpty {
                problems.append("Claude may now keep its data in: \(found.map(\.path).joined(separator: ", ")).")
            }
        }
        return DataLayoutCheck(problems: problems)
    }
}
