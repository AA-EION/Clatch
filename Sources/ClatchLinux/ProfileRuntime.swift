// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import ClatchCore
import Foundation
import Glibc

/// Keeps track of which profiles have a Claude running, starts and closes them.
///
/// A running Claude holds the single-instance lock in its data folder
/// (`SingletonLock` → "<host>-<pid>"). Clatch watches each profile's folder
/// (inotify through GIO), so it learns the moment a Claude starts or closes
/// on it, and follows each main process with a pidfd: no polling at rest.
@MainActor
final class ProfileRuntime {
    struct Instance: Equatable {
        var pid: pid_t
        var folder: URL
    }

    private(set) var instances: [UUID: Instance] = [:]
    var onChange: (() -> Void)?
    /// A profile's Claude ended without Clatch asking (the user quit it, or it crashed or was updated).
    var onUnexpectedExit: ((UUID) -> Void)?
    /// Last profile whose Claude was started or brought forward from Clatch.
    var lastActive: UUID?

    /// The data folder each profile runs on, supplied by the model.
    var folders: () -> [UUID: URL] = { [:] }

    private var watches: [String: FolderWatch] = [:]
    private var exitWatches: [pid_t: ExitWatch] = [:]
    private let quit = QuitRequester()
    private var closing: [UUID: Closing] = [:]
    private var closeTimer: GTimer?
    private var rescanTimer: GTimer?
    private var closeAllDone: (() -> Void)?

    private struct Closing {
        var pid: pid_t
        var folder: URL
        var askedAt: Date
        var then: [() -> Void]
        var progress: LinuxClaude.QuitProgress = .none
        var readySince: Date?
    }

    func start() { rescan() }

    // MARK: - Watching

    /// Re-reads every profile's lock (cheap: one readlink per profile) and updates the watches.
    func rescan() {
        rescanTimer = nil
        let folders = self.folders()
        var found: [UUID: Instance] = [:]
        for (id, folder) in folders {
            if let pid = Claude.runningMain(on: folder) { found[id] = Instance(pid: pid, folder: folder) }
        }
        // Watch each existing profile folder for its lock appearing or going away.
        var keep: Set<String> = []
        for folder in folders.values {
            let path = folder.path
            keep.insert(path)
            if watches[path] == nil, FileManager.default.fileExists(atPath: path) {
                watches[path] = FolderWatch(folder) { [weak self] name in
                    if name == "SingletonLock" { self?.scheduleRescan() }
                }
            }
        }
        // Profile folders that do not exist yet appear under their parents.
        for folder in folders.values where !FileManager.default.fileExists(atPath: folder.path) {
            let parent = folder.deletingLastPathComponent()
            keep.insert(parent.path)
            if watches[parent.path] == nil, FileManager.default.fileExists(atPath: parent.path) {
                watches[parent.path] = FolderWatch(parent) { [weak self] _ in self?.scheduleRescan() }
            }
        }
        for path in watches.keys where !keep.contains(path) { watches[path] = nil }

        let gone = instances.filter { found[$0.key]?.pid != $0.value.pid }
        for (id, instance) in gone {
            exitWatches[instance.pid]?.cancel()
            exitWatches[instance.pid] = nil
            quit.forget(instance.pid)
            if closing[id] == nil, found[id] == nil {
                Log.write("A profile's Claude ended on its own")
                onUnexpectedExit?(id)
            }
        }
        for (id, instance) in found where exitWatches[instance.pid] == nil {
            exitWatches[instance.pid] = ExitWatch(pid: instance.pid) { [weak self] in self?.scheduleRescan(after: 0.05) }
            if instances[id] == nil { Log.write("A profile's Claude started (pid \(instance.pid))") }
        }
        let changed = found != instances
        instances = found
        finishClosingIfDone()
        if changed { onChange?() }
    }

    private func scheduleRescan(after delay: TimeInterval = 0.15) {
        guard rescanTimer == nil else { return }
        rescanTimer = GTimer(delay, repeats: false) { [weak self] in self?.rescan() }
    }

    func isRunning(_ id: UUID) -> Bool { instances[id] != nil }

    // MARK: - Starting

