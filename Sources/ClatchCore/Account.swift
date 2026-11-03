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
    /// Text on the profile's badge (a letter or an emoji); nil = first letter of the name.
    public var badge: String?
    /// Badge colour as "#RRGGBB"; nil = a colour picked from the id.
    public var colorHex: String?
    /// Environment variables for this profile's Claude (applied when it starts).
    public var environment: [String: String]
    /// Extra command-line flags for this profile's Claude (applied when it starts).
    public var arguments: [String]

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), lastUsedAt: Date? = nil,
                badge: String? = nil, colorHex: String? = nil,
                environment: [String: String] = [:], arguments: [String] = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.badge = badge
        self.colorHex = colorHex
        self.environment = environment
        self.arguments = arguments
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, lastUsedAt, badge, colorHex, environment, arguments
    }

    /// Reads accounts saved by older versions, which lack the newer fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        badge = try c.decodeIfPresent(String.self, forKey: .badge)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
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

    /// What the profile's badge shows: the custom badge, else the name's first letter.
    public var badgeText: String {
        if let badge, !badge.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(badge.trimmingCharacters(in: .whitespaces).prefix(2))
        }
        return name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }

    /// The badge colour: the chosen one, else a stable pick from a palette by id.
    public var resolvedColorHex: String {
        if let colorHex, Account.isValidColor(colorHex) { return colorHex.uppercased() }
        let hash = id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Account.palette[hash % Account.palette.count]
    }

    /// Colours offered in the profile editor (readable with white text, light and dark mode).
    public static let palette = ["#D97757", "#0A84FF", "#AF52DE", "#30A14E", "#E5487D", "#0FA3B1", "#5E5CE6", "#B07D48"]

    public static func isValidColor(_ hex: String) -> Bool {
        let body = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        return body.count == 6 && body.allSatisfy(\.isHexDigit)
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
