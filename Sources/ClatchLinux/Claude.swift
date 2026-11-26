// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import CGtk
import ClatchCore
import Foundation
import Glibc

/// Claude Desktop for Linux: where it is installed, which of its processes
/// belong to which data folder, and how to start and politely close it.
///
/// Anthropic's package installs to /usr/lib/claude-desktop with
/// /usr/bin/claude-desktop pointing there; community builds use the same
/// command name. Claude keeps its data in ~/.config/Claude.
enum Claude {
    static let desktopEntry = "com.anthropic.Claude.desktop"

    /// The real executable (symlinks resolved), or nil when Claude is not installed.
    static var executable: String? {
        var candidates = ["/usr/lib/claude-desktop/claude-desktop"]
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin").split(separator: ":") {
            candidates.append("\(dir)/claude-desktop")
        }
        for candidate in candidates where access(candidate, X_OK) == 0 {
            return URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
        }
        return nil
    }

    static var isInstalled: Bool { executable != nil }

    /// The folder Claude is installed in (its helpers live inside it).
    static var installFolder: String? { executable.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } }

    /// Claude's own app icon (256 px when available).
    static var iconFile: String? {
        var candidates = ["/usr/share/icons/hicolor/256x256/apps/claude-desktop.png",
                          "/usr/share/pixmaps/claude-desktop.png",
                          "/usr/share/icons/hicolor/128x128/apps/claude-desktop.png"]
        if let folder = installFolder { candidates.insert("\(folder)/resources/icon.png", at: 1) }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// The installed version (dpkg), or the app.asar date for other installs.
    static var version: String? {
        if let version = LinuxClaude.installedVersion() { return version }
        guard let folder = installFolder,
              let date = (try? FileManager.default.attributesOfItem(atPath: "\(folder)/resources/app.asar"))?[.modificationDate] as? Date
        else { return nil }
        return "build-\(Int(date.timeIntervalSince1970))"
    }

    static var dataFolder: URL { ClatchPaths.standard.claudeData }

    // MARK: - Processes

    struct Proc {
        var pid: pid_t
        var parent: pid_t
        var executable: String
        var arguments: [String]
    }

    /// One snapshot of the user's processes that matter: Claude's, and everything started by a Claude.
    struct Snapshot {
        /// Main processes (no --type=) and the data folder each one runs on (nil: Claude's own).
        var mains: [pid_t: String?] = [:]
        /// Every process that belongs to a data folder (path; "" for Claude's own), with its pids.
        var byFolder: [String: [pid_t]] = [:]

        /// `folders`: the profiles' data folders, so that processes which only
        /// mention one (Claude Code running from it, the Cowork VM's disks) are
        /// found even after Claude itself has exited and they were re-parented.
        static func take(folders: [URL] = []) -> Snapshot {
            guard let install = installFolder else { return Snapshot() }
            let prefix = install + "/"
            let mainName = URL(fileURLWithPath: executable ?? "").lastPathComponent
            var procs: [pid_t: Proc] = [:]
            for pid in ProcessScanner.allPids() where pid != getpid() {
                guard let exe = ProcessScanner.executable(of: pid) else { continue }
                procs[pid] = Proc(pid: pid, parent: ProcessScanner.parent(of: pid) ?? 0, executable: exe,
                                  arguments: ProcessArguments.of(pid) ?? [])
            }
            var snapshot = Snapshot()
            for p in procs.values where p.executable.hasPrefix(prefix)
                && URL(fileURLWithPath: p.executable).lastPathComponent == mainName
                && !p.arguments.contains(where: { $0.hasPrefix("--type=") }) {
                // updateValue keeps a nil value (Claude's own folder); assigning nil would remove the entry.
                snapshot.mains.updateValue(ProcessArguments.userDataDir(in: p.arguments).map(normalize), forKey: p.pid)
            }
            let known = ([Claude.dataFolder] + folders).map { normalize($0.path) + "/" }
            for p in procs.values {
                var folder: String??
                // Its own arguments first: helpers carry the folder (the crash reporter as --database=<folder>/Crashpad).
                if let dir = ProcessArguments.userDataDir(in: p.arguments) {
                    folder = .some(normalize(dir))
                } else if p.executable.hasPrefix(prefix), let db = ProcessArguments.value(of: "--database", in: p.arguments),
                          db.hasSuffix("/Crashpad") {
                    folder = .some(normalize(String(db.dropLast("/Crashpad".count))))
                }
                // Otherwise the nearest Claude main process it descends from (Code sessions, MCP servers, Cowork).
                if folder == nil {
                    if let main = snapshot.mains[p.pid] { folder = .some(main) }
                    var current = p.parent, hops = 0
                    while folder == nil, current > 1, hops < 64 {
                        if let main = snapshot.mains[current] { folder = .some(main) }
                        current = procs[current]?.parent ?? 0
                        hops += 1
                    }
                }
                // Re-parented leftovers: running from, or pointing into, a profile folder.
                if folder == nil {
                    let text = ([p.executable] + p.arguments).joined(separator: " ")
                    if let match = known.filter({ text.contains($0) }).max(by: { $0.count < $1.count }) {
                        folder = .some(String(match.dropLast()))
                    } else if p.executable.hasPrefix(prefix) {
                        folder = .some(nil) // one of Claude's own helpers, on its own folder
                    }
                }
                guard let resolved = folder else { continue }
                snapshot.byFolder[key(resolved), default: []].append(p.pid)
            }
            return snapshot
        }

        /// The processes of a data folder.
        func processes(of folder: URL) -> [pid_t] {
            byFolder[Snapshot.key(for: folder)] ?? []
        }

        /// The main process running on this folder, if any.
        func main(of folder: URL) -> pid_t? {
            let wanted = Snapshot.key(for: folder)
            return mains.first { Snapshot.key($0.value) == wanted }?.key
        }

        static func key(for folder: URL) -> String {
            let path = normalize(folder.path)
            return path == normalize(Claude.dataFolder.path) ? "" : path
        }

        static func key(_ folder: String?) -> String {
            guard let folder else { return "" }
            return key(for: URL(fileURLWithPath: folder))
        }
    }

    static func normalize(_ path: String) -> String {
        var p = URL(fileURLWithPath: path).standardizedFileURL.path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Is a Claude running on this data folder? Its single-instance lock says so, checked against the process.
    static func runningMain(on folder: URL) -> pid_t? {
        guard let owner = LinuxClaude.lockOwner(of: folder), owner.host == hostName, ProcessScanner.isAlive(owner.pid),
              let exe = ProcessScanner.executable(of: owner.pid), let install = installFolder,
              exe.hasPrefix(install + "/") else { return nil }
        return owner.pid
    }

    static let hostName: String = {
        var buffer = [CChar](repeating: 0, count: 256)
        gethostname(&buffer, buffer.count - 1)
        return String(cString: buffer)
    }()

    // MARK: - Starting Claude

    /// Starts Claude (detached: its own session, no terminal), optionally on a
    /// data folder, with extra arguments and environment variables. If a Claude
    /// already runs on that folder, it hands the arguments over and exits:
    /// that brings the window forward, or delivers a link.
    /// `newInstance`: a Claude is really starting (not handing over to a running one).
    static func start(dataFolder: URL?, arguments: [String] = [], environment: [String: String] = [:],
                      activationToken: String? = nil, newInstance: Bool = false) throws {
        guard let exe = executable else { throw ClaudeError.notInstalled }
        var argv = newInstance ? appScope() : []
        argv.append(exe)
        if let dataFolder { argv.append("--user-data-dir=\(dataFolder.path)") }
        argv += arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        if let activationToken {
            env["XDG_ACTIVATION_TOKEN"] = activationToken
            env["DESKTOP_STARTUP_ID"] = activationToken
        } else {
            env["XDG_ACTIVATION_TOKEN"] = nil
            env["DESKTOP_STARTUP_ID"] = nil
        }
        try spawnDetached(argv, environment: env)
    }

    /// Starts a new Claude the way the desktop does: in its own systemd scope
    /// named after its app ID (app-<launcher>-<app id>-<random>.scope, the
    /// convention desktops and xdg-desktop-portal use). That is how the portal
    /// knows the process is Claude: GNOME then remembers the answer to Claude's
    /// own shortcut request (its Ctrl+Alt+Space Quick Entry) instead of asking
    /// again each time Clatch starts it. Without a systemd user session Claude
    /// starts as a plain child process.
    private static func appScope() -> [String] {
        let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? "/run/user/\(getuid())"
        guard FileManager.default.fileExists(atPath: "\(runtime)/systemd/private"),
              let systemdRun = (["/usr/bin/systemd-run", "/bin/systemd-run"] as [String]).first(where: { access($0, X_OK) == 0 })
        else { return [] }
        let appID = desktopEntry.replacingOccurrences(of: ".desktop", with: "")
        let random = String(UInt64.random(in: 1...UInt64.max), radix: 16)
        return [systemdRun, "--user", "--scope", "--quiet", "--collect",
                "--unit=app-clatch-\(appID)-\(random).scope", "--"]
    }

    /// g_spawn_async without DO_NOT_REAP: GLib double-forks, so no zombie is left;
    /// stdin is /dev/null and the child gets its own session (setsid).
    static func spawnDetached(_ argv: [String], environment: [String: String]) throws {
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cArgv.forEach { free($0) }; cEnv.forEach { free($0) } }
        var error: UnsafeMutablePointer<GError>?
        let setup: GSpawnChildSetupFunc = { _ in _ = setsid() }
        let flags = GSpawnFlags(rawValue: G_SPAWN_STDOUT_TO_DEV_NULL.rawValue | G_SPAWN_STDERR_TO_DEV_NULL.rawValue)
        let ok = g_spawn_async(nil, &cArgv, &cEnv, flags, setup, nil, nil, &error)
        if ok == 0 {
            let message = error.flatMap { String(gstring: $0.pointee.message) } ?? "unknown error"
            g_clear_error(&error)
            throw ClaudeError.couldNotStart(message)
        }
    }

    enum ClaudeError: LocalizedError {
        case notInstalled
        case couldNotStart(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: "Claude Desktop is not installed."
            case .couldNotStart(let reason): "Claude could not be started: \(reason)"
            }
        }
    }

    // MARK: - Closing Claude politely

    /// Electron quits gracefully on SIGTERM, SIGHUP and SIGINT: each runs Claude's
    /// normal quit (which may ask the user first, and may be declined). Each works
    /// once only: Electron restores the default action afterwards, so a second
    /// SIGTERM would kill Claude. Asking again therefore uses the next signal.
    static let politeSignals: [Int32] = [SIGTERM, SIGHUP, SIGINT]
}

