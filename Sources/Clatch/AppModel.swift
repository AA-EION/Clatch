// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import AppKit
import ClatchCore

/// What Clatch is doing right now (one-at-a-time switches and mode changes).
enum SwitchPhase: Equatable {
    case idle
    /// Claude was asked to quit and has not quit yet (it may be asking the
    /// user to confirm, or the user said no).
    case waitingForClaude(since: Date)
    /// Claude's main process is gone; helpers or sessions are still exiting.
    case waitingForHelpers(since: Date)
    /// Claude's data folder does not look the way Clatch expects (Claude may
    /// have changed how it stores data). Nothing has moved; the user decides.
    case confirmLayout(problems: [String])
    /// Moving folders (instant) and reopening Claude.
    case switching
    /// Turning side by side off: waiting for the other profiles' Claudes to close.
    case closingProfiles(remaining: Int)

    var isBusy: Bool { self != .idle }
}

/// The pages of the menu bar panel.
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

/// A switch the user asked for, waiting for Claude to quit.
enum PendingOperation: Equatable {
    case switchTo(UUID)
    case addAccount(name: String, renameCurrentTo: String?)
}

/// The app's single source of truth. Idle, it holds no timers: switches,
/// the switcher and the watchdog only run while there is something to do,
/// and Claude instances are tracked from the system's launch/quit notifications.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: AccountsState
    @Published private(set) var phase: SwitchPhase = .idle {
        didSet { onPhaseChange?(phase) }
    }
    @Published private(set) var pending: PendingOperation?
    @Published var page: Page = .accounts
    @Published var errorMessage: String?
    /// A short, non-error message ("Chat copied", "Backup restored").
    @Published var notice: String?
    @Published private(set) var hotKey: KeyCombo?
    @Published private(set) var hotKeyRegistration: HotKeyCenter.Registration = .off
    @Published private(set) var claudeInstalled = true
    /// Profiles whose Claude is running right now.
    @Published private(set) var running: Set<UUID> = []
    @Published private(set) var availableUpdate: UpdateChecker.Update?

    /// Lets the status item show progress without observing the model.
    var onPhaseChange: ((SwitchPhase) -> Void)?
    /// Opens the panel (used when the shortcut has nothing to switch to, or a decision is needed).
    var requestPanel: (() -> Void)?

    let preferences = Preferences()
    private let store: AccountStore
    private var pollTimer: Timer?
    private var claudeWasRunning = false
    private lazy var runtime = ProfileRuntime { [weak self] folder in self?.profile(forDataFolder: folder) }
    private let overlay = SwitcherOverlay()
    private let router = LinkRouter()
    private let updates = UpdateChecker()
    private var activationObserver: NSObjectProtocol?
    /// Links waiting for a profile's Claude to start, then delivered to it.
    private var pendingLinks: [UUID: String] = [:]
    /// Watchdog: Claude's version when each unexpected exit happened.
    private var watchedExits: [UUID: (version: String?, since: Date)] = [:]
    private var watchdogTimer: Timer?

    init(store: AccountStore = AccountStore()) {
        self.store = store
        self.state = store.state
        store.sharedItems = preferences.shareToolSettings ? AccountStore.defaultSharedItems : []
        hotKey = preferences.hotKey
    }

    var sideBySide: Bool { preferences.sideBySide }

    // MARK: - Lifecycle

    func start() {
        HotKeyCenter.shared.onPress = { [weak self] in self?.hotKeyPressed() }
        hotKeyRegistration = HotKeyCenter.shared.register(hotKey)
        overlay.onChoose = { [weak self] id in self?.open(id) }

        runtime.onChange = { [weak self] in self?.instancesChanged() }
        runtime.onUnexpectedExit = { [weak self] id, _ in self?.watch(unexpectedExitOf: id) }
        runtime.start()

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == ClaudeApp.bundleIdentifier else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.claudeActivated(pid) }
        }

        finishInterruptedSwitchIfPossible()
        syncShortcuts()
        // Routing hygiene: claude:// must reach Claude whenever routing is off.
        if !(preferences.routeSignIns && sideBySide) && LinkRouter.clatchIsHandler { LinkRouter.setHandler(clatch: false) }
        checkForUpdates()
        Log.write("Clatch \(version) started; \(sideBySide ? "side by side" : "one at a time"); \(state.accounts.count) profile(s)")
    }

    /// Cheap checks done each time the panel opens.
    func panelWillOpen() {
        claudeInstalled = ClaudeApp.isInstalled
        notice = nil
        if !phase.isBusy {
            store.load()
            state = store.state
            finishInterruptedSwitchIfPossible()
            runtime.rescan()
        }
        checkForUpdates()
    }

    func panelDidClose() {
        if !phase.isBusy { page = .accounts }
    }

    private func finishInterruptedSwitchIfPossible() {
        guard store.hasInterruptedSwitch, !ClaudeApp.isRunning else { return }
        do {
            try store.recoverInterruptedSwitch()
        } catch {
            errorMessage = error.localizedDescription
        }
        state = store.state
    }

    // MARK: - Profiles and their Claudes

    /// Which profile a running Claude belongs to, from its data folder (nil: Claude's own folder).
    private func profile(forDataFolder folder: URL?) -> UUID? {
        guard let folder else { return state.activeID }
        let wanted = folder.resolvingSymlinksInPath().standardizedFileURL.path
        for account in state.accounts {
            let path = store.dataFolder(for: account.id).resolvingSymlinksInPath().standardizedFileURL.path
            if path == wanted { return account.id }
        }
        return nil
    }

    private func instancesChanged() {
        running = Set(runtime.instances.keys)
        // Deliver links that were waiting for a profile's Claude to start.
        for (id, link) in pendingLinks {
            guard let pid = runtime.instances[id]?.pid else { continue }
            pendingLinks[id] = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Task.detached {
                    if let problem = LinkRouter.deliver(link, toProcess: pid) {
                        await MainActor.run { [weak self] in self?.errorMessage = problem }
                    }
                }
            }
        }
    }

    private func claudeActivated(_ pid: pid_t) {
        if let id = runtime.instances.first(where: { $0.value.pid == pid })?.key {
            router.lastActiveProfile = id
        }
    }

    func isRunning(_ id: UUID) -> Bool { running.contains(id) }

    /// The main action for a profile: the menu, the switcher, a launcher app.
    /// One at a time: switch Claude to it. Side by side: bring its Claude to the front, or start it.
    func open(_ id: UUID) {
        guard let account = state.accounts.first(where: { $0.id == id }) else { return }
        if sideBySide {
            launch(account)
        } else if id == state.activeID {
            openActiveClaude()
        } else {
            begin(.switchTo(id))
        }
    }

    private func launch(_ account: Account, activates: Bool = true) {
        let folder: URL? = account.id == state.activeID ? nil : store.dataFolder(for: account.id)
        if !hasSignIn(account.id), preferences.routeSignIns { router.expectSignIn(for: account.id) }
        runtime.launchOrFocus(account, dataFolder: folder, activates: activates) { [weak self] error in
            if let error { self?.errorMessage = error.localizedDescription }
        }
        store.markUsed(account.id)
        state = store.state
    }

    /// Opens Claude on the active profile (with its environment and flags).
    func openActiveClaude() {
        guard let active = state.active else { return ClaudeApp.open() }
        runtime.launchOrFocus(active, dataFolder: nil) { [weak self] error in
            if let error { self?.errorMessage = error.localizedDescription }
        }
    }

    private func hasSignIn(_ id: UUID) -> Bool {
        let folder = store.dataFolder(for: id)
        return ["Cookies", "Network/Cookies"].contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    func close(_ id: UUID) {
        guard isRunning(id) else { return }
        runtime.close(id)
    }

    func restart(_ id: UUID) {
        guard let account = state.accounts.first(where: { $0.id == id }) else { return }
        guard isRunning(id) else { return open(id) }
        runtime.close(id) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    if self.sideBySide || id == self.state.activeID { self.launch(account) }
                }
            }
        }
    }

    // MARK: - Account editing

    func update(_ account: Account) {
        perform { try store.update(account) }
        syncShortcuts()
        page = .accounts
    }

    func move(_ id: UUID, by offset: Int) {
        perform { try store.move(id, by: offset) }
    }

    func remove(_ id: UUID) {
        if isRunning(id) {
            errorMessage = "Close this profile's Claude first."
            page = .accounts
            return
        }
        perform { try store.remove(id) }
        syncShortcuts()
        page = .accounts
    }

    func suggestedNewName() -> String { store.suggestedNewName() }

    func hasStoredData(_ id: UUID) -> Bool { store.hasStoredData(id) }

    func account(_ id: UUID) -> Account? { state.accounts.first { $0.id == id } }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        state = store.state
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
        } else {
            begin(.addAccount(name: name, renameCurrentTo: renameCurrentTo))
        }
    }

    // MARK: - The switcher and the shortcut

    private func hotKeyPressed() {
        guard !phase.isBusy, let hotKey else { return }
        store.load()
        state = store.state
        guard state.accounts.count > 1 else {
            // Nothing to switch to yet: show the panel with "Add Account".
            requestPanel?()
            return
        }
        let current: UUID?
        if sideBySide, let front = NSWorkspace.shared.frontmostApplication,
           let id = runtime.instances.first(where: { $0.value.pid == front.processIdentifier })?.key {
            current = id
        } else {
            current = sideBySide ? (router.lastActiveProfile ?? state.activeID) : state.activeID
        }
        overlay.present(accounts: state.accounts, current: current, running: running, sideBySide: sideBySide, combo: hotKey)
    }

    // MARK: - Links (clatch:// from launchers, claude:// when routing)

    func handle(url: URL) {
        switch url.scheme?.lowercased() {
        case "clatch":
            // clatch://launch/<profile id>
            let parts = [url.host ?? ""] + url.pathComponents.filter { $0 != "/" }
            if parts.first == "launch", parts.count > 1, let id = UUID(uuidString: parts[1]) {
                Log.write("Launcher opened a profile")
                open(id)
            }
        case "claude":
            route(url)
        default:
            break
        }
    }

    private func route(_ url: URL) {
        let link = url.absoluteString
        guard ClaudeLink.isSignIn(link) || link.lowercased().hasPrefix("claude://") else { return }
        guard sideBySide && preferences.routeSignIns,
              let id = router.target(for: link, active: state.activeID),
              let account = account(id) else {
            Log.write("Passing \(ClaudeLink.describe(link)) to Claude")
            LinkRouter.forwardToClaude(url)
            return
        }
        Log.write("Routing \(ClaudeLink.describe(link)) to a profile")
        if ClaudeLink.isSignIn(link) { router.clearPending() }
        if let pid = runtime.instances[id]?.pid {
            Task.detached {
                if let problem = LinkRouter.deliver(link, toProcess: pid) {
                    await MainActor.run { [weak self] in self?.errorMessage = problem }
                }
            }
        } else {
            pendingLinks[id] = link
            launch(account)
        }
    }

    func setRouting(_ on: Bool) {
        objectWillChange.send()
        preferences.routeSignIns = on && sideBySide
        LinkRouter.setHandler(clatch: on && sideBySide)
        if on, let pid = runtime.instances.values.first?.pid {
            // Ask for the Automation permission now rather than in the middle of a sign-in.
            Task.detached {
                let allowed = LinkRouter.requestPermission(pid: pid)
                if !allowed {
                    await MainActor.run { [weak self] in
                        self?.errorMessage = "Allow Clatch to control Claude in System Settings › Privacy & Security › Automation, or sign-ins cannot be routed."
                    }
                }
            }
        }
    }

    // MARK: - One at a time: switching

    private func begin(_ operation: PendingOperation) {
        guard !phase.isBusy else { return }
        // An interrupted earlier switch is finished in commit(), once Claude is closed.
        errorMessage = nil
        pending = operation
        claudeWasRunning = ClaudeApp.isRunning
        if claudeWasRunning {
            phase = .waitingForClaude(since: Date())
            ClaudeApp.requestQuit()
            startPolling()
        } else {
            // Claude's helpers could still be on their way out from a recent quit.
            phase = .waitingForHelpers(since: Date())
            startPolling()
        }
    }

    /// Asks Claude to quit again, after the user said "Cancel" in its dialog.
    func askClaudeToQuitAgain() {
        if case .closingProfiles = phase {
            runtime.instances.keys.filter { $0 != state.activeID }.forEach { runtime.close($0) }
            return
        }
        guard case .waitingForClaude = phase else { return }
        phase = .waitingForClaude(since: Date())
        ClaudeApp.requestQuit()
    }

    /// Gives up waiting. Nothing has been moved yet, so nothing needs undoing.
    func cancelSwitch() {
        stopPolling()
        if case .closingProfiles = phase {
            runtime.cancelClosing()
            phase = .idle
            return
        }
        // Claude was closed for this switch: give it back to the user.
        let claudeWasClosedForUs: Bool
        switch phase {
        case .waitingForHelpers, .confirmLayout: claudeWasClosedForUs = claudeWasRunning
        default: claudeWasClosedForUs = false
        }
        pending = nil
        phase = .idle
        if claudeWasClosedForUs && !ClaudeApp.isRunning { openActiveClaude() }
    }

    /// Switch even though helper processes are still around. Safe: a rename
    /// never breaks open files, and a straggler that still writes does so
    /// into the outgoing account's (renamed) folder, which is where it belongs.
    func switchAnyway() {
        guard case .waitingForHelpers = phase else { return }
        commit()
    }

    /// The user read the warning about Claude's data folder and continues.
    func continueDespiteLayout() {
        guard case .confirmLayout = phase else { return }
        commit(layoutConfirmed: true)
    }

    /// Other places a future Claude Desktop might keep its data; mentioned in
    /// the warning when one of them exists.
    private var alternativeDataFolders: [URL] {
        let support = store.paths.claudeData.deletingLastPathComponent()
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return ["Claude-3p", "Claude Desktop", "Anthropic", "Anthropic Claude", ClaudeApp.bundleIdentifier]
            .map { support.appendingPathComponent($0) }
            + [home.appendingPathComponent("Library/Containers/\(ClaudeApp.bundleIdentifier)")]
    }

    private func startPolling() {
        stopPolling()
        // Only exists during a switch; 4 checks a second is plenty and cheap.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        poll()
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        switch phase {
        case .waitingForClaude:
            if !ClaudeApp.isRunning { phase = .waitingForHelpers(since: Date()) }
        case .waitingForHelpers(let since):
            let leftovers = ClaudeApp.leftoverProcesses(dataFolder: store.paths.claudeData)
            // A short grace period after the main process exits lets Electron
            // flush cookies and storage to disk.
            if leftovers.isEmpty && Date().timeIntervalSince(since) > 0.3 {
                commit()
            }
        case .idle, .switching, .confirmLayout, .closingProfiles:
            stopPolling()
        }
    }

    private func commit(layoutConfirmed: Bool = false) {
        stopPolling()
        guard let operation = pending else {
            phase = .idle
            return
        }
        if !layoutConfirmed {
            let check = DataLayoutCheck.inspect(claudeData: store.paths.claudeData,
                                                claudeHasRunSinceLastSwitch: claudeWasRunning,
                                                alternatives: alternativeDataFolders)
            if !check.isRecognized {
                phase = .confirmLayout(problems: check.problems)
                requestPanel?()
                return
            }
        }
        phase = .switching
        store.sharedItems = preferences.shareToolSettings ? AccountStore.defaultSharedItems : []
        var openClaude = claudeWasRunning && preferences.reopenClaude
        do {
            try store.recoverInterruptedSwitch()
            switch operation {
            case .switchTo(let id):
                try store.switchTo(id)
            case .addAccount(let name, let renameCurrentTo):
                if let renameCurrentTo, let current = store.state.activeID {
                    try store.rename(current, to: renameCurrentTo)
                }
                try store.addAccount(named: name)
                // The whole point: Claude opens fresh and asks for a sign-in.
                openClaude = true
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        state = store.state
        pending = nil
        runtime.rescan()
        syncShortcuts()
        if openClaude { openActiveClaude() }
        phase = .idle
    }

    // MARK: - Modes

    /// Turning side by side on goes through a confirmation page first.
    func requestSideBySide(_ on: Bool) {
        if on {
            page = .confirmSideBySide
        } else {
            turnSideBySideOff()
        }
    }

    /// Confirmed on the confirmation page.
    func confirmSideBySide() {
        backUpSignIns(reason: "Turning side by side on")
        preferences.sideBySide = true
        objectWillChange.send()
        runtime.rescan()
        page = .settings
        Log.write("Side by side turned on")
    }

    /// Closes every other profile's Claude (politely), backs up their sign-ins,
    /// then goes back to one at a time. Nothing has to be signed in again: each
    /// profile keeps the same folder in both modes.
    private func turnSideBySideOff() {
        let others = runtime.instances.keys.filter { $0 != state.activeID }
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            self.backUpSignIns(reason: "Turning side by side off")
            self.preferences.sideBySide = false
            if self.preferences.routeSignIns { self.setRouting(false) }
            self.objectWillChange.send()
            self.phase = .idle
            Log.write("Side by side turned off")
        }
        guard !others.isEmpty else { return finish() }
        phase = .closingProfiles(remaining: others.count)
        page = .accounts
        runtime.closeAll(except: state.activeID.map { [$0] } ?? []) {
            finish()
        }
    }

    // MARK: - Sign-in backups

    var backupsFolder: URL { store.paths.clatchRoot.appendingPathComponent("Backups", isDirectory: true) }

    func backUpSignIns(reason: String) {
        var folders: [UUID: URL] = [:]
        for account in state.accounts where !isRunning(account.id) {
            folders[account.id] = store.dataFolder(for: account.id)
        }
        do {
            if let snapshot = try SignInBackup.backUp(folders, into: backupsFolder, reason: reason) {
                Log.write("Backed up the sign-ins of \(snapshot.profiles.count) profile(s): \(reason)")
            }
        } catch {
            Log.write("Sign-in backup failed: \(error.localizedDescription)")
        }
    }

    func backups() -> [SignInBackup.Snapshot] { SignInBackup.list(in: backupsFolder) }

    /// Puts sign-ins back from a backup, for profiles whose Claude is closed.
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
    }

    // MARK: - Code-tab chats

    func codeSessions(of id: UUID) -> [CodeSession] {
        CodeSessions.discover(inProfile: store.dataFolder(for: id))
    }

    func copy(_ session: CodeSession, to id: UUID) {
        guard let target = account(id) else { return }
        do {
            try CodeSessions.copy(session, toProfile: store.dataFolder(for: id), profileName: target.name)
            notice = "Copied “\(session.title)” to \(target.name)." + (isRunning(id) ? " Restart its Claude to see it." : "")
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Watchdog

    /// A profile's Claude ended without Clatch asking. If Claude was updated
    /// meanwhile, that update closed it: reopen it once the new version is in place.
    private func watch(unexpectedExitOf id: UUID) {
        guard sideBySide, preferences.watchdog else { return }
        watchedExits[id] = (ClaudeApp.version, Date())
        guard watchdogTimer == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkWatchedExits() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func checkWatchedExits() {
        let now = Date()
        let current = ClaudeApp.version
        for (id, exit) in watchedExits {
            if isRunning(id) || now.timeIntervalSince(exit.since) > 180 {
                watchedExits[id] = nil // reopened by someone else, or simply quit by the user
                continue
            }
            guard let current, current != exit.version, ClaudeApp.isInstalled,
                  now.timeIntervalSince(exit.since) > 6, let account = account(id) else { continue }
            Log.write("Claude was updated to \(current); reopening a profile it closed")
            watchedExits[id] = nil
            launch(account, activates: false)
        }
        if watchedExits.isEmpty {
            watchdogTimer?.invalidate()
            watchdogTimer = nil
        }
    }

    // MARK: - Shortcuts, updates, settings

    func syncShortcuts() {
        ProfileShortcuts.sync(accounts: state.accounts, enabled: preferences.profileShortcuts)
    }

    func checkForUpdates(force: Bool = false) {
        guard preferences.checkForUpdates || force else { return }
        updates.checkIfDue(currentVersion: shortVersion, force: force) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let update):
                self.availableUpdate = update
                if force && update == nil { self.notice = "Clatch is up to date." }
            case .failure(let error):
                if force { self.errorMessage = "Could not check for updates: \(error.localizedDescription)" }
            }
        }
    }

    func setHotKey(_ combo: KeyCombo?) {
        preferences.hotKey = combo
        hotKey = combo
        hotKeyRegistration = HotKeyCenter.shared.register(combo)
    }

    func suspendHotKey() { HotKeyCenter.shared.unregister() }

    func resumeHotKey() { hotKeyRegistration = HotKeyCenter.shared.register(hotKey) }

    var reopenClaude: Bool {
        get { preferences.reopenClaude }
        set { objectWillChange.send(); preferences.reopenClaude = newValue }
    }

    var shareToolSettings: Bool {
        get { preferences.shareToolSettings }
        set { objectWillChange.send(); preferences.shareToolSettings = newValue }
    }

    var profileShortcuts: Bool {
        get { preferences.profileShortcuts }
        set { objectWillChange.send(); preferences.profileShortcuts = newValue; syncShortcuts() }
    }

    var watchdogEnabled: Bool {
        get { preferences.watchdog }
        set { objectWillChange.send(); preferences.watchdog = newValue }
    }

    var updateChecks: Bool {
        get { preferences.checkForUpdates }
        set { objectWillChange.send(); preferences.checkForUpdates = newValue }
    }

    var openAtLogin: Bool {
        get { LoginItem.isEnabled }
        set {
            objectWillChange.send()
            do { try LoginItem.setEnabled(newValue) } catch { errorMessage = error.localizedDescription }
        }
    }

    func revealAccountsFolder() {
        let folder = store.paths.clatchRoot
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    func revealShortcutsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([ProfileShortcuts.folder])
    }

    func openLog() { NSWorkspace.shared.open(Log.fileURL) }

    func openClaude() { openActiveClaude() }

    // MARK: - Links

    static let donateURL = URL(string: "https://www.paypal.com/donate/?business=juanesgtgt2%40gmail.com&no_recurring=0&item_name=Issen+Software+Group")!
    static let projectURL = URL(string: "https://github.com/AA-EION/Clatch")!
    static let termsURL = URL(string: "https://www.anthropic.com/legal/consumer-terms")!

    func donate() { NSWorkspace.shared.open(Self.donateURL) }
    func openProjectPage() { NSWorkspace.shared.open(Self.projectURL) }
    func openTerms() { NSWorkspace.shared.open(Self.termsURL) }
    func openUpdatePage() { if let page = availableUpdate?.page { NSWorkspace.shared.open(page) } }

    var shortVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }

    var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty || build == short ? short : "\(short) (\(build))"
    }
}
