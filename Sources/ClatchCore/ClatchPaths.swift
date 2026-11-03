// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import Foundation

/// Where Claude Desktop keeps its data and where Clatch keeps the other accounts.
///
/// Claude Desktop is an Electron app (bundle ID `com.anthropic.claudefordesktop`).
/// Electron puts everything that makes up a sign-in into one user-data folder,
/// `~/Library/Application Support/Claude`:
///
/// * `Cookies`, `Local Storage/`, `IndexedDB/`, `Session Storage/`: the claude.ai web session;
/// * `config.json`: app state, including `oauth:tokenCache`, encrypted with Electron safeStorage;
/// * `claude_desktop_config.json`: MCP servers and other tool settings (not tied to an account).
///
/// The safeStorage key lives in the login Keychain as "Claude Safe Storage". It
/// belongs to the app, not to a sign-in, so every copy of the folder decrypts with
/// the same key. Swapping the folder therefore swaps the account, and the
/// Keychain is never touched.
public struct ClatchPaths: Sendable, Equatable {
    /// Claude Desktop's live data folder.
    public var claudeData: URL
    /// Clatch's own folder: `accounts.json`, the switch journal and `Accounts/`.
    public var clatchRoot: URL

    public init(claudeData: URL, clatchRoot: URL) {
        self.claudeData = claudeData
        self.clatchRoot = clatchRoot
    }

    /// The real locations in the user's Library.
    public static var standard: ClatchPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return ClatchPaths(claudeData: support.appendingPathComponent("Claude", isDirectory: true),
                           clatchRoot: support.appendingPathComponent("Clatch", isDirectory: true))
    }

    public var stateFile: URL { clatchRoot.appendingPathComponent("accounts.json") }
    public var journalFile: URL { clatchRoot.appendingPathComponent("switch-journal.json") }
    /// The "standard folder" that holds the accounts that are not active.
    public var accountsFolder: URL { clatchRoot.appendingPathComponent("Accounts", isDirectory: true) }

    /// Where an inactive account's Claude data is parked.
    public func stash(for id: UUID) -> URL {
        accountsFolder
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
    }
}
