// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import CGtk
import ClatchCore
import Foundation
import Glibc

/// What Clatch is doing (one-at-a-time switches and mode changes).
enum SwitchPhase: Equatable {
    case idle
    /// Claude was asked to quit and has not yet (it may be asking the user, who may say no).
    case waitingForClaude(since: Date)
    /// Claude's main process is gone; its helpers or sessions are still exiting.
    case waitingForHelpers(since: Date)
    /// Claude's data folder does not look the way Clatch expects. Nothing has moved; the user decides.
    case confirmLayout(problems: [String])
    case switching
    /// Turning side by side off: waiting for the other profiles' Claudes to close.
    case closingProfiles

    var isBusy: Bool { self != .idle }
}

enum Page: Equatable {
    case accounts
    case addAccount
    case editProfile(UUID)
    case confirmRemove(UUID)
    case settings
    case confirmSideBySide
    case moveChats
    case restoreBackups
}

enum PendingOperation: Equatable {
    case switchTo(UUID)
    case addAccount(name: String, renameCurrentTo: String?)
}

/// The app's single source of truth, on the main thread. Idle, it holds no
/// timers: switches, closing and the watchdog only run while there is
/// something to do, and Claudes are followed through inotify and pidfds.
@MainActor
final class AppModel {
    private(set) var state: AccountsState
    private(set) var phase: SwitchPhase = .idle
    private(set) var pending: PendingOperation?
    var page: Page = .accounts
    var errorMessage: String?
    var notice: String?
    private(set) var availableUpdate: UpdateChecker.Update?
    private(set) var settings = Settings.load()
    private(set) var claudeUpdatedWhileOpen = false

    let store: AccountStore
    let runtime = ProfileRuntime()
    let router = LinkRouter()
    let shortcut = GlobalShortcut()
    let switcher = Switcher()
    private let updates = UpdateChecker()
    private var pollTimer: GTimer?
    private var claudeWasRunning = false
    private var pendingLinks: [UUID: String] = [:]
    private var watchedExits: [UUID: (version: String?, since: Date)] = [:]
    private var watchdogTimer: GTimer?
    private var installWatch: FolderWatch?
    private var versionAtStart: String?
    private var observers: [() -> Void] = []
    /// The last activation token the desktop gave Clatch (lets the Claude window come forward on Wayland).
    var activationToken: String?
    var app: GPtr!

    /// Opens Clatch's window (when a decision is needed, or nothing can be switched to yet).
    var requestPanel: (() -> Void)?

    init(store: AccountStore = AccountStore()) {
        self.store = store
        self.state = store.state
        store.sharedItems = settings.shareToolSettings ? AccountStore.defaultSharedItems : []
    }

    var sideBySide: Bool { settings.sideBySide }
    var isBusy: Bool { phase.isBusy }

    func observe(_ observer: @escaping () -> Void) { observers.append(observer) }
    func notify() { observers.forEach { $0() } }

    private func change(_ edit: (inout Settings) -> Void) {
        edit(&settings)
        settings.save()
        notify()
    }

    // MARK: - Lifecycle

    func start() {
        runtime.folders = { [weak self] in self?.profileFolders() ?? [:] }
        runtime.onChange = { [weak self] in self?.instancesChanged() }
        runtime.onUnexpectedExit = { [weak self] id in self?.watch(unexpectedExitOf: id) }
        runtime.start()
        switcher.onChoose = { [weak self] id in self?.open(id) }

        shortcut.onPress = { [weak self] token in self?.hotKeyPressed(token: token, fromPortal: true) }
        shortcut.onRelease = { [weak self] in self?.switcher.shortcutReleased() }
        shortcut.onStatusChange = { [weak self] in self?.notify() }
        shortcut.set(settings.hotKey)

        router.onDisplacedHandler = { [weak self] handler in
            guard handler != Desktop.desktopEntry else { return }
            self?.change { $0.claudeLinkHandlerBackup = handler }
        }
        finishInterruptedSwitchIfPossible()
        syncShortcuts()
        // Routing hygiene: claude:// must reach Claude whenever routing is off.
        if settings.routeSignIns && sideBySide { router.enable() }
        else if LinkRouter.clatchIsHandler { router.disable(restoring: settings.claudeLinkHandlerBackup) }
        watchInstall()
        checkForUpdates()
        Log.write("Clatch \(Self.version) started; \(sideBySide ? "side by side" : "one at a time"); \(state.accounts.count) profile(s); Claude \(Claude.isInstalled ? Claude.version ?? "installed" : "not found")")
    }

