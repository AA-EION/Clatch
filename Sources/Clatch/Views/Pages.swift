// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import AppKit
import ClatchCore
import SwiftUI

// MARK: - Add account

struct AddAccountPage: View {
    @ObservedObject var model: AppModel
    @State private var newName = ""
    @State private var currentName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Add Account") { model.page = .accounts }

            VStack(alignment: .leading, spacing: 8) {
                if model.sideBySide {
                    step(1, "Clatch creates a separate place for the new profile. Your other profiles keep running.")
                    step(2, "A new Claude window opens at the sign-in screen.")
                    step(3, "Sign in with the other account.")
                } else {
                    step(1, "Clatch asks Claude to quit. If a session is running, Claude asks you first.")
                    step(2, "Your current account is set aside in Clatch's accounts folder. Nothing is deleted.")
                    step(3, "Claude opens fresh. Sign in with the other account.")
                }
            }
            .padding(12)
            .glassSurface()

            if let active = model.state.active {
                labeled(model.sideBySide ? "Name for the account in Claude's own folder" : "Name for the account signed in now") {
                    TextField(active.name, text: $currentName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
            }
            labeled("Name for the new account") {
                TextField(model.suggestedNewName(), text: $newName, onCommit: submit)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            HStack {
                Button("Cancel") { model.page = .accounts }
                    .secondaryButton()
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: submit) { Text(buttonTitle) }
                    .primaryButton()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { currentName = model.state.active?.name ?? "" }
    }

    private var buttonTitle: String {
        if model.sideBySide { return "Add & Open" }
        return ClaudeApp.isRunning ? "Quit Claude & Add" : "Add & Open Claude"
    }

    private func submit() {
        let current = currentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rename = (current.isEmpty || current == model.state.active?.name) ? nil : current
        model.addAccount(name: newName, renameCurrentTo: rename)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.caption).foregroundColor(Color(NSColor.secondaryLabelColor))
        content()
    }
}

// MARK: - Edit profile

struct EditProfilePage: View {
    @ObservedObject var model: AppModel
    var id: UUID
    @State private var name = ""
    @State private var badge = ""
    @State private var color = ""
    @State private var environment = ""
    @State private var flags = ""
    @State private var problems: [String] = []
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Edit Profile") { model.page = .accounts }

            HStack(spacing: 12) {
                Image(nsImage: ProfileIcons.icon(for: preview, size: 56))
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: $name)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    HStack(spacing: 6) {
                        TextField("Badge", text: $badge)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 64)
                            .help("A letter or an emoji. Empty: the name's first letter.")
                        Text("letter or emoji").font(.caption).foregroundColor(Color(NSColor.secondaryLabelColor))
                    }
                }
            }

            HStack(spacing: 6) {
                ForEach(Account.palette, id: \.self) { hex in
                    Button(action: { color = hex }) {
                        Circle()
                            .fill(Color(NSColor(hex: hex) ?? .gray))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(Color.white, lineWidth: preview.resolvedColorHex == hex ? 2.5 : 0))
                            .overlay(Circle().stroke(Color.black.opacity(0.15), lineWidth: 0.5))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(hex)
                }
            }

            Button(action: { withAnimation { showAdvanced.toggle() } }) {
                HStack(spacing: 4) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                    Text("Environment variables & launch flags").font(.caption.weight(.semibold))
                }
            }
            .buttonStyle(PlainButtonStyle())

            if showAdvanced {
                labeled("Environment variables (NAME=value, one per line)") {
                    TextEditorBox(text: $environment)
                }
                labeled("Launch flags") {
                    TextField("e.g. --lang=es", text: $flags)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                Text("They apply the next time this profile's Claude starts. Use Restart Claude in the profile's menu to apply them now.")
                    .font(.caption)
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(problems, id: \.self) { problem in
                Text(problem).font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") { model.page = .accounts }
                    .secondaryButton()
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: save)
                    .primaryButton()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear(perform: load)
    }

    private var preview: Account {
        var account = model.account(id) ?? Account(id: id, name: name)
        account.name = name.isEmpty ? account.name : name
        account.badge = badge.isEmpty ? nil : badge
        account.colorHex = color.isEmpty ? account.colorHex : color
        return account
    }

    private func load() {
        guard let account = model.account(id) else { return }
        name = account.name
        badge = account.badge ?? ""
        color = account.colorHex ?? ""
        environment = LaunchOptions.formatEnvironment(account.environment)
        flags = LaunchOptions.formatArguments(account.arguments)
        showAdvanced = !account.environment.isEmpty || !account.arguments.isEmpty
    }

    private func save() {
        let parsedEnvironment = LaunchOptions.parseEnvironment(environment)
        let parsedFlags = LaunchOptions.parseArguments(flags)
        problems = parsedEnvironment.problems + LaunchOptions.problems(arguments: parsedFlags)
        guard problems.isEmpty, var account = model.account(id) else { return }
        account.name = name
        account.badge = badge.trimmingCharacters(in: .whitespaces).isEmpty ? nil : badge.trimmingCharacters(in: .whitespaces)
        account.colorHex = color.isEmpty ? nil : color
        account.environment = parsedEnvironment.values
        account.arguments = parsedFlags
        model.update(account)
    }
}

