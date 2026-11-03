// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import AppKit
import ClatchCore

/// Claude Desktop as seen from the outside: where it is installed and whether
/// it is running.
@MainActor
enum ClaudeApp {
    static let bundleIdentifier = "com.anthropic.claudefordesktop"

    static var url: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    static var isInstalled: Bool { url != nil }

    /// Claude's installed build number, read fresh from its bundle (the watchdog
    /// compares it before and after a Claude quits on its own).
    static var version: String? {
        guard let url else { return nil }
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        return (info?["CFBundleVersion"] as? String) ?? (info?["CFBundleShortVersionString"] as? String)
    }

    /// Main app instances (normally one).
    static var running: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
    }

    static var isRunning: Bool { !running.isEmpty }

    /// Any process still running from Claude.app or from Claude's data folder:
    /// Electron helpers, local Claude Code sessions.
    static func leftoverProcesses(dataFolder: URL) -> [pid_t] {
        var folders = [dataFolder]
        if let url { folders.append(url) }
        return ProcessScanner.pids(withExecutableUnder: folders)
    }

    /// Asks Claude to quit the normal way (the same Apple Event as ⌘Q or
    /// Quit in the Dock). Claude can still ask the user to confirm, e.g.
    /// while a local session is running, and the user can say no. Never forced.
    static func requestQuit() {
        for app in running { app.terminate() }
    }

    static func open() {
        guard let url else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }
}