    /// Cheap checks each time the window opens.
    func windowWillOpen() {
        notice = nil
        if !phase.isBusy {
            store.load()
            state = store.state
            finishInterruptedSwitchIfPossible()
            runtime.rescan()
        }
        checkForUpdates()
    }

    func windowDidClose() {
        if !phase.isBusy { page = .accounts }
    }

    private func finishInterruptedSwitchIfPossible() {
        guard store.hasInterruptedSwitch, Claude.runningMain(on: Claude.dataFolder) == nil else { return }
        perform { try store.recoverInterruptedSwitch() }
    }

    /// Every profile's data folder: Claude's own for the active one, its stash for the others.
    func profileFolders() -> [UUID: URL] {
        var folders: [UUID: URL] = [:]
        for account in state.accounts { folders[account.id] = store.dataFolder(for: account.id) }
        return folders
    }

    // MARK: - Profiles and their Claudes

    private func instancesChanged() {
        for (id, link) in pendingLinks where runtime.isRunning(id) {
            pendingLinks[id] = nil
            let folder = id == state.activeID ? nil : store.dataFolder(for: id)
            // Give the new Claude a moment to set up its link handling.
            after(2) { [weak self] in
                do { try self?.runtime.deliver(link, dataFolder: folder) } catch { self?.errorMessage = error.localizedDescription }
            }
        }
        // Every Claude closed after an update: they will all start on the new version.
        if runtime.instances.isEmpty && claudeUpdatedWhileOpen {
            claudeUpdatedWhileOpen = false
            versionAtStart = Claude.version
        }
        notify()
    }

    func isRunning(_ id: UUID) -> Bool { runtime.isRunning(id) }
    func account(_ id: UUID) -> Account? { state.accounts.first { $0.id == id } }
    var claudeRunning: Bool { state.activeID.map(isRunning) ?? false || Claude.runningMain(on: Claude.dataFolder) != nil }

    /// The main action for a profile (the list, the switcher, a launcher).
    /// One at a time: switch Claude to it. Side by side: bring its Claude forward, or start it.
    func open(_ id: UUID) {
        guard let account = account(id) else { return }
        if sideBySide || id == state.activeID {
            launch(account)
        } else {
            begin(.switchTo(id))
        }
    }

    private func launch(_ account: Account) {
        let folder: URL? = account.id == state.activeID ? nil : store.dataFolder(for: account.id)
        if !hasSignIn(account.id), settings.routeSignIns { router.expectSignIn(for: account.id) }
        do {
            try runtime.launchOrFocus(account, dataFolder: folder, activationToken: takeToken())
        } catch {
            errorMessage = error.localizedDescription
        }
        store.markUsed(account.id)
        state = store.state
        notify()
    }

    /// An activation token works once.
    private func takeToken() -> String? {
        defer { activationToken = nil }
        return activationToken
    }

    func openActiveClaude() {
        if let active = state.active { launch(active) }
        else { try? Claude.start(dataFolder: nil, activationToken: takeToken()) }
    }

