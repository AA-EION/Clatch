// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import AppKit
import ClatchCore

/// One running Claude, and the data folder it was started with.
struct ClaudeInstance: Equatable {
    let pid: pid_t
    /// nil: Claude's own folder (no --user-data-dir).
    let dataFolder: URL?
    let launchedAt: Date

    var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
}

/// Which Claude runs for which profile, kept up to date from the system's
/// launch and quit notifications (no polling). Side by side, it also starts,
/// focuses, closes and restarts each profile's Claude.
@MainActor
final class ProfileRuntime {
    /// Profile id → its running Claude.
    private(set) var instances: [UUID: ClaudeInstance] = [:]
    /// Called whenever an instance starts or ends (pid, profile, ended?).
    var onChange: (() -> Void)?
    /// A profile's Claude ended without Clatch asking (for the watchdog).
    var onUnexpectedExit: ((UUID, ClaudeInstance) -> Void)?

    private var observers: [NSObjectProtocol] = []
    /// Profiles Clatch is closing on purpose, so their exit is not "unexpected".
    private var closing: Set<UUID> = []
    /// Waiters for a profile's Claude to end (close + restart).
    private var exitWaiters: [UUID: [() -> Void]] = [:]
    private let profileFolder: (URL?) -> UUID?

    /// - Parameter profileFolder: maps a data folder (nil = Claude's own) to a profile id.
    init(profileFolder: @escaping (URL?) -> UUID?) {
        self.profileFolder = profileFolder
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == ClaudeApp.bundleIdentifier else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.didLaunch(pid) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == ClaudeApp.bundleIdentifier else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.didTerminate(pid) }
        })
        rescan()
    }

    /// Re-reads every running Claude (after the profile list changed, or at start).
    func rescan() {
        var found: [UUID: ClaudeInstance] = [:]
        for app in ClaudeApp.running {
            if let instance = describe(app.processIdentifier), let id = profileFolder(instance.dataFolder) {
                found[id] = instances[id]?.pid == instance.pid ? instances[id] : instance
            }
        }
        instances = found
        onChange?()
    }

    private func describe(_ pid: pid_t) -> ClaudeInstance? {
        let arguments = ProcessArguments.of(pid) ?? []
        let folder = ProcessArguments.userDataDir(in: arguments).map { URL(fileURLWithPath: $0).standardizedFileURL }
        return ClaudeInstance(pid: pid, dataFolder: folder, launchedAt: Date())
    }

    private func didLaunch(_ pid: pid_t) {
        guard let instance = describe(pid), let id = profileFolder(instance.dataFolder) else { return }
        instances[id] = instance
        Log.write("Claude started for a profile (pid \(pid))")
        onChange?()
    }

    private func didTerminate(_ pid: pid_t) {
        guard let (id, instance) = instances.first(where: { $0.value.pid == pid }) else { return }
        instances[id] = nil
        let expected = closing.remove(id) != nil
        if !expected { onUnexpectedExit?(id, instance) }
        exitWaiters.removeValue(forKey: id)?.forEach { $0() }
        onChange?()
    }

    func isRunning(_ id: UUID) -> Bool { instances[id] != nil }

    var runningCount: Int { instances.count }

    // MARK: - Side by side

    /// Brings the profile's Claude to the front, or starts it.
    /// - Parameters:
    ///   - dataFolder: the profile's folder; nil for Claude's own folder.
    func launchOrFocus(_ account: Account, dataFolder: URL?, activates: Bool = true, completion: ((Error?) -> Void)? = nil) {
        if let instance = instances[account.id], let app = instance.app, !app.isTerminated {
            guard activates else { completion?(nil); return }
            app.unhide()
            app.activate(options: [.activateAllWindows])
            completion?(nil)
            return
        }
        guard let claude = ClaudeApp.url else {
            completion?(ClatchError.claudeNotInstalled)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        // A separate Claude per profile: Electron's single-instance lock is per data folder.
        configuration.createsNewApplicationInstance = true
        var arguments: [String] = []
        if let dataFolder {
            try? FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
            arguments.append("--user-data-dir=\(dataFolder.path)")
        }
        arguments += account.arguments.filter { LaunchOptions.problems(arguments: [$0]).isEmpty }
        configuration.arguments = arguments
        if !account.environment.isEmpty { configuration.environment = account.environment }
        Log.write("Starting Claude for “\(account.name)”" + (dataFolder == nil ? " (Claude's own folder)" : ""))
        let token = UUID()
        if let completion { launchCompletions[token] = completion }
        NSWorkspace.shared.openApplication(at: claude, configuration: configuration) { [weak self] _, error in
            // Only Sendable values cross back to the main actor.
            let message = error?.localizedDescription
            Task { @MainActor in self?.finishLaunch(token, errorMessage: message) }
        }
    }

    private var launchCompletions: [UUID: (Error?) -> Void] = [:]

    private func finishLaunch(_ token: UUID, errorMessage: String?) {
        if let errorMessage { Log.write("Could not start Claude: \(errorMessage)") }
        launchCompletions.removeValue(forKey: token)?(errorMessage.map { ClatchError.launchFailed($0) })
    }

    /// Asks this profile's Claude to quit (it can still ask the user first).
    func close(_ id: UUID, then: (() -> Void)? = nil) {
        guard let instance = instances[id], let app = instance.app, !app.isTerminated else {
            then?()
            return
        }
        closing.insert(id)
        if let then { exitWaiters[id, default: []].append(then) }
        app.terminate()
    }

    /// Asks every profile's Claude to quit; `then` runs once all have ended.
    func closeAll(except keep: Set<UUID> = [], then: @escaping () -> Void) {
        let targets = instances.keys.filter { !keep.contains($0) }
        guard !targets.isEmpty else { return then() }
        var remaining = targets.count
        for id in targets {
            close(id) {
                remaining -= 1
                if remaining == 0 { then() }
            }
        }
    }

    /// Forgets pending close requests (the user cancelled, or Claude said no).
    func cancelClosing() {
        closing.removeAll()
        exitWaiters.removeAll()
    }
}

enum ClatchError: LocalizedError {
    case claudeNotInstalled
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .claudeNotInstalled: return "Claude Desktop is not installed in Applications."
        case .launchFailed(let message): return "Claude could not be started: \(message)"
        }
    }
}
