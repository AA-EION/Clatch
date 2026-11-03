// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import XCTest
@testable import ClatchCore

final class AccountStoreTests: XCTestCase {
    private var root: URL!
    private var paths: ClatchPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClatchTests-\(UUID().uuidString)", isDirectory: true)
        paths = ClatchPaths(claudeData: root.appendingPathComponent("Claude", isDirectory: true),
                            clatchRoot: root.appendingPathComponent("Clatch", isDirectory: true))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    /// Pretends Claude signed in: writes a marker into the live folder.
    private func writeLive(_ marker: String, config: String? = nil) throws {
        try FileManager.default.createDirectory(at: paths.claudeData, withIntermediateDirectories: true)
        try marker.write(to: paths.claudeData.appendingPathComponent("Cookies"), atomically: true, encoding: .utf8)
        if let config {
            try config.write(to: paths.claudeData.appendingPathComponent("claude_desktop_config.json"),
                             atomically: true, encoding: .utf8)
        }
    }

    private func liveMarker() -> String? {
        try? String(contentsOf: paths.claudeData.appendingPathComponent("Cookies"), encoding: .utf8)
    }

    private func liveConfig() -> String? {
        try? String(contentsOf: paths.claudeData.appendingPathComponent("claude_desktop_config.json"), encoding: .utf8)
    }

    // MARK: Tests

