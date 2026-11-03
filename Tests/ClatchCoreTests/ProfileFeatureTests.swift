// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import XCTest
@testable import ClatchCore

final class ProfileFeatureTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ClatchProfiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Profile model

    func testOldAccountsFilesStillLoad() throws {
        let json = #"{"id":"6E1B3C2A-9F4D-4A51-8C0B-3D2E7A9F1C55","name":"Work","createdAt":"2026-01-01T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let account = try decoder.decode(Account.self, from: Data(json.utf8))
        XCTAssertEqual(account.name, "Work")
        XCTAssertEqual(account.environment, [:])
        XCTAssertEqual(account.arguments, [])
        XCTAssertNil(account.badge)
    }

    func testBadgeAndColour() {
        var account = Account(name: "personal")
        XCTAssertEqual(account.badgeText, "P")
        account.badge = "🚀"
        XCTAssertEqual(account.badgeText, "🚀")
        XCTAssertTrue(Account.palette.contains(account.resolvedColorHex))
        account.colorHex = "#123abc"
        XCTAssertEqual(account.resolvedColorHex, "#123ABC")
        account.colorHex = "nope"
        XCTAssertTrue(Account.palette.contains(account.resolvedColorHex))
    }

    func testSideBySideProfilesNeedNoMoves() throws {
        let paths = ClatchPaths(claudeData: root.appendingPathComponent("Claude"), clatchRoot: root.appendingPathComponent("Clatch"))
        let store = AccountStore(paths: paths, sharedItems: [])
        let main = try XCTUnwrap(store.state.activeID)
        let work = try store.createProfile(named: "Work")
        XCTAssertEqual(store.state.activeID, main, "creating a profile side by side keeps the active one")
        XCTAssertEqual(store.dataFolder(for: main), paths.claudeData)
        XCTAssertEqual(store.dataFolder(for: work.id), paths.stash(for: work.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.stash(for: work.id).path))

        // The same profile also works one at a time.
        try FileManager.default.createDirectory(at: paths.claudeData, withIntermediateDirectories: true)
        try store.switchTo(work.id)
        XCTAssertEqual(store.state.activeID, work.id)
    }

    func testEditingAProfile() throws {
        let paths = ClatchPaths(claudeData: root.appendingPathComponent("Claude"), clatchRoot: root.appendingPathComponent("Clatch"))
        let store = AccountStore(paths: paths, sharedItems: [])
        var account = try XCTUnwrap(store.state.active)
        account.name = "  Work  "
        account.environment = ["HTTPS_PROXY": "http://proxy:8080"]
        account.arguments = ["--lang=es"]
        try store.update(account)
        let reloaded = AccountStore(paths: paths, sharedItems: [])
        XCTAssertEqual(reloaded.state.active?.name, "Work")
        XCTAssertEqual(reloaded.state.active?.environment["HTTPS_PROXY"], "http://proxy:8080")
        XCTAssertEqual(reloaded.state.active?.arguments, ["--lang=es"])
    }

    // MARK: Launch options

    func testArgumentsRoundTrip() {
        let line = #"--lang=es --proxy-server="http://a b:80" -v"#
        let parsed = LaunchOptions.parseArguments(line)
        XCTAssertEqual(parsed, ["--lang=es", "--proxy-server=http://a b:80", "-v"])
        XCTAssertEqual(LaunchOptions.parseArguments(LaunchOptions.formatArguments(parsed)), parsed)
        XCTAssertFalse(LaunchOptions.problems(arguments: ["--user-data-dir=/tmp/x"]).isEmpty)
        XCTAssertTrue(LaunchOptions.problems(arguments: ["--lang=es"]).isEmpty)
    }

    func testEnvironmentParsing() {
        let result = LaunchOptions.parseEnvironment("# proxy\nHTTPS_PROXY=http://p:1\n\nBAD-NAME=x\nNOEQUALS\nEMPTY=")
        XCTAssertEqual(result.values, ["HTTPS_PROXY": "http://p:1", "EMPTY": ""])
        XCTAssertEqual(result.problems.count, 2)
    }

    // MARK: Links and versions

    func testSignInLinks() {
        XCTAssertTrue(ClaudeLink.isSignIn("claude://login/abc"))
        XCTAssertTrue(ClaudeLink.isSignIn("claude://claude.ai/sso-callback?code=1"))
        XCTAssertFalse(ClaudeLink.isSignIn("claude://claude.ai/sso-callbackX"))
        XCTAssertFalse(ClaudeLink.isSignIn("claude://claude.ai/new"))
        XCTAssertFalse(ClaudeLink.describe("claude://claude.ai/sso-callback?code=SECRET").contains("SECRET"))
    }

    func testVersionOrdering() throws {
        let v = { (s: String) in try XCTUnwrap(AppVersion(s)) }
        XCTAssertLessThan(try v("0.1.0-beta.1"), try v("0.1.0-beta.2"))
        XCTAssertLessThan(try v("0.1.0-beta.2"), try v("0.1.0"))
        XCTAssertLessThan(try v("0.1.0"), try v("v0.2.0-beta.1"))
        XCTAssertLessThan(try v("0.9"), try v("0.10.0"))
        XCTAssertEqual(try v("1.0"), try v("1.0.0"))
        XCTAssertNil(AppVersion("latest"))
    }

    // MARK: Code-tab chats

    private func writeSession(_ profile: URL, account: String, org: String, id: String, json: String) throws -> URL {
        let folder = profile.appendingPathComponent("claude-code-sessions/\(account)/\(org)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("local_\(id).json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func testDiscoversAndCopiesCodeChats() throws {
        let source = root.appendingPathComponent("A"), target = root.appendingPathComponent("B")
        _ = try writeSession(source, account: "acct-a", org: "org-a", id: "1111", json: #"{"title":"Fix the build","cwd":"/Users/me/clatch"}"#)
        _ = try writeSession(source, account: "acct-a", org: "org-a", id: "2222", json: #"{"cwd":"/x/scratch-workspaces/y"}"#)
        let sessions = CodeSessions.discover(inProfile: source)
        XCTAssertEqual(sessions.count, 2)
        let fix = try XCTUnwrap(sessions.first { $0.title == "Fix the build" })
        XCTAssertEqual(fix.folder, "clatch")
        XCTAssertTrue(sessions.contains { $0.title == "Chat 2222" && $0.folder == "(no folder)" })

        // The target never opened the Code tab: refuse with a helpful message.
        XCTAssertThrowsError(try CodeSessions.copy(fix, toProfile: target, profileName: "B")) { error in
            XCTAssertEqual(error as? CodeSessionError, .targetNeverOpenedCodeTab("B"))
        }
        // Once it has, the chat lands under its account and organisation.
        try FileManager.default.createDirectory(at: target.appendingPathComponent("claude-code-sessions/acct-b/org-b"),
                                                withIntermediateDirectories: true)
        let copied = try CodeSessions.copy(fix, toProfile: target, profileName: "B")
        XCTAssertEqual(copied.deletingLastPathComponent().lastPathComponent, "org-b")
        XCTAssertEqual(CodeSessions.discover(inProfile: target).map(\.title), ["Fix the build"])
        XCTAssertThrowsError(try CodeSessions.copy(fix, toProfile: target, profileName: "B")) { error in
            XCTAssertEqual(error as? CodeSessionError, .alreadyThere)
        }
    }
}