/// A small multi-line editor (TextEditor needs macOS 11; styled like a text field).
struct TextEditorBox: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12, design: .monospaced))
            .frame(height: 64)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(NSColor.separatorColor), lineWidth: 1))
    }
}

// MARK: - Remove

struct RemovePage: View {
    @ObservedObject var model: AppModel
    var id: UUID

    var body: some View {
        let name = model.account(id)?.name ?? "this account"
        return VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Remove Account") { model.page = .accounts }
            Text("Remove “\(name)” from Clatch? Its saved Claude sign-in and local data go to the Trash, so you can still restore them from there. Its launcher is removed too.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { model.page = .accounts }
                    .secondaryButton()
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Move to Trash") { model.remove(id) }
                    .primaryButton()
            }
        }
    }
}

// MARK: - Side by side: confirmation

struct ConfirmSideBySidePage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Run Profiles Side by Side?") { model.page = .settings }

            VStack(alignment: .leading, spacing: 8) {
                Label("Each profile gets its own Claude window, and several can be open at once. Switching is instant.",
                      systemImage: "rectangle.on.rectangle")
                Label("Several accounts are then signed in and active at the same time from this Mac. One at a time is the more conservative choice: like signing out and in, only one account is ever active.",
                      systemImage: "exclamationmark.shield")
                Label("Review Anthropic's terms for how your accounts may be used. Clatch does not change what each account is allowed to do.",
                      systemImage: "doc.text")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .glassSurface(tint: .orange)

            Text("Every profile keeps its sign-in in both modes, and Clatch backs them up whenever the mode changes. You can go back at any time.")
                .font(.caption)
                .foregroundColor(Color(NSColor.secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Anthropic's Terms") { model.openTerms() }
                    .secondaryButton()
                Spacer()
                Button("Cancel") { model.page = .settings }
                    .secondaryButton()
                    .keyboardShortcut(.cancelAction)
                Button("Use Side by Side") { model.confirmSideBySide() }
                    .primaryButton()
            }
        }
    }
}

// MARK: - Move Code-tab chats