    private func hasSignIn(_ id: UUID) -> Bool {
        let folder = store.dataFolder(for: id)
        return ["Cookies", "Network/Cookies"].contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    func close(_ id: UUID) { runtime.close(id) { [weak self] in self?.notify() }; notify() }

    func restart(_ id: UUID) {
        guard let account = account(id) else { return }
        guard isRunning(id) else { return open(id) }
        runtime.close(id) { [weak self] in
            after(0.5) { [weak self] in self?.launch(account) }
        }
        notify()
    }

    // MARK: - Editing

    func update(_ account: Account) {
        perform { try store.update(account) }
        syncShortcuts()
        page = .accounts
        notify()
    }

    func move(_ id: UUID, by offset: Int) { perform { try store.move(id, by: offset) } }

    func remove(_ id: UUID) {
        if isRunning(id) {
            errorMessage = "Close this profile's Claude first."
        } else if let account = account(id) {
            perform { try store.remove(id) }
            ProfileIcons.prune(account)
            syncShortcuts()
        }
        page = .accounts
        notify()
    }

    func suggestedNewName() -> String { store.suggestedNewName() }
    func hasStoredData(_ id: UUID) -> Bool { store.hasStoredData(id) }

    func show(_ page: Page) {
        self.page = page
        notify()
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        state = store.state
        notify()
    }

    // MARK: - Adding profiles

    func addAccount(name: String, renameCurrentTo: String?) {
        page = .accounts
        if sideBySide {
            perform {
                if let renameCurrentTo, let current = store.state.activeID { try store.rename(current, to: renameCurrentTo) }
                let account = try store.createProfile(named: name)
                state = store.state
                router.expectSignIn(for: account.id)
                launch(account)
            }
            syncShortcuts()
            runtime.rescan()
        } else {
            begin(.addAccount(name: name, renameCurrentTo: renameCurrentTo))
        }
    }

    // MARK: - The switcher

    /// The shortcut was pressed (the portal, or `clatch --switcher` from a GNOME shortcut).
    func hotKeyPressed(token: String?, fromPortal: Bool) {
        if switcher.isOpen { return switcher.step(1) }
        guard !phase.isBusy else { return }
        store.load()
        state = store.state
        guard state.accounts.count > 1 else {
            activationToken = token
            requestPanel?()
            return
        }
        let current = sideBySide ? (runtime.lastActive ?? state.activeID) : state.activeID
        let tiles = state.accounts.map {
            Switcher.Tile(account: $0, icon: ProfileIcons.png(for: $0), isCurrent: $0.id == state.activeID, isRunning: isRunning($0.id))
        }
        switcher.present(tiles: tiles, current: current, sideBySide: sideBySide, accelerator: settings.hotKey,
                         token: token, reportsRelease: fromPortal, app: app)
    }

    // MARK: - Links (claude:// when routing)

    func handle(link: String) {
        guard link.lowercased().hasPrefix("claude:") else { return }
        guard sideBySide && settings.routeSignIns,
              let id = router.target(for: link, lastActive: runtime.lastActive, active: state.activeID),
              let account = account(id) else {
            Log.write("Passing \(ClaudeLink.describe(link)) to Claude")
            do { try runtime.deliver(link, dataFolder: nil) } catch { errorMessage = error.localizedDescription; notify() }
            return
        }
        Log.write("Routing \(ClaudeLink.describe(link)) to a profile")
        if ClaudeLink.isSignIn(link) { router.clearPending() }
        let folder = id == state.activeID ? nil : store.dataFolder(for: id)
        if isRunning(id) {
            do { try runtime.deliver(link, dataFolder: folder) } catch { errorMessage = error.localizedDescription; notify() }
        } else {
            pendingLinks[id] = link
            launch(account)
        }
    }

    func setRouting(_ on: Bool) {
        change { $0.routeSignIns = on && sideBySide }
        if settings.routeSignIns {
            router.enable()
            if !LinkRouter.clatchIsHandler {
                errorMessage = "Clatch could not become the handler for claude:// links. Is Clatch installed from its package?"
            }
        } else {
            router.disable(restoring: settings.claudeLinkHandlerBackup)
        }
        notify()
    }

    // MARK: - One at a time: switching

    private func begin(_ operation: PendingOperation) {
        guard !phase.isBusy else { return }
        errorMessage = nil
        pending = operation
        runtime.rescan()
        claudeWasRunning = claudeRunning
        if claudeWasRunning, let active = state.activeID, isRunning(active) {
            phase = .waitingForClaude(since: Date())
            runtime.close(active)
        } else if claudeWasRunning, let pid = Claude.runningMain(on: Claude.dataFolder) {
            // A Claude on Claude's own folder that no profile owns yet (first run).
            phase = .waitingForClaude(since: Date())
            kill(pid, SIGTERM)
        } else {
            phase = .waitingForHelpers(since: Date())
        }
        Log.write("Switch requested; Claude running=\(claudeWasRunning)")
        startPolling()
        notify()
    }

    var quitDeclined: Bool {
        if case .waitingForClaude(let since) = phase { return runtime.closeLooksDeclined || Date().timeIntervalSince(since) > 4 }
        if case .closingProfiles = phase { return runtime.closeLooksDeclined }
        return false
    }

    var canAskAgain: Bool { runtime.canAskAgain }

    func askClaudeToQuitAgain() { runtime.askAgain() }

    /// Gives up waiting. Nothing has moved yet, so nothing needs undoing.
    func cancelSwitch() {
        stopPolling()
        if case .closingProfiles = phase {
            runtime.cancelClosing()
            phase = .idle
            return notify()
        }
        let closedForUs: Bool
        switch phase {
        case .waitingForHelpers, .confirmLayout: closedForUs = claudeWasRunning
        default: closedForUs = false
        }
        runtime.cancelClosing()
        pending = nil
        phase = .idle
        if closedForUs && !claudeRunning { openActiveClaude() }
        notify()
    }

    /// Switch while helper processes are still around. Safe on Linux: a rename
    /// never breaks open files, and a straggler that writes does so into the
    /// outgoing profile's (renamed) folder, where it belongs.
    func switchAnyway() {
        guard case .waitingForHelpers = phase else { return }
        commit()
    }

    var helpersTakingLong: Bool {
        if case .waitingForHelpers(let since) = phase { return Date().timeIntervalSince(since) > 6 }
        return false
    }

    func continueDespiteLayout() {
        guard case .confirmLayout = phase else { return }
        commit(layoutConfirmed: true)
    }

    private var alternativeDataFolders: [URL] {
        let config = ClatchPaths.configHome
        return ["Claude-3p", "Claude Desktop", "claude-desktop", "Anthropic", "Anthropic Claude"].map { config.appendingPathComponent($0) }
    }

    private func startPolling() {
        // Exists only during a switch.
        pollTimer = GTimer(0.25, repeats: true) { [weak self] in self?.poll() }
        poll()
    }

    private func stopPolling() { pollTimer = nil }

    private func poll() {
        switch phase {
        case .waitingForClaude:
            if Claude.runningMain(on: Claude.dataFolder) == nil {
                phase = .waitingForHelpers(since: Date())
            }
            notify()
        case .waitingForHelpers(let since):
            let leftovers = Claude.Snapshot.take(folders: Array(profileFolders().values)).processes(of: Claude.dataFolder)
            // A short grace period lets Chromium flush cookies and storage.
            if leftovers.isEmpty && Date().timeIntervalSince(since) > 0.3 { commit() }
            else if Int(Date().timeIntervalSince(since) * 4) % 4 == 0 { notify() }
        case .idle, .switching, .confirmLayout, .closingProfiles:
            stopPolling()
        }
    }

    private func commit(layoutConfirmed: Bool = false) {
        stopPolling()
        guard let operation = pending else {
            phase = .idle
            return notify()
        }
        if !layoutConfirmed {
            let check = DataLayoutCheck.inspect(claudeData: store.paths.claudeData,
                                                claudeHasRunSinceLastSwitch: claudeWasRunning,
                                                alternatives: alternativeDataFolders)
            if !check.isRecognized {
                phase = .confirmLayout(problems: check.problems)
                requestPanel?()
                return notify()
            }
        }
        phase = .switching
        notify()
        store.sharedItems = settings.shareToolSettings ? AccountStore.defaultSharedItems : []
        var openClaude = claudeWasRunning && settings.reopenClaude
        do {
            try store.recoverInterruptedSwitch()
            switch operation {
            case .switchTo(let id):
                try store.switchTo(id)
            case .addAccount(let name, let renameCurrentTo):
                if let renameCurrentTo, let current = store.state.activeID { try store.rename(current, to: renameCurrentTo) }
                try store.addAccount(named: name)
                openClaude = true
            }
            errorMessage = nil
            switch operation {
            case .switchTo: Log.write("Switched: to another profile")
            case .addAccount: Log.write("Switched: to a new profile")
            }
        } catch {
            errorMessage = error.localizedDescription
            Log.write("Switch failed: \(error.localizedDescription)")
        }
        state = store.state
        pending = nil
        runtime.rescan()
        syncShortcuts()
        phase = .idle
        if openClaude { openActiveClaude() }
        notify()
    }

    // MARK: - Modes

    func requestSideBySide(_ on: Bool) {
        if on { show(.confirmSideBySide) } else { turnSideBySideOff() }
    }

    func confirmSideBySide() {
        backUpSignIns(reason: "Turning side by side on")
        change { $0.sideBySide = true }
        runtime.rescan()
        page = .settings
        Log.write("Side by side turned on")
        notify()
    }

    /// Closes every other profile's Claude (politely), backs up their sign-ins,
    /// then goes back to one at a time. Every profile keeps its folder: nothing
    /// has to be signed in again.
    private func turnSideBySideOff() {
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            self.backUpSignIns(reason: "Turning side by side off")
            self.change { $0.sideBySide = false }
            if self.settings.routeSignIns { self.setRouting(false) }
            self.phase = .idle
            Log.write("Side by side turned off")
            self.notify()
        }
        let keep: Set<UUID> = state.activeID.map { [$0] } ?? []
        guard runtime.instances.keys.contains(where: { !keep.contains($0) }) else { return finish() }
        phase = .closingProfiles
        page = .accounts
        runtime.closeAll(except: keep, then: finish)
        notify()
    }

