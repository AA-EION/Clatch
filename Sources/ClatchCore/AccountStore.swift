// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import Foundation

public enum AccountStoreError: LocalizedError, Equatable {
    case unknownAccount
    case alreadyActive
    case cannotRemoveActive
    case stashOccupied(String)
    case recoveryNeeded

    public var errorDescription: String? {
        switch self {
        case .unknownAccount:
            return "That account no longer exists."
        case .alreadyActive:
            return "That account is already active."
        case .cannotRemoveActive:
            return "Switch to another account before removing this one."
        case .stashOccupied(let path):
            return "Clatch found unexpected data at \(path). Move it away and try again."
        case .recoveryNeeded:
            return "An earlier switch did not finish. Quit Claude so Clatch can complete it."
        }
    }
}

/// Keeps the account list and moves Claude's data folder between accounts.
///
/// **Only call the switching methods while Claude Desktop is not running.**
/// The app layer makes sure of that (see `SwitchCoordinator`).
///
/// Switching is two `rename(2)` calls on the same volume, so it is instant no
/// matter how much data an account has, and nothing is ever copied or
/// rewritten. Every step is written to a journal first; if Clatch or the Mac
/// stops halfway, `recoverInterruptedSwitch()` finishes the switch the next
/// time Clatch starts.
public final class AccountStore {
    public let paths: ClatchPaths
    /// Files that belong to this Mac rather than to an account. They follow
    /// the user from account to account (copied from the outgoing account
    /// into the incoming one on every switch). Empty to keep everything separate.
    public var sharedItems: [String]

    public private(set) var state: AccountsState

    private let fileManager: FileManager

    public static let defaultSharedItems = ["claude_desktop_config.json"]

    public init(paths: ClatchPaths = .standard,
                sharedItems: [String] = AccountStore.defaultSharedItems,
                fileManager: FileManager = .default) {
        self.paths = paths
        self.sharedItems = sharedItems
        self.fileManager = fileManager
        self.state = AccountsState()
        load()
    }

    // MARK: - Persistence

    /// Reads `accounts.json`. The first time Clatch runs there is none: the
    /// account that is signed in to Claude right now becomes "Account 1".
    public func load() {
        if let data = try? Data(contentsOf: paths.stateFile),
           let decoded = try? Self.decoder.decode(AccountsState.self, from: data),
           !decoded.accounts.isEmpty {
            state = decoded
            if state.active == nil { state.activeID = state.accounts.first?.id }
            return
        }
        let first = Account(name: "Account 1", lastUsedAt: Date())
        state = AccountsState(accounts: [first], activeID: first.id)
        try? save()
    }