struct MoveChatsPage: View {
    @ObservedObject var model: AppModel
    @State private var source: UUID?
    @State private var target: UUID?
    @State private var sessions: [CodeSession] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Move Code Chats") { model.page = .accounts }
            Text("Copies a chat from Claude's Code tab to another profile, so you can carry on there. (claude.ai chats are stored by Anthropic per account and cannot be moved.)")
                .font(.caption)
                .foregroundColor(Color(NSColor.secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                profilePicker("From", selection: $source)
                Image(systemName: "arrow.right").foregroundColor(Color(NSColor.secondaryLabelColor))
                profilePicker("To", selection: $target)
            }

            if let message = model.errorMessage {
                ErrorBanner(message: message) { model.errorMessage = nil }
            }
            if let notice = model.notice {
                NoticeCard(systemImage: "checkmark.circle", text: notice)
            }

            if sessions.isEmpty {
                NoticeCard(systemImage: "bubble.left.and.bubble.right", text: "No Code-tab chats in this profile yet.")
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(sessions) { session in
                            HoverRow(action: { copy(session) }, isEnabled: target != nil && target != source) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(session.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text([session.folder, relative(session.updated)].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                                        .lineLimit(1)
                                }
                            }
                            .help("Copy to \(model.account(target ?? UUID())?.name ?? "the other profile")")
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
        .onAppear {
            source = model.state.activeID ?? model.state.accounts.first?.id
            target = model.state.accounts.first { $0.id != source }?.id
            reload()
        }
    }

    private func profilePicker(_ title: String, selection: Binding<UUID?>) -> some View {
        Picker(title, selection: Binding(get: { selection.wrappedValue }, set: { selection.wrappedValue = $0; reload() })) {
            ForEach(model.state.accounts) { account in
                Text(account.name).tag(Optional(account.id))
            }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }

    private func reload() {
        sessions = source.map(model.codeSessions(of:)) ?? []
    }

    private func copy(_ session: CodeSession) {
        guard let target, target != source else { return }
        model.copy(session, to: target)
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Restore sign-ins

struct RestoreBackupsPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let backups = model.backups()
        return VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Restore Sign-ins") { model.page = .settings }
            Text("Clatch backs up every profile's sign-in when the mode changes (the newest three are kept). Restoring puts a profile's sign-in back as it was then; close that profile's Claude first.")
                .font(.caption)
                .foregroundColor(Color(NSColor.secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
            if backups.isEmpty {
                NoticeCard(systemImage: "clock.arrow.circlepath", text: "No backups yet.")
            }
            ForEach(backups) { snapshot in
                HoverRow(action: { model.restore(snapshot) }) {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(DateFormatter.localizedString(from: snapshot.date, dateStyle: .medium, timeStyle: .short))
                                .font(.system(size: 12, weight: .medium))
                            Text(snapshot.profiles.compactMap { model.account($0)?.name }.joined(separator: ", "))
                                .font(.caption)
                                .foregroundColor(Color(NSColor.secondaryLabelColor))
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("Restore").font(.caption.weight(.semibold)).foregroundColor(.accentColor)
                    }
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsPage: View {
    @ObservedObject var model: AppModel
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Settings") { model.page = .accounts }

            // How profiles run.
            VStack(alignment: .leading, spacing: 8) {
                Text("Profiles").font(.system(size: 13, weight: .medium))
                Picker("", selection: Binding(get: { model.sideBySide }, set: { model.requestSideBySide($0) })) {
                    Text("One at a time").tag(false)
                    Text("Side by side").tag(true)
                }
                .pickerStyle(SegmentedPickerStyle())
                .labelsHidden()
                .disabled(model.phase.isBusy)
                Text(model.sideBySide
                     ? "Each profile runs its own Claude; the switcher brings it to the front or opens it."
                     : "One Claude, one account active at a time; the switcher closes Claude, swaps the account and reopens it.")
                    .font(.caption)
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)
                if model.sideBySide {
                    Toggle("Send sign-ins to the profile that asked", isOn: Binding(get: { model.preferences.routeSignIns }, set: { model.setRouting($0) }))
                        .help("Makes Clatch the handler for claude:// links and passes each one to the right profile's Claude.")
                    Toggle("Reopen profiles after Claude updates", isOn: $model.watchdogEnabled)
                }
            }
            .toggleStyle(SwitchToggleStyle())
            .controlSize(.small)
            .padding(12)
            .glassSurface()

            // The shortcut.
            VStack(alignment: .leading, spacing: 8) {
                Text("Profile switcher").font(.system(size: 13, weight: .medium))
                HStack(spacing: 8) {
                    Text(recorder.isRecording ? "Type a shortcut…" : (model.hotKey?.displayString ?? "Off"))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .frame(minWidth: 96)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassSurface(cornerRadius: 8, tint: recorder.isRecording ? .accentColor : nil)
                    Spacer()
                    if recorder.isRecording {
                        Button("Cancel") { recorder.stop() }
                    } else {
                        Button("Change") { startRecording() }
                        Button("Default") { model.setHotKey(.default) }
                            .disabled(model.hotKey == .default)
                        Button(action: { model.setHotKey(nil) }) { Image(systemName: "xmark") }
                            .help("Turn the shortcut off")
                            .disabled(model.hotKey == nil)
                    }
                }
                .controlSize(.small)
                Text("Hold the keys and tap the letter to move between profiles; let go to open the highlighted one.")
                    .font(.caption)
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)
                if let message = recorder.message ?? registrationMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .glassSurface()

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Profile launchers in Applications", isOn: $model.profileShortcuts)
                    .help("~/Applications/Clatch Profiles: one app per profile, kept in step with your profiles.")
                if !model.sideBySide {
                    Toggle("Reopen Claude after switching", isOn: $model.reopenClaude)
                }
                Toggle("Same MCP & tool settings for every account", isOn: $model.shareToolSettings)
                    .help("Copies claude_desktop_config.json to the account you switch to.")
                Toggle("Check for updates daily", isOn: $model.updateChecks)
                if LoginItem.isSupported {
                    Toggle("Open Clatch at login", isOn: $model.openAtLogin)
                }
            }
            .toggleStyle(SwitchToggleStyle())
            .controlSize(.small)
            .padding(12)
            .glassSurface()

            VStack(spacing: 0) {
                if model.profileShortcuts {
                    ActionRow(title: "Show Profile Launchers", systemImage: "square.grid.2x2") { model.revealShortcutsFolder() }
                }
                ActionRow(title: "Restore Sign-ins…", systemImage: "clock.arrow.circlepath") { model.page = .restoreBackups }
                ActionRow(title: "Check for Updates", systemImage: "arrow.down.circle") { model.checkForUpdates(force: true) }
                ActionRow(title: "Show Accounts Folder", systemImage: "folder") { model.revealAccountsFolder() }
                ActionRow(title: "Open Log", systemImage: "doc.text.magnifyingglass") { model.openLog() }
                ActionRow(title: "Clatch on GitHub", systemImage: "chevron.left.slash.chevron.right") {
                    model.openProjectPage()
                }
            }

            if let notice = model.notice {
                NoticeCard(systemImage: "info.circle", text: notice)
            }
            if let message = model.errorMessage {
                ErrorBanner(message: message) { model.errorMessage = nil }
            }

            Text("Clatch \(model.version) · GPL-3.0-or-later · Issen Software Group")
                .font(.caption2)
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .onDisappear { recorder.stop() }
    }

    private var registrationMessage: String? {
        switch model.hotKeyRegistration {
        case .takenByAnotherApp: return "Another app already uses this shortcut. Choose a different one."
        case .conflictsWithSystem: return "macOS already uses this shortcut. Choose a different one."
        case .active, .off: return nil
        }
    }

    private func startRecording() {
        model.suspendHotKey()
        recorder.start(
            onRecord: { combo in model.setHotKey(combo) },
            onEnd: { model.resumeHotKey() })
    }
}

/// Captures the next key combination typed while the panel is open.
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var message: String?

    private var monitor: Any?
    private var onRecord: ((KeyCombo) -> Void)?
    private var onEnd: (() -> Void)?

    func start(onRecord: @escaping (KeyCombo) -> Void, onEnd: @escaping () -> Void) {
        stop()
        self.onRecord = onRecord
        self.onEnd = onEnd
        message = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Copy the plain values out first: NSEvent itself is not Sendable.
            let code = event.keyCode
            let flags = event.modifierFlags
            let characters = event.charactersIgnoringModifiers
            let consumed = MainActor.assumeIsolated {
                self?.handle(HotKeyCenter.combo(keyCode: code, flags: flags, characters: characters)) ?? false
            }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let wasRecording = isRecording
        isRecording = false
        if wasRecording { onEnd?() }
        onRecord = nil
        onEnd = nil
    }

    /// Returns true when the event was consumed.
    private func handle(_ combo: KeyCombo) -> Bool {
        // Esc alone cancels, like every shortcut recorder on macOS.
        if combo.keyCode == 53 && combo.modifiers == 0 {
            stop()
            return true
        }
        guard combo.isAcceptable else {
            message = "Include ⌘, ⌃ or ⌥ (function keys work alone)."
            return true
        }
        if HotKeyCenter.isSystemShortcut(combo) {
            message = "\(combo.displayString) is a macOS shortcut. Try another."
            return true
        }
        let record = onRecord
        message = nil
        stop()
        record?(combo)
        return true
    }
}
