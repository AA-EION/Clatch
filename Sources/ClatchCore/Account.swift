// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import Foundation

/// One Claude Desktop sign-in that Clatch keeps.
///
/// Clatch never reads or stores credentials. An account is only a name for a
/// copy of Claude Desktop's own data folder: the active account's data is the
/// live folder Claude uses, every other account's data waits in Clatch's
/// accounts folder until it is switched to.
public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    /// Up to two letters for the avatar: "Work Account" → "WA", "personal" → "PE".
    public var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." || $0 == "@" })
        if words.count >= 2, let a = words[0].first, let b = words[1].first {
            return String([a, b]).uppercased()
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(2)).uppercased()
    }
}

/// What Clatch persists in `accounts.json`.
public struct AccountsState: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var accounts: [Account]
    /// The account whose data is in Claude's live folder right now.
    public var activeID: UUID?

    public init(accounts: [Account] = [], activeID: UUID? = nil) {
        self.version = Self.currentVersion
        self.accounts = accounts
        self.activeID = activeID
    }

    public var active: Account? { accounts.first { $0.id == activeID } }

    /// The account after the active one, wrapping around: what the keyboard
    /// shortcut switches to.
    public var next: Account? {
        guard accounts.count > 1 else { return nil }
        guard let index = accounts.firstIndex(where: { $0.id == activeID }) else { return accounts.first }
        return accounts[(index + 1) % accounts.count]
    }
}