    func testFirstRunAdoptsCurrentSignInAsAccountOne() throws {
        try writeLive("alice")
        let store = AccountStore(paths: paths)
        XCTAssertEqual(store.state.accounts.count, 1)
        XCTAssertEqual(store.state.active?.name, "Account 1")
        XCTAssertEqual(liveMarker(), "alice", "first run must not move anything")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.stateFile.path))
    }

    func testAddAccountParksCurrentDataAndLeavesClaudeEmpty() throws {
        try writeLive("alice")
        let store = AccountStore(paths: paths, sharedItems: [])
        let alice = try XCTUnwrap(store.state.activeID)

        let bob = try store.addAccount(named: "Bob")

        XCTAssertEqual(store.state.activeID, bob.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.claudeData.path),
                       "Claude must start fresh to ask for a new sign-in")
        let parked = try String(contentsOf: paths.stash(for: alice).appendingPathComponent("Cookies"), encoding: .utf8)
        XCTAssertEqual(parked, "alice")
        XCTAssertFalse(store.hasInterruptedSwitch)
    }

    func testSwitchBackAndForthKeepsEachAccountsData() throws {
        try writeLive("alice")
        let store = AccountStore(paths: paths, sharedItems: [])
        let alice = try XCTUnwrap(store.state.activeID)
        let bob = try store.addAccount(named: "Bob")
        try writeLive("bob") // Claude signed Bob in

        try store.switchTo(alice)
        XCTAssertEqual(liveMarker(), "alice")
        XCTAssertEqual(store.state.activeID, alice)

        try store.switchTo(bob.id)
        XCTAssertEqual(liveMarker(), "bob")
        XCTAssertEqual(store.state.activeID, bob.id)

        // Survives a reload from disk.
        let reloaded = AccountStore(paths: paths, sharedItems: [])
        XCTAssertEqual(reloaded.state.activeID, bob.id)
        XCTAssertEqual(reloaded.state.accounts.map(\.name), ["Account 1", "Bob"])
    }

    func testSharedToolSettingsFollowTheUser() throws {
        try writeLive("alice", config: "{\"mcpServers\":{\"a\":{}}}")
        let store = AccountStore(paths: paths)
        let alice = try XCTUnwrap(store.state.activeID)

        try store.addAccount(named: "Bob")
        XCTAssertEqual(liveConfig(), "{\"mcpServers\":{\"a\":{}}}", "new account gets the MCP setup")

        try writeLive("bob", config: "{\"mcpServers\":{\"b\":{}}}")
        try store.switchTo(alice)
        XCTAssertEqual(liveMarker(), "alice")
        XCTAssertEqual(liveConfig(), "{\"mcpServers\":{\"b\":{}}}", "latest tool settings carried over")
    }

    func testRecoveryFinishesSwitchInterruptedAfterParking() throws {
        try writeLive("alice")
        let store = AccountStore(paths: paths, sharedItems: [])
        let alice = try XCTUnwrap(store.state.activeID)
        let bob = try store.addAccount(named: "Bob")
        try writeLive("bob")

        // Simulate a crash right after Bob was parked: journal written, Bob in
        // his stash, Alice still in hers, nothing live.
        let journal = AccountStore.Journal(from: bob.id, to: alice, newAccount: nil)
        try JSONEncoder().encode(journal).write(to: paths.journalFile)
        try FileManager.default.createDirectory(at: paths.stash(for: bob.id).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: paths.claudeData, to: paths.stash(for: bob.id))

        let restarted = AccountStore(paths: paths, sharedItems: [])
        XCTAssertTrue(restarted.hasInterruptedSwitch)
        try restarted.recoverInterruptedSwitch()
        XCTAssertFalse(restarted.hasInterruptedSwitch)
        XCTAssertEqual(liveMarker(), "alice")
        XCTAssertEqual(restarted.state.activeID, alice)
    }

    func testRecoveryFinishesSwitchInterruptedBeforeParking() throws {
        try writeLive("alice")
        let store = AccountStore(paths: paths, sharedItems: [])
        let alice = try XCTUnwrap(store.state.activeID)
        let bob = try store.addAccount(named: "Bob")
        try writeLive("bob")

        // Crash right after the journal was written: nothing moved yet.
        let journal = AccountStore.Journal(from: bob.id, to: alice, newAccount: nil)
        try JSONEncoder().encode(journal).write(to: paths.journalFile)

        let restarted = AccountStore(paths: paths, sharedItems: [])
        try restarted.recoverInterruptedSwitch()
        XCTAssertEqual(liveMarker(), "alice")
        let parked = try String(contentsOf: paths.stash(for: bob.id).appendingPathComponent("Cookies"), encoding: .utf8)
        XCTAssertEqual(parked, "bob")
    }

    func testCannotRemoveActiveAccount() throws {
        try writeLive("alice")
        let store = AccountStore(paths: paths, sharedItems: [])
        let alice = try XCTUnwrap(store.state.activeID)
        XCTAssertThrowsError(try store.remove(alice)) { error in
            XCTAssertEqual(error as? AccountStoreError, .cannotRemoveActive)
        }
    }

    func testRefusesToOverwriteUnexpectedData() throws {
        try writeLive("alice")
        let store = AccountStore(paths: paths, sharedItems: [])
        let alice = try XCTUnwrap(store.state.activeID)
        let stray = paths.stash(for: alice)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.addAccount(named: "Bob"))
        XCTAssertEqual(liveMarker(), "alice", "nothing may move when the parking spot is taken")
        XCTAssertEqual(store.state.accounts.count, 1)
    }

    func testNextAccountWrapsAround() {
        let a = Account(name: "A"), b = Account(name: "B"), c = Account(name: "C")
        var state = AccountsState(accounts: [a, b, c], activeID: c.id)
        XCTAssertEqual(state.next?.id, a.id)
        state.activeID = a.id
        XCTAssertEqual(state.next?.id, b.id)
        XCTAssertNil(AccountsState(accounts: [a], activeID: a.id).next)
    }

    func testInitials() {
        XCTAssertEqual(Account(name: "Work Account").initials, "WA")
        XCTAssertEqual(Account(name: "jane@example.com").initials, "JE")
        XCTAssertEqual(Account(name: "personal").initials, "PE")
    }

    func testDefaultShortcut() {
        XCTAssertEqual(KeyCombo.default.displayString, "⌃⌥⌘C")
        XCTAssertTrue(KeyCombo.default.isAcceptable)
        XCTAssertFalse(KeyCombo(keyCode: 8, modifiers: KeyCombo.shiftKey, keyLabel: "C").isAcceptable)
        XCTAssertTrue(KeyCombo(keyCode: 96, modifiers: 0, keyLabel: "F5").isAcceptable)
    }

    func testProcessScannerFindsThisTestRunner() throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        // Scanning the folder of a process other than ourselves: at least it must not crash
        // and must not report our own pid.
        let found = ProcessScanner.pids(withExecutableUnder: [executable.deletingLastPathComponent()])
        XCTAssertFalse(found.contains(getpid()))
        XCTAssertTrue(ProcessScanner.pids(withExecutableUnder: [root]).isEmpty)
    }

    // MARK: Fail-safe for a changed data layout

    func testLayoutCheckAcceptsNormalElectronFolder() throws {
        try writeLive("alice", config: "{}")
        try "{}".write(to: paths.claudeData.appendingPathComponent("Local State"), atomically: true, encoding: .utf8)
        try "{}".write(to: paths.claudeData.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(DataLayoutCheck.inspect(claudeData: paths.claudeData, claudeHasRunSinceLastSwitch: true).isRecognized)
    }

    func testLayoutCheckFlagsMissingFolderAfterClaudeRan() {
        let check = DataLayoutCheck.inspect(claudeData: paths.claudeData, claudeHasRunSinceLastSwitch: true)
        XCTAssertFalse(check.isRecognized)
        // A brand-new account that never opened Claude has no folder yet, which is fine.
        XCTAssertTrue(DataLayoutCheck.inspect(claudeData: paths.claudeData, claudeHasRunSinceLastSwitch: false).isRecognized)
    }

    func testLayoutCheckFlagsUnrecognizedContentsAndPointsToAlternatives() throws {
        try FileManager.default.createDirectory(at: paths.claudeData, withIntermediateDirectories: true)
        try "x".write(to: paths.claudeData.appendingPathComponent("something-new.db"), atomically: true, encoding: .utf8)
        let elsewhere = root.appendingPathComponent("Claude-3p")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let check = DataLayoutCheck.inspect(claudeData: paths.claudeData, claudeHasRunSinceLastSwitch: true,
                                            alternatives: [elsewhere, root.appendingPathComponent("Nope")])
        XCTAssertEqual(check.problems.count, 3)
        XCTAssertTrue(check.problems.last?.contains("Claude-3p") ?? false)
    }

    func testLayoutCheckAcceptsFolderHoldingOnlySharedSettings() throws {
        try FileManager.default.createDirectory(at: paths.claudeData, withIntermediateDirectories: true)
        try "{}".write(to: paths.claudeData.appendingPathComponent("claude_desktop_config.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(DataLayoutCheck.inspect(claudeData: paths.claudeData, claudeHasRunSinceLastSwitch: false).isRecognized)
    }

    func testFailedFirstMoveLeavesNoJournal() throws {
        try writeLive("alice")
        let store = AccountStore(paths: paths, sharedItems: [])
        // Make parking impossible: the Accounts folder is a file.
        try FileManager.default.createDirectory(at: paths.clatchRoot, withIntermediateDirectories: true)
        try "x".write(to: paths.accountsFolder, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.addAccount(named: "Bob"))
        XCTAssertFalse(store.hasInterruptedSwitch)
        XCTAssertEqual(liveMarker(), "alice")
    }
}