    public func save() throws {
        try fileManager.createDirectory(at: paths.clatchRoot, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(state)
        try data.write(to: paths.stateFile, options: .atomic)
    }

    // MARK: - Editing

    public func rename(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = state.accounts.firstIndex(where: { $0.id == id }) else { return }
        state.accounts[index].name = trimmed
        try save()
    }

    public func move(_ id: UUID, by offset: Int) throws {
        guard let index = state.accounts.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard state.accounts.indices.contains(target) else { return }
        state.accounts.swapAt(index, target)
        try save()
    }

    /// Removes an inactive account and moves its data to the Trash, so a
    /// mistake can still be undone from Finder.
    public func remove(_ id: UUID) throws {
        guard id != state.activeID else { throw AccountStoreError.cannotRemoveActive }
        guard let index = state.accounts.firstIndex(where: { $0.id == id }) else {
            throw AccountStoreError.unknownAccount
        }
        let folder = paths.stash(for: id).deletingLastPathComponent()
        if fileManager.fileExists(atPath: folder.path) {
            #if os(macOS)
            try fileManager.trashItem(at: folder, resultingItemURL: nil)
            #else
            try fileManager.removeItem(at: folder)
            #endif
        }
        state.accounts.remove(at: index)
        try save()
    }

    /// A name for the next new account that is not taken yet.
    public func suggestedNewName() -> String {
        var n = state.accounts.count + 1
        let names = Set(state.accounts.map(\.name))
        while names.contains("Account \(n)") { n += 1 }
        return "Account \(n)"
    }

    public func hasStoredData(_ id: UUID) -> Bool {
        if id == state.activeID { return fileManager.fileExists(atPath: paths.claudeData.path) }
        return fileManager.fileExists(atPath: paths.stash(for: id).path)
    }

    // MARK: - Switching

    struct Journal: Codable, Equatable {
        var from: UUID
        var to: UUID
        /// Only set when the switch creates the account.
        var newAccount: Account?
    }

    /// Makes `id` the active account. Claude must not be running.
    public func switchTo(_ id: UUID) throws {
        guard state.accounts.contains(where: { $0.id == id }) else { throw AccountStoreError.unknownAccount }
        guard id != state.activeID else { throw AccountStoreError.alreadyActive }
        try perform(Journal(from: try activeIDOrThrow(), to: id, newAccount: nil))
    }

    /// Parks the active account's data and leaves Claude's folder empty, so
    /// Claude starts as if freshly installed and asks the user to sign in.
    /// Claude must not be running.
    @discardableResult
    public func addAccount(named name: String) throws -> Account {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = Account(name: trimmed.isEmpty ? suggestedNewName() : trimmed)
        try perform(Journal(from: try activeIDOrThrow(), to: account.id, newAccount: account))
        return account
    }

    private func activeIDOrThrow() throws -> UUID {
        if let id = state.activeID { return id }
        // No active account recorded (should not happen): adopt the live data as a new one.
        let adopted = Account(name: suggestedNewName(), lastUsedAt: Date())
        state.accounts.append(adopted)
        state.activeID = adopted.id
        try save()
        return adopted.id
    }

    public var hasInterruptedSwitch: Bool { fileManager.fileExists(atPath: paths.journalFile.path) }

    /// Finishes a switch that was interrupted. Safe to call at any time Claude
    /// is not running; does nothing when there is no journal.
    public func recoverInterruptedSwitch() throws {
        guard let data = try? Data(contentsOf: paths.journalFile) else { return }
        guard let journal = try? Self.decoder.decode(Journal.self, from: data) else {
            try? fileManager.removeItem(at: paths.journalFile)
            return
        }
        try advance(journal)
    }

    private func perform(_ journal: Journal) throws {
        // Refuse before changing anything if the incoming slot is in a state
        // we did not create.
        let outgoing = paths.stash(for: journal.from)
        if fileManager.fileExists(atPath: outgoing.path) {
            throw AccountStoreError.stashOccupied(outgoing.path)
        }
        try fileManager.createDirectory(at: paths.clatchRoot, withIntermediateDirectories: true)
        try Self.encoder.encode(journal).write(to: paths.journalFile, options: .atomic)
        try advance(journal)
    }

    /// Idempotent: each step looks at the disk and only does what is still
    /// missing, so it can be re-run after a crash at any point.
    private func advance(_ journal: Journal) throws {
        let live = paths.claudeData
        let outgoing = paths.stash(for: journal.from)
        let incoming = paths.stash(for: journal.to)

        // 1. Park the outgoing account. Its data is still live as long as it
        //    has not been parked yet: incoming data only moves in afterwards.
        if exists(live) && !exists(outgoing) {
            try fileManager.createDirectory(at: outgoing.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try fileManager.moveItem(at: live, to: outgoing)
        }

        // 2. Bring in the incoming account (a new account has nothing to bring).
        if !exists(live) && exists(incoming) {
            try fileManager.moveItem(at: incoming, to: live)
            try? fileManager.removeItem(at: incoming.deletingLastPathComponent())
        }

        // 3. Carry machine-wide settings over (MCP servers and so on).
        if exists(outgoing) {
            for item in sharedItems where !item.isEmpty && !item.contains("/") {
                let source = outgoing.appendingPathComponent(item)
                guard exists(source) else { continue }
                try fileManager.createDirectory(at: live, withIntermediateDirectories: true)
                let destination = live.appendingPathComponent(item)
                if exists(destination) { try fileManager.removeItem(at: destination) }
                try fileManager.copyItem(at: source, to: destination)
            }
        }

        // 4. Record the result, then drop the journal.
        if let account = journal.newAccount, !state.accounts.contains(where: { $0.id == account.id }) {
            state.accounts.append(account)
        }
        if state.accounts.contains(where: { $0.id == journal.to }) {
            state.activeID = journal.to
            if let index = state.accounts.firstIndex(where: { $0.id == journal.to }) {
                state.accounts[index].lastUsedAt = Date()
            }
        }
        try save()
        try? fileManager.removeItem(at: paths.journalFile)
    }

    private func exists(_ url: URL) -> Bool {
        // lstat semantics: a dangling symlink still counts as "something is there".
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
