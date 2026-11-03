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
                step(1, "Clatch asks Claude to quit. If a session is running, Claude asks you first.")
                step(2, "Your current account is set aside in Clatch's accounts folder. Nothing is deleted.")
                step(3, "Claude opens fresh. Sign in with the other account.")
            }
            .padding(12)
            .glassSurface()

            if let active = model.state.active {
                labeled("Name for the account signed in now") {
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
                Button(action: submit) { Text(ClaudeApp.isRunning ? "Quit Claude & Add" : "Add & Open Claude") }
                    .primaryButton()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            currentName = model.state.active?.name ?? ""
        }
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

private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.caption).foregroundColor(Color(NSColor.secondaryLabelColor))
        content()
    }
}

// MARK: - Rename

struct RenamePage: View {
    @ObservedObject var model: AppModel
    var id: UUID
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Rename Account") { model.page = .accounts }
            TextField("Name", text: $name, onCommit: save)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            Text("Tip: use the email address you sign in with, so you can tell accounts apart.")
                .font(.caption)
                .foregroundColor(Color(NSColor.secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
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
        .onAppear { name = model.state.accounts.first { $0.id == id }?.name ?? "" }
    }

    private func save() { model.rename(id, to: name) }
}

// MARK: - Remove

struct RemovePage: View {
    @ObservedObject var model: AppModel
    var id: UUID

    var body: some View {
        let name = model.state.accounts.first { $0.id == id }?.name ?? "this account"
        return VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Remove Account") { model.page = .accounts }
            Text("Remove “\(name)” from Clatch? Its saved Claude sign-in and local data go to the Trash, so you can still restore them from there.")
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

// MARK: - Settings

struct SettingsPage: View {
    @ObservedObject var model: AppModel
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Settings") { model.page = .accounts }

            VStack(alignment: .leading, spacing: 8) {
                Text("Switch to next account").font(.system(size: 13, weight: .medium))
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
                Toggle("Reopen Claude after switching", isOn: binding(\.reopenClaude))
                Toggle("Same MCP & tool settings for every account", isOn: binding(\.shareToolSettings))
                    .help("Copies claude_desktop_config.json to the account you switch to.")
                if LoginItem.isSupported {
                    Toggle("Open Clatch at login", isOn: binding(\.openAtLogin))
                }
            }
            .toggleStyle(SwitchToggleStyle())
            .controlSize(.small)
            .padding(12)
            .glassSurface()

            VStack(spacing: 0) {
                ActionRow(title: "Show Accounts Folder", systemImage: "folder") { model.revealAccountsFolder() }
                ActionRow(title: "Open Claude", systemImage: "arrow.up.forward.app",
                          isEnabled: ClaudeApp.isInstalled) { model.openClaude() }
                ActionRow(title: "Clatch on GitHub", systemImage: "chevron.left.slash.chevron.right") {
                    model.openProjectPage()
                }
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

    private func binding(_ keyPath: ReferenceWritableKeyPath<AppModel, Bool>) -> Binding<Bool> {
        Binding(get: { model[keyPath: keyPath] }, set: { model[keyPath: keyPath] = $0 })
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
