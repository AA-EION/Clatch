// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import ClatchCore
import Foundation
import XCTest

final class LinuxHelperTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clatch-linux-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testReadsTheSingleInstanceLock() throws {
        XCTAssertEqual(LinuxClaude.parseLock("EION-LEN-LOQ-82XV-18329"), .init(host: "EION-LEN-LOQ-82XV", pid: 18329))
        XCTAssertNil(LinuxClaude.parseLock("nohyphen"))
        XCTAssertNil(LinuxClaude.parseLock("host-abc"))
        let folder = root.appendingPathComponent("Claude")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertNil(LinuxClaude.lockOwner(of: folder))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("SingletonLock").path,
                                                   withDestinationPath: "my-host-4242")
        XCTAssertEqual(LinuxClaude.lockOwner(of: folder), .init(host: "my-host", pid: 4242))
    }

    func testQuitProgressFromClaudesLog() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let asked = Date()
        let before = formatter.string(from: asked.addingTimeInterval(-60))
        let after = formatter.string(from: asked.addingTimeInterval(1))
        let old = "\(before) [info] Successully ran all onQuitCleanup handlers, marking readyForQuit\n"
        XCTAssertEqual(LinuxClaude.quitProgress(inLog: old, since: asked), .none, "an earlier quit does not count")
        let asking = old + "\(after) [info] beforeQuit: vetoed by before-quit interceptor\n"
        XCTAssertEqual(LinuxClaude.quitProgress(inLog: asking, since: asked), .asking)
        let ready = asking + "\(after) [info] Successully ran all onQuitCleanup handlers, marking readyForQuit\n"
        XCTAssertEqual(LinuxClaude.quitProgress(inLog: ready, since: asked), .readyToQuit)

        let logs = root.appendingPathComponent("Claude/logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try ready.write(to: logs.appendingPathComponent("main.log"), atomically: true, encoding: .utf8)
        XCTAssertEqual(LinuxClaude.quitProgress(dataFolder: root.appendingPathComponent("Claude"), since: asked), .readyToQuit)
    }

    func testDpkgVersion() {
        let status = """
        Package: claude-desktop-helper
        Status: install ok installed
        Version: 9.9

        Package: claude-desktop
        Status: install ok installed
        Architecture: amd64
        Version: 6.28899.6

        Package: removed-thing
        Status: deinstall ok config-files
        Version: 1.0
        """
        XCTAssertEqual(LinuxClaude.packageVersion("claude-desktop", inDpkgStatus: status), "6.28899.6")
        XCTAssertNil(LinuxClaude.packageVersion("removed-thing", inDpkgStatus: status))
    }

    func testReadsTheDefaultLinkHandler() {
        let text = """
        [Added Associations]
        x-scheme-handler/claude=com.anthropic.Claude.desktop;com.issensoftware.Clatch.desktop;

        [Default Applications]
        text/html=firefox.desktop
        x-scheme-handler/claude = com.issensoftware.Clatch.desktop;com.anthropic.Claude.desktop;
        """
        XCTAssertEqual(LinuxClaude.defaultHandler(for: "x-scheme-handler/claude", inMimeapps: text), "com.issensoftware.Clatch.desktop")
        XCTAssertNil(LinuxClaude.defaultHandler(for: "x-scheme-handler/claude", inMimeapps: "[Added Associations]\nx-scheme-handler/claude=a.desktop\n"))
    }

    func testDesktopEntryQuoting() {
        XCTAssertEqual(LinuxClaude.execArgument("/usr/bin/clatch"), "/usr/bin/clatch")
        XCTAssertEqual(LinuxClaude.execArgument("/opt/my apps/clatch"), "\"/opt/my apps/clatch\"")
        XCTAssertEqual(LinuxClaude.execArgument("100%"), "100%%")
        XCTAssertEqual(LinuxClaude.desktopValue("a\nb\\c"), "a\\nb\\\\c")
        let id = UUID()
        let entry = LinuxClaude.profileLauncher(name: "Work\nX", profile: id, executable: "/usr/bin/clatch", icon: "/tmp/i.png")
        XCTAssertTrue(entry.contains("Name=Claude – Work\\nX"))
        XCTAssertTrue(entry.contains("Exec=/usr/bin/clatch --launch \(id.uuidString.lowercased())"))
    }

    #if os(Linux)
    func testTrashKeepsWhereItCameFrom() throws {
        let trash = root.appendingPathComponent("Trash")
        for _ in 0..<2 {
            let item = root.appendingPathComponent("Profile")
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
            try "x".write(to: item.appendingPathComponent("Cookies"), atomically: true, encoding: .utf8)
            try Trash.move(item, trash: trash)
            XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: trash.appendingPathComponent("files").path).sorted()
        XCTAssertEqual(files, ["Profile", "Profile.2"])
        let info = try String(contentsOf: trash.appendingPathComponent("info/Profile.2.trashinfo"), encoding: .utf8)
        XCTAssertTrue(info.hasPrefix("[Trash Info]\nPath=\(root.standardizedFileURL.path)/Profile\nDeletionDate="))
    }

    func testProcHelpers() {
        let me = getpid()
        XCTAssertNotNil(ProcessScanner.executable(of: me))
        XCTAssertEqual(ProcessScanner.parent(of: me), getppid())
        XCTAssertTrue(ProcessScanner.allPids().contains(me))
        XCTAssertNotNil(ProcessArguments.of(me))
    }
    #endif
}