/// Remembers which polite signals each process has had already.
@MainActor
final class QuitRequester {
    private var used: [pid_t: Int] = [:]

    /// Asks a Claude main process to quit. Returns false when every polite way
    /// has been used (the user has to quit from Claude's own menu).
    @discardableResult
    func ask(_ pid: pid_t) -> Bool {
        let index = used[pid] ?? 0
        guard index < Claude.politeSignals.count else { return false }
        used[pid] = index + 1
        let signal = Claude.politeSignals[index]
        let result = kill(pid, signal)
        Log.write("Asked Claude (\(pid)) to quit with signal \(signal): \(result == 0 ? "sent" : "failed")")
        return result == 0
    }

    func canAskAgain(_ pid: pid_t) -> Bool { (used[pid] ?? 0) < Claude.politeSignals.count }

    func forget(_ pid: pid_t) { used[pid] = nil }
}

/// Calls back once when a process exits: a pidfd (Linux 5.3+) in GLib's loop,
/// no polling. Older kernels fall back to a slow check.
@MainActor
final class ExitWatch {
    private var watch: FDWatch?
    private var timer: GTimer?

    init(pid: pid_t, _ exited: @escaping @MainActor () -> Void) {
        let fd = clatch_pidfd_open(pid)
        if fd >= 0 {
            watch = FDWatch(fd: fd, exited)
        } else {
            timer = GTimer(0.5, repeats: true) { [weak self] in
                if !ProcessScanner.isAlive(pid) {
                    self?.timer?.cancel()
                    exited()
                }
            }
        }
    }

    func cancel() {
        watch?.cancel()
        timer?.cancel()
    }
}