    // MARK: - Sign-in backups

    var backupsFolder: URL { store.paths.clatchRoot.appendingPathComponent("Backups", isDirectory: true) }

    func backUpSignIns(reason: String) {
        var folders: [UUID: URL] = [:]
        for account in state.accounts where !isRunning(account.id) { folders[account.id] = store.dataFolder(for: account.id) }
        do {
            if let snapshot = try SignInBackup.backUp(folders, into: backupsFolder, reason: reason) {
                Log.write("Backed up the sign-ins of \(snapshot.profiles.count) profile(s): \(reason)")
            }
        } catch {
            Log.write("Sign-in backup failed: \(error.localizedDescription)")
        }
    }

    func backups() -> [SignInBackup.Snapshot] { SignInBackup.list(in: backupsFolder) }

    func restore(_ snapshot: SignInBackup.Snapshot) {
        var restored = 0, skipped = 0
        for id in snapshot.profiles where account(id) != nil {
            if isRunning(id) { skipped += 1; continue }
            do {
                try SignInBackup.restore(id, from: snapshot, into: store.dataFolder(for: id))
                restored += 1
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        notice = "Restored \(restored) profile(s)." + (skipped > 0 ? " \(skipped) skipped because their Claude is open: close it and restore again." : "")
        page = .accounts
        notify()
    }

    // MARK: - Code-tab chats

    func codeSessions(of id: UUID) -> [CodeSession] { CodeSessions.discover(inProfile: store.dataFolder(for: id)) }

    func copy(_ session: CodeSession, to id: UUID) {
        guard let target = account(id) else { return }
        do {
            try CodeSessions.copy(session, toProfile: store.dataFolder(for: id), profileName: target.name)
            notice = "Copied “\(session.title)” to \(target.name)." + (isRunning(id) ? " Restart its Claude to see it." : "")
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        notify()
    }

    // MARK: - Watchdog

    /// A profile's Claude ended without Clatch asking. If Claude was updated
    /// meanwhile (apt replaced it), reopen it once the new version is in place.
    private func watch(unexpectedExitOf id: UUID) {
        guard sideBySide, settings.watchdog else { return }
        watchedExits[id] = (versionAtStart, Date())
        guard watchdogTimer == nil else { return }
        watchdogTimer = GTimer(3, repeats: true) { [weak self] in self?.checkWatchedExits() }
    }

    private func checkWatchedExits() {
        let now = Date()
        let current = Claude.version
        for (id, exit) in watchedExits {
            if isRunning(id) || now.timeIntervalSince(exit.since) > 180 {
                watchedExits[id] = nil
                continue
            }
            guard let current, current != exit.version, Claude.isInstalled,
                  now.timeIntervalSince(exit.since) > 6, let account = account(id) else { continue }
            Log.write("Claude was updated to \(current); reopening a profile it closed")
            watchedExits[id] = nil
            launch(account)
        }
        if watchedExits.isEmpty { watchdogTimer = nil }
    }

    /// apt replaces Claude's files while it runs: note it, so the user can restart open profiles.
    private func watchInstall() {
        versionAtStart = Claude.version
        guard let folder = Claude.installFolder else { return }
        installWatch = FolderWatch(URL(fileURLWithPath: folder).appendingPathComponent("resources")) { [weak self] name in
            guard let self, name == "app.asar" else { return }
            after(3) { [weak self] in
                guard let self else { return }
                let now = Claude.version
                if now != self.versionAtStart {
                    if !self.runtime.instances.isEmpty { self.claudeUpdatedWhileOpen = true }
                    Log.write("Claude was updated to \(now ?? "?")")
                    if self.runtime.instances.isEmpty { self.versionAtStart = now }
                    self.notify()
                }
            }
        }
    }

    /// Restarts every open profile on the new Claude.
    func restartOpenProfiles() {
        claudeUpdatedWhileOpen = false
        versionAtStart = Claude.version
        runtime.instances.keys.forEach(restart)
    }

    // MARK: - Settings

    func syncShortcuts() { ProfileShortcuts.sync(accounts: state.accounts, enabled: settings.profileShortcuts) }

    func setProfileShortcuts(_ on: Bool) { change { $0.profileShortcuts = on }; syncShortcuts() }
    func setReopenClaude(_ on: Bool) { change { $0.reopenClaude = on } }
    func setWatchdog(_ on: Bool) { change { $0.watchdog = on } }
    func setCheckForUpdates(_ on: Bool) { change { $0.checkForUpdates = on } }
    func setShareToolSettings(_ on: Bool) {
        change { $0.shareToolSettings = on }
        store.sharedItems = on ? AccountStore.defaultSharedItems : []
    }

    func setHotKey(_ accelerator: String?) {
        change { $0.hotKey = accelerator }
        shortcut.set(accelerator)
    }

    var startAtLogin: Bool { StartAtLogin.isEnabled }

    func setStartAtLogin(_ on: Bool) {
        do { try StartAtLogin.setEnabled(on) } catch { errorMessage = error.localizedDescription }
        notify()
    }

    func checkForUpdates(force: Bool = false) {
        guard settings.checkForUpdates || force else { return }
        if !force, let last = settings.lastUpdateCheck, Date().timeIntervalSince(last) < 24 * 3600 { return }
        updates.check(currentVersion: Self.version) { [weak self] result in
            guard let self else { return }
            self.change { $0.lastUpdateCheck = Date() }
            switch result {
            case .success(let update):
                self.availableUpdate = update
                if force && update == nil { self.notice = "Clatch is up to date." }
            case .failure(let error):
                if force { self.errorMessage = "Could not check for updates: \(error.localizedDescription)" }
            }
            self.notify()
        }
    }

    // MARK: - Links and folders

    static let donateURL = "https://www.paypal.com/donate/?business=juanesgtgt2%40gmail.com&no_recurring=0&item_name=Issen+Software+Group"
    static let projectURL = "https://github.com/AA-EION/Clatch"
    static let termsURL = "https://www.anthropic.com/legal/consumer-terms"

    func openURI(_ uri: String) {
        var error: UnsafeMutablePointer<GError>?
        if g_app_info_launch_default_for_uri(uri, nil, &error) == 0 {
            errorMessage = error.flatMap { String(gstring: $0.pointee.message) } ?? "Could not open \(uri)"
            notify()
        }
        g_clear_error(&error)
    }

    func openFolder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        openURI(url.absoluteString)
    }

    func revealAccountsFolder() { openFolder(store.paths.clatchRoot) }
    func openLog() { openURI(Log.fileURL.absoluteString) }

    /// The version baked in at build time (scripts/build-deb.sh), else "dev".
    static let version: String = {
        let file = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("../share/clatch/version").standardizedFileURL
        let text = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProcessInfo.processInfo.environment["CLATCH_VERSION"] ?? text ?? "0.0.0-dev"
    }()
}
