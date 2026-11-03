// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import AppKit
import ClatchCore

/// What Clatch is doing right now.
enum SwitchPhase: Equatable {
    case idle
    /// Claude was asked to quit and has not quit yet (it may be asking the
    /// user to confirm, or the user said no).
    case waitingForClaude(since: Date)
    /// Claude's main process is gone; helpers or sessions are still exiting.
    case waitingForHelpers(since: Date)
    /// Moving folders (instant) and reopening Claude.
    case switching

    var isBusy: Bool { self != .idle }
}

/// The pages of the menu bar panel.
enum Page: Equatable {
    case accounts
    case addAccount
    case rename(UUID)
    case confirmRemove(UUID)
    case settings
}

/// A switch the user asked for, waiting for Claude to quit.
enum PendingOperation: Equatable {
    case switchTo(UUID)
    case addAccount(name: String, renameCurrentTo: String?)
}

/// The app's single source of truth. Lives for the whole app run, but holds
/// no timers or observers while idle: the only work it does in the
/// background is during a switch.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: AccountsState
    @Published private(set) var phase: SwitchPhase = .idle {
        didSet { onPhaseChange?(phase) }
    }
    @Published private(set) var pending: PendingOperation?
    @Published var page: Page = .accounts
    @Published var errorMessage: String?
    @Published private(set) var hotKey: KeyCombo?
    @Published private(set) var hotKeyRegistration: HotKeyCenter.Registration = .off
    @Published private(set) var claudeInstalled = true

    /// Lets the status item show progress without observing the model.
    var onPhaseChange: ((SwitchPhase) -> Void)?
    /// Opens the panel (used when the shortcut has nothing to switch to).
    var requestPanel: (() -> Void)?

    let preferences = Preferences()
    private let store: AccountStore
    private var pollTimer: Timer?
    private var claudeWasRunning = false

    init(store: AccountStore = AccountStore()) {
        self.store = store
        self.state = store.state
        store.sharedItems = preferences.shareToolSettings ? AccountStore.defaultSharedItems : []
        hotKey = preferences.hotKey
    }

    // MARK: - Lifecycle

    func start() {
        HotKeyCenter.shared.onPress = { [weak self] in self?.hotKeyPressed() }
        hotKeyRegistration = HotKeyCenter.shared.register(hotKey)
        finishInterruptedSwitchIfPossible()
    }

    /// Cheap checks done each time the panel opens.
    func panelWillOpen() {
        claudeInstalled = ClaudeApp.isInstalled
        if !phase.isBusy {
            store.load()
            state = store.state
            finishInterruptedSwitchIfPossible()
        }
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

    // MARK: - Account editing

    func rename(_ id: UUID, to name: String) {
        perform { try store.rename(id, to: name) }
        page = .accounts
    }

    func move(_ id: UUID, by offset: Int) {
        perform { try store.move(id, by: offset) }
    }

    func remove(_ id: UUID) {
        perform { try store.remove(id) }
        page = .accounts
    }

    func suggestedNewName() -> String { store.suggestedNewName() }

    func hasStoredData(_ id: UUID) -> Bool { store.hasStoredData(id) }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        state = store.state
    }

    // MARK: - Switching

    func switchTo(_ id: UUID) {
        guard id != state.activeID else { return }
        begin(.switchTo(id))
    }

    func addAccount(name: String, renameCurrentTo: String?) {
        page = .accounts
        begin(.addAccount(name: name, renameCurrentTo: renameCurrentTo))
    }

    private func hotKeyPressed() {
        guard !phase.isBusy else { return }
        store.load()
        state = store.state
        if let next = state.next {
            switchTo(next.id)
        } else {
            // Nothing to switch to yet: show the panel with "Add Account".
            requestPanel?()
        }
    }

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
        guard case .waitingForClaude = phase else { return }
        phase = .waitingForClaude(since: Date())
        ClaudeApp.requestQuit()
    }

    /// Gives up waiting. Nothing has been moved yet, so nothing needs undoing.
    func cancelSwitch() {
        stopPolling()
        pending = nil
        phase = .idle
    }

    /// Switch even though helper processes are still around. Safe: a rename
    /// never breaks open files, and a straggler that still writes does so
    /// into the outgoing account's (renamed) folder, which is where it belongs.
    func switchAnyway() {
        guard case .waitingForHelpers = phase else { return }
        commit()
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
            if leftovers.isEmpty && Date().timeIntervalSince(since) > 0.6 {
                commit()
            }
        case .idle, .switching:
            stopPolling()
        }
    }

    private func commit() {
        stopPolling()
        guard let operation = pending else {
            phase = .idle
            return
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
        if openClaude { ClaudeApp.open() }
        phase = .idle
    }

    // MARK: - Settings

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

    func openClaude() { ClaudeApp.open() }

    // MARK: - Links

    static let donateURL = URL(string: "https://www.paypal.com/donate/?business=juanesgtgt2%40gmail.com&no_recurring=0&item_name=Issen+Software+Group")!
    static let projectURL = URL(string: "https://github.com/AA-EION/Clatch")!

    func donate() { NSWorkspace.shared.open(Self.donateURL) }
    func openProjectPage() { NSWorkspace.shared.open(Self.projectURL) }

    var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty || build == short ? short : "\(short) (\(build))"
    }
}