    /// Brings a profile's Claude forward (it hands the request to the running
    /// instance) or starts it with the profile's environment and flags.
    func launchOrFocus(_ account: Account, dataFolder: URL?, activationToken: String?) throws {
        lastActive = account.id
        if isRunning(account.id) {
            try Claude.start(dataFolder: dataFolder, activationToken: activationToken)
            return
        }
        let problems = LaunchOptions.problems(arguments: account.arguments)
        let arguments = problems.isEmpty ? account.arguments : []
        if let folder = dataFolder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Claude.start(dataFolder: dataFolder, arguments: arguments, environment: account.environment,
                         activationToken: activationToken, newInstance: true)
        Log.write("Started Claude for a profile\(dataFolder == nil ? " (Claude's own folder)" : "")")
        scheduleRescan(after: 1)
    }

    /// Hands a link (claude://…) to the Claude running on this folder.
    func deliver(_ link: String, dataFolder: URL?) throws {
        try Claude.start(dataFolder: dataFolder, arguments: [link])
    }

    // MARK: - Closing

    /// Asks a profile's Claude to quit (Claude may ask the user first). `then` runs once it has closed.
    func close(_ id: UUID, then: (() -> Void)? = nil) {
        guard let instance = instances[id] else { then?(); return }
        if var existing = closing[id] {
            if let then { existing.then.append(then) }
            closing[id] = existing
            return
        }
        closing[id] = Closing(pid: instance.pid, folder: instance.folder, askedAt: Date(), then: then.map { [$0] } ?? [])
        quit.ask(instance.pid)
        startCloseTimer()
    }

    /// Asks again after the user said no in Claude's dialog (the next polite signal).
    func askAgain() {
        for (id, entry) in closing {
            if quit.ask(entry.pid) {
                closing[id]?.askedAt = Date()
                closing[id]?.progress = .none
            }
        }
        onChange?()
    }

    var canAskAgain: Bool { closing.values.contains { quit.canAskAgain($0.pid) } }

    /// Closing, and Claude has not agreed after a few seconds: it is asking, or was told no.
    var closeLooksDeclined: Bool {
        closing.values.contains { $0.progress != .readyToQuit && Date().timeIntervalSince($0.askedAt) > 3 }
    }

    var isClosing: Bool { !closing.isEmpty }

    /// Closes every profile's Claude except `except`, then calls `then`.
    func closeAll(except: Set<UUID>, then: @escaping () -> Void) {
        let targets = instances.keys.filter { !except.contains($0) }
        guard !targets.isEmpty else { return then() }
        closeAllDone = then
        targets.forEach { close($0) }
    }

    /// Stops waiting (the Claudes that are still open stay open).
    func cancelClosing() {
        closing.removeAll()
        closeAllDone = nil
        closeTimer = nil
        onChange?()
    }

    private func startCloseTimer() {
        guard closeTimer == nil else { return }
        // Exists only while a Claude is being closed.
        closeTimer = GTimer(0.5, repeats: true) { [weak self] in self?.checkClosing() }
    }

    /// Reads Claude's log for its answer. Once Claude has agreed and finished
    /// saving ("readyForQuit"), whatever is left after a few seconds is ended:
    /// nothing can be lost then. Without that line, Clatch never forces anything.
    private func checkClosing() {
        let snapshotNeeded = closing.values.contains { $0.readySince.map { Date().timeIntervalSince($0) > 5 } ?? false }
        let snapshot = snapshotNeeded ? Claude.Snapshot.take() : nil
        var changed = false
        for (id, entry) in closing {
            let progress = LinuxClaude.quitProgress(dataFolder: entry.folder, since: entry.askedAt)
            if progress != entry.progress {
                closing[id]?.progress = progress
                changed = true
                if progress == .readyToQuit { closing[id]?.readySince = Date() }
            }
            if let ready = closing[id]?.readySince, Date().timeIntervalSince(ready) > 5, let snapshot {
                let leftovers = snapshot.processes(of: entry.folder)
                if !leftovers.isEmpty {
                    Log.write("Claude agreed to quit and saved, but \(leftovers.count) process(es) stayed: ending them")
                    leftovers.forEach { _ = kill($0, SIGKILL) }
                }
            }
        }
        if changed { onChange?() }
        rescan()
    }

    private func finishClosingIfDone() {
        for (id, entry) in closing where instances[id]?.pid != entry.pid {
            closing[id] = nil
            entry.then.forEach { $0() }
        }
        if closing.isEmpty {
            closeTimer = nil
            if let done = closeAllDone {
                closeAllDone = nil
                done()
            }
        }
    }
}
