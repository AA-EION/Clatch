// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import AppKit
import ClatchCore
import SwiftUI

/// The menu bar panel. One page at a time; the panel resizes to fit.
struct PanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.page {
            case .accounts:
                AccountsPage(model: model)
            case .addAccount:
                AddAccountPage(model: model)
            case .rename(let id):
                RenamePage(model: model, id: id)
            case .confirmRemove(let id):
                RemovePage(model: model, id: id)
            case .settings:
                SettingsPage(model: model)
            }
        }
        .padding(Design.padding)
        .frame(width: Design.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Accounts (main page)

struct AccountsPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if case .confirmLayout(let problems) = model.phase {
                LayoutWarningCard(model: model, problems: problems)
            } else if model.phase.isBusy {
                SwitchProgressCard(model: model)
            }
            if let message = model.errorMessage {
                ErrorBanner(message: message) { model.errorMessage = nil }
            }
            if !model.claudeInstalled {
                NoticeCard(systemImage: "questionmark.app",
                           text: "Claude Desktop is not installed in Applications. Clatch switches the accounts of the Claude Desktop app.")
            }

            VStack(spacing: 6) {
                ForEach(model.state.accounts) { account in
                    AccountRow(model: model, account: account,
                               isActive: account.id == model.state.activeID)
                }
            }
            .glassGroup(spacing: 6)

            if model.state.accounts.count == 1 {
                SingleAccountCallout(model: model)
            }

            VStack(spacing: 0) {
                ActionRow(title: "Add Account…", systemImage: "person.badge.plus",
                          isEnabled: !model.phase.isBusy) { model.page = .addAccount }
                ActionRow(title: "Settings…", systemImage: "gearshape") { model.page = .settings }
                ActionRow(title: "Quit Clatch", systemImage: "power", shortcutHint: "⌘Q") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
                ActionRow(title: "Donate", systemImage: "heart.fill", tint: .pink) { model.donate() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text("Clatch").font(.headline)
                Text("Claude accounts").font(.caption).foregroundColor(Color(NSColor.secondaryLabelColor))
            }
            Spacer()
            if let hotKey = model.hotKey, model.state.accounts.count > 1 {
                Text(hotKey.displayString)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .glassSurface(cornerRadius: 9)
                    .help("Press \(hotKey.displayString) anywhere to switch to the next account")
            }
        }
    }
}

struct AccountRow: View {
    @ObservedObject var model: AppModel
    var account: Account
    var isActive: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: { model.switchTo(account.id) }) {
                HStack(spacing: 10) {
                    Avatar(initials: account.initials, color: Design.color(for: account.id))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.name)
                            .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(Color(NSColor.secondaryLabelColor))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                            .help("Signed in to Claude now")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isActive || model.phase.isBusy)
            .help(isActive ? "Active account" : "Switch Claude to \(account.name)")

            Menu {
                Button("Rename…") { model.page = .rename(account.id) }
                Button("Move Up") { model.move(account.id, by: -1) }
                    .disabled(account.id == model.state.accounts.first?.id)
                Button("Move Down") { model.move(account.id, by: 1) }
                    .disabled(account.id == model.state.accounts.last?.id)
                Divider()
                Button("Remove…") { model.page = .confirmRemove(account.id) }
                    .disabled(isActive || model.phase.isBusy)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
            }
            .menuStyle(BorderlessButtonMenuStyle())
            .hiddenMenuIndicator()
            .fixedSize()
            .opacity(hovering || isActive ? 1 : 0.35)
            .help("More")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassSurface(cornerRadius: Design.rowRadius,
                      tint: isActive ? Design.color(for: account.id) : nil,
                      interactive: !isActive)
        .onHover { hovering = $0 }
    }

    private var subtitle: String {
        if isActive { return "Active" }
        if !model.hasStoredData(account.id) { return "Not signed in yet" }
        guard let date = account.lastUsedAt else { return "Click to switch" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Used " + formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Shown while there is only one account, which is how everyone starts.
struct SingleAccountCallout: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.2.fill")
                    .foregroundColor(.accentColor)
                Text("Use more than one Claude account? Add another and switch between them with one click or \(model.hotKey?.displayString ?? "a shortcut").")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: { model.page = .addAccount }) {
                Text("Add Another Account…").frame(maxWidth: .infinity)
            }
            .primaryButton()
            .disabled(model.phase.isBusy)
        }
        .padding(12)
        .glassSurface(tint: .accentColor)
    }
}

/// Progress of a switch, with the ways out.
struct SwitchProgressCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(title).font(.system(size: 13, weight: .medium))
            }
            Text(detail)
                .font(.caption)
                .foregroundColor(Color(NSColor.secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if case .waitingForClaude = model.phase {
                    Button("Ask Claude Again") { model.askClaudeToQuitAgain() }
                }
                if case .waitingForHelpers = model.phase {
                    Button("Switch Anyway") { model.switchAnyway() }
                }
                Spacer()
                if model.phase != .switching {
                    Button("Cancel") { model.cancelSwitch() }
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .glassSurface(tint: .orange)
    }

    private var title: String {
        switch model.phase {
        case .waitingForClaude: return "Waiting for Claude to quit…"
        case .waitingForHelpers: return "Waiting for Claude to finish…"
        case .switching: return "Switching…"
        case .idle, .confirmLayout: return ""
        }
    }

    private var detail: String {
        switch model.phase {
        case .waitingForClaude:
            return "If Claude asks whether to quit (for example while a session is running), choose Quit there. If you chose Cancel, nothing has changed: ask again or cancel here."
        case .waitingForHelpers:
            return "Claude is closed; its background processes are still exiting. Clatch switches as soon as they are done."
        case .switching, .idle, .confirmLayout:
            return "Claude will reopen with the other account."
        }
    }
}

/// Fail-safe: Claude's data folder is not what Clatch expects.
struct LayoutWarningCard: View {
    @ObservedObject var model: AppModel
    var problems: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text("Claude's data looks different").font(.system(size: 13, weight: .semibold))
            }
            Text("Claude Desktop may have changed how it stores its data. Nothing has been moved yet.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(problems, id: \.self) { problem in
                Text("• " + problem)
                    .font(.caption)
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Continuing may not switch the account, or may start Claude signed out. Your data stays in place either way.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { model.cancelSwitch() }
                Spacer()
                Button("Continue Anyway") { model.continueDespiteLayout() }
            }
            .controlSize(.small)
        }
        .padding(12)
        .glassSurface(tint: .orange)
    }
}

struct ErrorBanner: View {
    var message: String
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
            Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(PlainButtonStyle())
                .help("Dismiss")
        }
        .padding(10)
        .glassSurface(cornerRadius: Design.rowRadius, tint: .red)
    }
}

struct NoticeCard: View {
    var systemImage: String
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundColor(Color(NSColor.secondaryLabelColor))
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: Design.rowRadius)
    }
}
