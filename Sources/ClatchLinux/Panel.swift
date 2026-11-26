// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import CGtk
import ClatchCore
import Foundation

/// Clatch's window: the profiles, their actions, and the pages for adding,
/// editing and settings. Created when it is opened and destroyed when it is
/// closed, so nothing is drawn while it is not shown.
@MainActor
final class Panel {
    private let model: AppModel
    private(set) var window: GPtr?
    private var scroller: GPtr?
    private var titleWidget: GPtr?
    private var backButton: GPtr?
    private var renderedPage: Page?
    private var recording = false
    private var recorderMessage: String?
    private var pageMessage: String?
    private var draftColor: String?
    private var chatsFrom: UUID?
    private var chatsTo: UUID?
    private var observing = false

    init(model: AppModel) { self.model = model }

    var isOpen: Bool { window != nil }

    func present(token: String? = nil) {
        if let window {
            if let token { gtk_window_set_startup_id(window.t(), token) }
            gtk_window_present(window.t())
            return
        }
        model.windowWillOpen()
        let window = g(adw_application_window_new(model.app.t()))
        self.window = window
        gtk_window_set_title(window.t(), "Clatch")
        gtk_window_set_default_size(window.t(), 420, 640)
        gtk_window_set_icon_name(window.t(), Desktop.appID)

        let header = g(adw_header_bar_new())
        let title = g(adw_window_title_new("Clatch", ""))
        titleWidget = title
        adw_header_bar_set_title_widget(header.t(), title.t())
        let back = UI.iconButton("go-previous-symbolic", "Back") { [weak self] in self?.goBack() }
        backButton = back
        adw_header_bar_pack_start(header.t(), back.t())

        let scroller = g(gtk_scrolled_window_new())
        self.scroller = scroller
        gtk_scrolled_window_set_policy(scroller.t(), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_vexpand(scroller.t(), 1)
        let content = UI.vbox(0, [header, scroller])
        adw_application_window_set_content(window.t(), content.t())

        let keys = g(gtk_event_controller_key_new())
        gtk_event_controller_set_propagation_phase(keys.t(), GTK_PHASE_CAPTURE)
        onKey(keys, released: false) { [weak self] keyval, state in self?.keyPressed(keyval, state) ?? false }
        gtk_widget_add_controller(window.t(), keys.t())
        onSignalBool(window, "close-request") { [weak self] in
            self?.closed()
            return false
        }
        if !observing {
            observing = true
            model.observe { [weak self] in self?.render() }
        }
        renderedPage = nil
        render()
        if let token { gtk_window_set_startup_id(window.t(), token) }
        gtk_window_present(window.t())
        Log.write("Window shown")
    }

    func close() {
        guard let window else { return }
        gtk_window_close(window.t())
    }

    private func closed() {
        window = nil
        scroller = nil
        if recording { recording = false; model.shortcut.set(model.settings.hotKey) }
        model.windowDidClose()
    }

    private func goBack() {
        switch model.page {
        case .confirmSideBySide, .restoreBackups: model.show(.settings)
        default: model.show(.accounts)
        }
    }

    // MARK: - Rendering

    /// Rebuilds the page. Pages with text being typed are not rebuilt by
    /// background changes (a Claude starting), only when the page itself changes.
    func render(force: Bool = false) {
        guard window != nil, let scroller else { return }
        let page = model.page
        let editing: Bool
        switch page {
        case .addAccount, .editProfile: editing = true
        default: editing = false
        }
        if editing && page == renderedPage && !force { return }
        if page != renderedPage {
            pageMessage = nil
            draftColor = nil
        }
        renderedPage = page

        let box = UI.vbox(18)
        gtk_widget_set_margin_top(box.t(), 12)
        gtk_widget_set_margin_bottom(box.t(), 18)
        gtk_widget_set_margin_start(box.t(), 14)
        gtk_widget_set_margin_end(box.t(), 14)
        let title: String
        switch page {
        case .accounts: title = "Clatch"; renderAccounts(box)
        case .addAccount: title = "Add Account"; renderAddAccount(box)
        case .editProfile(let id): title = "Edit Profile"; renderEditProfile(box, id)
        case .confirmRemove(let id): title = "Remove Account"; renderRemove(box, id)
        case .settings: title = "Settings"; renderSettings(box)
        case .confirmSideBySide: title = "Side by Side"; renderConfirmSideBySide(box)
        case .moveChats: title = "Move Code Chats"; renderMoveChats(box)
        case .restoreBackups: title = "Restore Sign-ins"; renderRestoreBackups(box)
        }
        if let titleWidget {
            adw_window_title_set_title(titleWidget.t(), title)
            adw_window_title_set_subtitle(titleWidget.t(), page == .accounts
                ? (model.sideBySide ? "Claude profiles · side by side" : "Claude profiles · one at a time") : "")
        }
        if let backButton { gtk_widget_set_visible(backButton.t(), page == .accounts ? 0 : 1) }
        let clamp = g(adw_clamp_new())
        adw_clamp_set_maximum_size(clamp.t(), 560)
        adw_clamp_set_child(clamp.t(), box.t())
        gtk_scrolled_window_set_child(scroller.t(), clamp.t())
    }

    private func messages(_ box: GPtr) {
        if let error = model.errorMessage {
            let close = UI.iconButton("window-close-symbolic", "Dismiss") { [weak self] in
                self?.model.errorMessage = nil
                self?.model.notify()
            }
            UI.append(box, UI.card(UI.hbox(8, [UI.icon("dialog-error-symbolic"), UI.expand(UI.label(error)), close]), tint: "clatch-tint-error"))
        }
        if let notice = model.notice {
            UI.append(box, UI.card(UI.hbox(8, [UI.icon("emblem-ok-symbolic"), UI.expand(UI.label(notice))]), tint: "clatch-tint-success"))
        }
    }

    // MARK: Profiles

    private func renderAccounts(_ box: GPtr) {
        if case .confirmLayout(let problems) = model.phase { UI.append(box, layoutWarning(problems)) }
        else if model.isBusy { UI.append(box, progress()) }

        if let update = model.availableUpdate {
            let download = UI.button("Download", ["pill", "suggested-action"]) { [weak self] in self?.model.openURI(update.page.absoluteString) }
            UI.append(box, UI.card(UI.hbox(10, [UI.expand(UI.label("Clatch \(update.version) is available.", ["heading"])), download]),
                                   tint: "clatch-tint-accent"))
        }
        messages(box)
        if !Claude.isInstalled {
            UI.append(box, UI.card(UI.label("Claude Desktop was not found. Clatch switches the accounts of the Claude Desktop app (install it from claude.com/download)."),
                                   tint: "clatch-tint-warning"))
        }
        if model.claudeUpdatedWhileOpen {
            let restart = UI.button("Restart Them", ["pill"]) { [weak self] in self?.model.restartOpenProfiles() }
            UI.append(box, UI.card(UI.hbox(10, [UI.expand(UI.label("Claude was updated. Restart the open profiles to use the new version.")), restart]),
                                   tint: "clatch-tint-accent"))
        }

        let rows = model.state.accounts.enumerated().map { accountRow($0.element, index: $0.offset) }
        UI.append(box, UI.list(rows))

        if model.state.accounts.count == 1 {
            let key = model.settings.hotKey.map(Self.acceleratorLabel) ?? "a shortcut"
            let add = UI.button("Add Another Account…", ["pill", "suggested-action"]) { [weak self] in self?.model.show(.addAccount) }
            UI.append(box, UI.card(UI.vbox(10, [UI.label("Use more than one Claude account? Add another and switch between them with one click or \(key)."), add]),
                                   tint: "clatch-tint-accent"))
        }

        var actions: [GPtr] = [
            actionRow("Add Account…", "list-add-symbolic", enabled: !model.isBusy) { [weak self] in self?.model.show(.addAccount) },
        ]
        if model.state.accounts.count > 1 {
            actions.append(actionRow("Move Code Chats…", "mail-forward-symbolic", enabled: !model.isBusy) { [weak self] in self?.model.show(.moveChats) })
        }
        actions += [
            actionRow("Settings…", "emblem-system-symbolic") { [weak self] in self?.model.show(.settings) },
            actionRow("Quit Clatch", "application-exit-symbolic") { [weak self] in self?.quit() },
            actionRow("Donate", "emblem-favorite-symbolic") { [weak self] in self?.model.openURI(AppModel.donateURL) },
        ]
        UI.append(box, UI.list(actions))
    }

    private func quit() {
        Log.write("Quit")
        g_application_quit(model.app.t())
    }

    private func actionRow(_ title: String, _ icon: String, enabled: Bool = true, _ action: @escaping Action) -> GPtr {
        let row = UI.row(title, prefix: UI.icon(icon), activate: action)
        gtk_widget_set_sensitive(row.t(), enabled ? 1 : 0)
        return row
    }

    private func isCurrent(_ account: Account) -> Bool {
        model.sideBySide ? model.isRunning(account.id) : account.id == model.state.activeID
    }

    private func accountRow(_ account: Account, index: Int) -> GPtr {
        let id = account.id
        let isActive = id == model.state.activeID
        let running = model.isRunning(id)
        let side = model.sideBySide

        let icon = profileIcon(account, running: running, size: 36)
        var suffix: [GPtr] = []
        if index < 9 { suffix.append(UI.align(UI.css(UI.label("Ctrl+\(index + 1)", ["caption", "dim-label"], wrap: false), "clatch-chip"), v: GTK_ALIGN_CENTER)) }
        if isCurrent(account) && !side { suffix.append(UI.icon("object-select-symbolic")) }

        var items: [(String, Bool, Action)?] = [
            (side && running ? "Bring to Front" : side || isActive ? "Open Claude" : "Switch to This Account", !model.isBusy,
             { [weak self] in self?.model.open(id) }),
        ]
        if side && running {
            items.append(("Close Claude", true, { [weak self] in self?.model.close(id) }))
            items.append(("Restart Claude", true, { [weak self] in self?.model.restart(id) }))
        }
        items.append(nil)
        items.append(("Edit…", true, { [weak self] in self?.model.show(.editProfile(id)) }))
        items.append(("Move Up", id != model.state.accounts.first?.id, { [weak self] in self?.model.move(id, by: -1) }))
        items.append(("Move Down", id != model.state.accounts.last?.id, { [weak self] in self?.model.move(id, by: 1) }))
        items.append(nil)
        items.append(("Remove…", !isActive && !running && !model.isBusy, { [weak self] in self?.model.show(.confirmRemove(id)) }))
        suffix.append(UI.menuButton(items))

        let row = UI.row(account.name, subtitle: subtitle(account, isActive: isActive, running: running), prefix: icon, suffix: suffix) {
            [weak self] in self?.model.open(id)
        }
        gtk_widget_set_sensitive(row.t(), model.isBusy ? 0 : 1)
        _ = UI.tooltip(row, side ? (running ? "Bring \(account.name)'s Claude to the front" : "Open Claude as \(account.name)")
                       : (isActive ? (model.claudeRunning ? "Signed in to Claude now" : "Open Claude") : "Switch Claude to \(account.name)"))
        if isCurrent(account) { UI.css(row, "clatch-tint-accent") }
        return row
    }

    private func subtitle(_ account: Account, isActive: Bool, running: Bool) -> String {
        if model.sideBySide {
            if running { return "Open" }
        } else if isActive {
            return model.claudeRunning ? "Active" : "Active · Claude is closed"
        }
        if !isActive && !model.hasStoredData(account.id) { return "Not signed in yet" }
        guard let used = account.lastUsedAt else { return model.sideBySide ? "Click to open" : "Click to switch" }
        let ago = Date().timeIntervalSince(used)
        return "Used " + (ago < 60 ? "just now" : ago < 3600 ? "\(Int(ago / 60)) min ago"
                          : ago < 86400 ? "\(Int(ago / 3600)) h ago" : "\(Int(ago / 86400)) days ago")
    }

    /// The badged icon, with a green dot while its Claude runs.
    private func profileIcon(_ account: Account, running: Bool, size: Int32) -> GPtr {
        let image = UI.image(file: ProfileIcons.png(for: account), size: size)
        let overlay = g(gtk_overlay_new())
        gtk_overlay_set_child(overlay.t(), image.t())
        if running {
            let dot = UI.align(UI.css(UI.hbox(0), "clatch-dot"), h: GTK_ALIGN_END, v: GTK_ALIGN_END)
            gtk_overlay_add_overlay(overlay.t(), dot.t())
        }
        return UI.align(overlay, v: GTK_ALIGN_CENTER)
    }

    private func progress() -> GPtr {
        let spinner = g(gtk_spinner_new())
        gtk_spinner_start(spinner.t())
        let title: String
        let caption: String
        switch model.phase {
        case .waitingForClaude:
            title = "Waiting for Claude to close…"
            caption = model.quitDeclined
                ? "Claude hasn't closed. If it asked you to confirm, choose to quit there. You can also quit it from its own menu or its icon in the top bar; Clatch continues by itself."
                : "If Claude asks whether to close (for example while a session is running), confirm there. If you say no, nothing changes."
        case .waitingForHelpers:
            title = "Waiting for Claude to finish…"
            caption = "Claude is closed; its background processes (Claude Code, Cowork) are still exiting."
        case .closingProfiles:
            title = "Closing the other profiles…"
            caption = "Going back to one at a time: Clatch asks every other profile's Claude to close. If one asks you first, confirm there. Their sign-ins are kept and backed up."
        default:
            title = "Switching…"
            caption = "Claude will reopen with the other account."
        }
        let buttons = UI.align(UI.hbox(8), h: GTK_ALIGN_END)
        if model.quitDeclined && model.canAskAgain {
            UI.append(buttons, UI.button("Ask Claude Again", ["pill"]) { [weak self] in self?.model.askClaudeToQuitAgain() })
        }
        if model.helpersTakingLong {
            UI.append(buttons, UI.button("Switch Anyway", ["pill"]) { [weak self] in self?.model.switchAnyway() })
        }
        if model.phase != .switching {
            UI.append(buttons, UI.button("Cancel", ["pill"]) { [weak self] in self?.model.cancelSwitch() })
        }
        return UI.card(UI.vbox(8, [UI.hbox(8, [spinner, UI.heading(title)]), UI.caption(caption), buttons]), tint: "clatch-tint-warning")
    }

    private func layoutWarning(_ problems: [String]) -> GPtr {
        let content = UI.vbox(6, [UI.hbox(8, [UI.icon("dialog-warning-symbolic"), UI.heading("Claude's data looks different")]),
                                  UI.caption("Claude Desktop may have changed how it stores its data. Nothing has been moved yet.")])
        problems.forEach { UI.append(content, UI.caption("• " + $0)) }
        UI.append(content, UI.caption("Continuing may not switch the account, or may start Claude signed out. Your data stays in place either way."))
        UI.append(content, UI.align(UI.hbox(8, [
            UI.button("Cancel", ["pill"]) { [weak self] in self?.model.cancelSwitch() },
            UI.button("Continue Anyway", ["pill", "destructive-action"]) { [weak self] in self?.model.continueDespiteLayout() },
        ]), h: GTK_ALIGN_END))
        return UI.card(content, tint: "clatch-tint-warning")
    }

    // MARK: Add, edit, remove

    private func step(_ number: Int, _ text: String) -> GPtr {
        let badge = UI.css(UI.label("\(number)", ["caption-heading"], wrap: false, xalign: 0.5), "clatch-chip")
        return UI.hbox(10, [UI.align(badge, v: GTK_ALIGN_START), UI.expand(UI.label(text))])
    }

    private func renderAddAccount(_ box: GPtr) {
        let steps = model.sideBySide
            ? ["Clatch makes a new profile with its own Claude data folder.",
               "A second Claude window opens for it, next to the ones already open.",
               "Sign in there with the other account."]
            : ["Clatch asks Claude to close. If a session is running, Claude asks you first.",
               "Your current account is set aside in Clatch's folder. Nothing is deleted.",
               "Claude opens fresh. Sign in with the other account."]
        UI.append(box, UI.card(UI.vbox(8, steps.enumerated().map { step($0.offset + 1, $0.element) })))

        let current = UI.entry(model.state.active?.name ?? "")
        let added = UI.entry("", placeholder: model.suggestedNewName())
        let submit: Action = { [weak self] in
            guard let self else { return }
            let rename = UI.text(of: current).trimmingCharacters(in: .whitespaces)
            self.model.addAccount(name: UI.text(of: added),
                                  renameCurrentTo: rename.isEmpty || rename == self.model.state.active?.name ? nil : rename)
        }
        onSignal(added, "activate", submit)
        if model.state.active != nil { UI.append(box, UI.field("Name for the account signed in now", current)) }
        UI.append(box, UI.field("Name for the new account", added))
        let primary = model.sideBySide ? "Add & Open" : model.claudeRunning ? "Close Claude & Add" : "Add & Open Claude"
        UI.append(box, UI.buttonRow(("Cancel", { [weak self] in self?.model.show(.accounts) }), (primary, submit)))
        if model.settings.profileShortcuts {
            UI.append(box, UI.caption("A shortcut for the new profile appears in your apps and on the Desktop."))
        }
        after(0.05) { gtk_widget_grab_focus(added.t()) }
    }

    private func renderEditProfile(_ box: GPtr, _ id: UUID) {
        guard let account = model.account(id) else { return model.show(.accounts) }
        if draftColor == nil { draftColor = account.colorHex ?? account.resolvedColorHex }
        let name = UI.entry(account.name, placeholder: "you@example.com")
        let badge = UI.entry(account.badge ?? "", placeholder: account.badgeText)
        gtk_entry_set_max_length(badge.t(), 8)
        let environment = UI.textArea(LaunchOptions.formatEnvironment(account.environment))
        let flags = UI.entry(LaunchOptions.formatArguments(account.arguments), placeholder: "--example-flag")

        // A live preview of the icon, and the colour choices.
        let previewHost = UI.hbox(0)
        let refresh: Action = { [weak self] in
            guard let self else { return }
            var preview = account
            let typed = UI.text(of: name).trimmingCharacters(in: .whitespaces)
            if !typed.isEmpty { preview.name = typed }
            preview.badge = UI.text(of: badge)
            preview.colorHex = self.draftColor
            while let child = gtk_widget_get_first_child(previewHost.t()) { gtk_box_remove(previewHost.t(), child) }
            UI.append(previewHost, UI.image(file: ProfileIcons.png(for: preview), size: 56))
        }
        refresh()
        let swatches = UI.hbox(6)
        for hex in Account.palette {
            let swatch = UI.button(content: UI.hbox(0), ["clatch-swatch"]) { [weak self] in
                self?.draftColor = hex
                self?.render(force: true)
            }
            let provider = gtk_css_provider_new()
            gtk_css_provider_load_from_data(provider, "button { background: \(hex); }", -1)
            gtk_style_context_add_provider(gtk_widget_get_style_context(swatch.t()), GPtr(provider!).t(), guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
            if hex.caseInsensitiveCompare(draftColor ?? "") == .orderedSame { UI.css(swatch, "selected") }
            _ = UI.tooltip(swatch, hex)
            UI.append(swatches, UI.align(swatch, v: GTK_ALIGN_CENTER))
        }
        onSignal(name, "changed", refresh)
        onSignal(badge, "changed", refresh)
        UI.append(box, UI.card(UI.hbox(14, [previewHost, UI.align(swatches, v: GTK_ALIGN_CENTER)])))
        UI.append(box, UI.field("Name", name))
        UI.append(box, UI.field("Badge (a letter or an emoji)", badge))
        UI.append(box, UI.field("Environment variables (NAME=value, one per line)", environment))
        UI.append(box, UI.field("Extra flags for Claude", flags))
        UI.append(box, UI.caption("Applied whenever Clatch starts this profile's Claude. --user-data-dir is set by Clatch."))
        if let pageMessage { UI.append(box, UI.card(UI.label(pageMessage), tint: "clatch-tint-error")) }

        let save: Action = { [weak self] in
            guard let self else { return }
            let parsed = LaunchOptions.parseEnvironment(UI.text(ofArea: environment))
            let arguments = LaunchOptions.parseArguments(UI.text(of: flags))
            var problems = parsed.problems + LaunchOptions.problems(arguments: arguments)
            let newName = UI.text(of: name).trimmingCharacters(in: .whitespaces)
            if newName.isEmpty { problems.insert("Give the profile a name.", at: 0) }
            guard problems.isEmpty else {
                self.pageMessage = problems.joined(separator: "\n")
                return self.render(force: true)
            }
            var updated = account
            updated.name = newName
            let badgeText = UI.text(of: badge).trimmingCharacters(in: .whitespaces)
            updated.badge = badgeText.isEmpty ? nil : badgeText
            updated.colorHex = account.colorHex == nil && self.draftColor?.caseInsensitiveCompare(account.resolvedColorHex) == .orderedSame
                ? nil : self.draftColor
            updated.environment = parsed.values
            updated.arguments = arguments
            self.model.update(updated)
        }
        onSignal(name, "activate", save)
        UI.append(box, UI.buttonRow(("Cancel", { [weak self] in self?.model.show(.accounts) }), ("Save", save)))
    }

    private func renderRemove(_ box: GPtr, _ id: UUID) {
        let name = model.account(id)?.name ?? "this account"
        UI.append(box, UI.label("Remove “\(name)” from Clatch? Its saved Claude sign-in and local data go to the Trash, so you can still restore them from there."
                                + (model.settings.profileShortcuts ? " Its shortcuts are removed too." : "")))
        UI.append(box, UI.buttonRow(("Cancel", { [weak self] in self?.model.show(.accounts) }),
                                    ("Move to Trash", { [weak self] in self?.model.remove(id) }), destructive: true))
    }

    // MARK: Side by side, chats, backups

    private func renderConfirmSideBySide(_ box: GPtr) {
        let points = UI.vbox(12, [
            UI.hbox(10, [UI.align(UI.icon("view-dual-symbolic", size: 20), v: GTK_ALIGN_START),
                         UI.expand(UI.label("Each profile gets its own Claude window, and several can be open at once. Switching is instant."))]),
            UI.hbox(10, [UI.align(UI.icon("security-medium-symbolic", size: 20), v: GTK_ALIGN_START),
                         UI.expand(UI.label("Several accounts are then signed in and active at the same time from this computer. One at a time is the more conservative choice: like signing out and in, only one account is ever active."))]),
            UI.hbox(10, [UI.align(UI.icon("text-x-generic-symbolic", size: 20), v: GTK_ALIGN_START),
                         UI.expand(UI.label("Review Anthropic's terms for how your accounts may be used. Clatch does not change what each account is allowed to do."))]),
        ])
        UI.append(box, UI.card(points, tint: "clatch-tint-warning"))
        UI.append(box, UI.caption("On Linux, Cowork can run for one profile at a time: Claude's Cowork helper is shared by every Claude of your user."))
        UI.append(box, UI.caption("Every profile keeps its sign-in in both modes, and Clatch backs them up whenever the mode changes. You can go back at any time."))
        let terms = UI.button("Anthropic's Terms", ["flat"]) { [weak self] in self?.model.openURI(AppModel.termsURL) }
        UI.append(box, UI.align(terms, h: GTK_ALIGN_START))
        UI.append(box, UI.buttonRow(("Cancel", { [weak self] in self?.model.show(.settings) }),
                                    ("Use Side by Side", { [weak self] in self?.model.confirmSideBySide() })))
    }

    private func renderMoveChats(_ box: GPtr) {
        UI.append(box, UI.caption("Copies a chat from Claude's Code tab to another profile, so you can carry on there. (claude.ai chats are stored by Anthropic per account and cannot be moved.)"))
        let accounts = model.state.accounts
        if chatsFrom.flatMap(model.account) == nil { chatsFrom = model.state.activeID ?? accounts.first?.id }
        if chatsTo.flatMap(model.account) == nil || chatsTo == chatsFrom { chatsTo = accounts.first { $0.id != chatsFrom }?.id }
        let names = accounts.map(\.name)
        let from = UI.dropdown(names, selected: accounts.firstIndex { $0.id == chatsFrom } ?? 0) { [weak self] index in
            self?.chatsFrom = accounts[index].id
            self?.render(force: true)
        }
        let to = UI.dropdown(names, selected: accounts.firstIndex { $0.id == chatsTo } ?? 0) { [weak self] index in
            self?.chatsTo = accounts[index].id
            self?.render(force: true)
        }
        UI.append(box, UI.hbox(8, [UI.expand(UI.field("From", from)), UI.align(UI.icon("go-next-symbolic"), v: GTK_ALIGN_END),
                                   UI.expand(UI.field("To", to))]))
        messages(box)
        guard let source = chatsFrom, let target = chatsTo else { return }
        let sessions = model.codeSessions(of: source)
        if sessions.isEmpty {
            UI.append(box, UI.card(UI.caption("No Code-tab chats in this profile yet.")))
            return
        }
        let targetName = model.account(target)?.name ?? "the other profile"
        let rows = sessions.map { session -> GPtr in
            let detail = [session.folder, relative(session.updated)].filter { !$0.isEmpty }.joined(separator: " · ")
            let row = UI.row(session.title, subtitle: detail, suffix: [UI.icon("edit-copy-symbolic")]) { [weak self] in
                self?.model.copy(session, to: target)
            }
            _ = UI.tooltip(row, "Copy to \(targetName)")
            gtk_widget_set_sensitive(row.t(), source != target ? 1 : 0)
            return row
        }
        UI.append(box, UI.list(rows))
    }

    private func relative(_ date: Date) -> String {
        let ago = Date().timeIntervalSince(date)
        return ago < 60 ? "just now" : ago < 3600 ? "\(Int(ago / 60)) min ago" : ago < 86400 ? "\(Int(ago / 3600)) h ago" : "\(Int(ago / 86400)) days ago"
    }

    private func renderRestoreBackups(_ box: GPtr) {
        UI.append(box, UI.caption("Clatch backs up every profile's sign-in when the mode changes (the newest three are kept). Restoring puts a profile's sign-in back as it was then; close that profile's Claude first."))
        messages(box)
        let backups = model.backups()
        guard !backups.isEmpty else { return UI.append(box, UI.card(UI.caption("No backups yet."))) }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let rows = backups.map { snapshot -> GPtr in
            let names = snapshot.profiles.compactMap { model.account($0)?.name }.joined(separator: ", ")
            let restore = UI.button("Restore", ["flat"]) { [weak self] in self?.model.restore(snapshot) }
            return UI.row(formatter.string(from: snapshot.date), subtitle: names, prefix: UI.icon("document-open-recent-symbolic"),
                          suffix: [UI.align(restore, v: GTK_ALIGN_CENTER)])
        }
        UI.append(box, UI.list(rows))
    }

    // MARK: Settings

    private func renderSettings(_ box: GPtr) {
        messages(box)
        let mode = UI.sensitive(UI.segmented(["One at a time", "Side by side"], selected: model.sideBySide ? 1 : 0) { [weak self] index in
            after(0) { self?.model.requestSideBySide(index == 1) }
        }, !model.isBusy)
        var modeRows: [GPtr] = []
        if model.sideBySide {
            modeRows.append(UI.switchRow("Send sign-ins to the profile that asked", subtitle: "Clatch handles claude:// links and passes each one to the right profile's Claude.",
                                         isOn: model.settings.routeSignIns) { [weak self] on in self?.model.setRouting(on) })
            modeRows.append(UI.switchRow("Reopen profiles after Claude updates", isOn: model.settings.watchdog) { [weak self] on in self?.model.setWatchdog(on) })
        }
        let modeCaption = model.sideBySide
            ? "Each profile runs its own Claude; the switcher brings it to the front or opens it. Cowork works for one profile at a time."
            : "One Claude, one account active at a time; the switcher closes Claude, swaps the account and reopens it."
        UI.append(box, UI.vbox(8, [UI.label("Profiles", ["heading"]), mode, UI.caption(modeCaption)] + (modeRows.isEmpty ? [] : [UI.list(modeRows)])))

        UI.append(box, shortcutSection())

        var general: [GPtr] = [
            UI.switchRow("Profile shortcuts in your apps and on the Desktop", subtitle: "One launcher per profile, kept in step with your profiles.",
                         isOn: model.settings.profileShortcuts) { [weak self] on in self?.model.setProfileShortcuts(on) },
        ]
        if !model.sideBySide {
            general.append(UI.switchRow("Reopen Claude after switching", isOn: model.settings.reopenClaude) { [weak self] on in self?.model.setReopenClaude(on) })
        }
        general += [
            UI.switchRow("Same MCP & tool settings for every account", isOn: model.settings.shareToolSettings) { [weak self] on in self?.model.setShareToolSettings(on) },
            UI.switchRow("Check for updates daily", isOn: model.settings.checkForUpdates) { [weak self] on in self?.model.setCheckForUpdates(on) },
            UI.switchRow("Open Clatch when I log in", isOn: model.startAtLogin) { [weak self] on in self?.model.setStartAtLogin(on) },
        ]
        UI.append(box, UI.list(general))

        UI.append(box, UI.list([
            actionRow("Check for Updates", "software-update-available-symbolic") { [weak self] in self?.model.checkForUpdates(force: true) },
            actionRow("Restore Sign-ins…", "document-revert-symbolic", enabled: !model.isBusy) { [weak self] in self?.model.show(.restoreBackups) },
            actionRow("Show Accounts Folder", "folder-symbolic") { [weak self] in self?.model.revealAccountsFolder() },
            actionRow("Open Claude", "applications-internet-symbolic", enabled: Claude.isInstalled && !model.isBusy) { [weak self] in self?.model.openActiveClaude() },
            actionRow("Open Log", "text-x-generic-symbolic") { [weak self] in self?.model.openLog() },
            actionRow("Clatch on GitHub", "web-browser-symbolic") { [weak self] in self?.model.openURI(AppModel.projectURL) },
        ]))

        UI.append(box, UI.caption(Claude.isInstalled
            ? "Claude Desktop \(Claude.version ?? "") at \(Claude.installFolder ?? "?"). Data: \(Claude.dataFolder.path)"
            : "Claude Desktop not found."))
        UI.append(box, UI.label("Clatch \(AppModel.version) · GPL-3.0-or-later · Issen Software Group", ["caption", "dim-label"], xalign: 0.5))
    }

    private func shortcutSection() -> GPtr {
        let accelerator = model.settings.hotKey
        let current = UI.css(UI.label(recording ? "Type a shortcut…" : accelerator.map(Self.acceleratorLabel) ?? "Off", ["heading"], wrap: false), "clatch-chip")
        let buttons = UI.hbox(6, [UI.expand(UI.align(current, h: GTK_ALIGN_START))])
        if recording {
            UI.append(buttons, UI.button("Cancel", ["pill"]) { [weak self] in self?.stopRecording() })
        } else {
            UI.append(buttons, UI.button("Change", ["pill"]) { [weak self] in self?.startRecording() })
            UI.append(buttons, UI.sensitive(UI.button("Default", ["pill"]) { [weak self] in self?.model.setHotKey(Settings.defaultHotKey) },
                                            accelerator != Settings.defaultHotKey))
            UI.append(buttons, UI.sensitive(UI.button("Off", ["pill"]) { [weak self] in self?.model.setHotKey(nil) }, accelerator != nil))
        }
        let section = UI.vbox(8, [UI.label("Profile switcher", ["heading"]), buttons,
                                  UI.caption("Hold the keys and tap the letter to move between profiles; let go to open the highlighted one.")])
        let status: String?
        switch model.shortcut.status {
        case .off: status = nil
        case .pending: status = "Waiting for your desktop to confirm the shortcut (it may show a dialog)."
        case .portal(let trigger): status = trigger.map { "Your desktop set it to \($0)." }
        case .gnome: status = "Set as a GNOME keyboard shortcut (Settings › Keyboard). It opens the highlighted profile after a short pause."
        case .unsupported: status = "Your desktop has no way for apps to set shortcuts. In its keyboard settings, add a shortcut that runs: clatch --switcher"
        case .failed(let reason): status = reason
        }
        if let message = recorderMessage ?? status { UI.append(section, UI.caption(message)) }
        if model.shortcut.usesPortal, (GlobalShortcut.portalVersion ?? 0) >= 2 {
            UI.append(section, UI.align(UI.button("Change in System Settings…", ["flat"]) { [weak self] in self?.model.shortcut.configure() }, h: GTK_ALIGN_START))
        }
        return section
    }

    static func acceleratorLabel(_ accelerator: String) -> String {
        var key: guint = 0
        var mods = GdkModifierType(rawValue: 0)
        gtk_accelerator_parse(accelerator, &key, &mods)
        return String(owned: gtk_accelerator_get_label(key, mods)) ?? accelerator
    }

    // MARK: - Keys

    private func startRecording() {
        recording = true
        recorderMessage = nil
        model.shortcut.set(nil) // so the old shortcut doesn't fire while typing the new one
        render(force: true)
    }

    private func stopRecording() {
        recording = false
        model.shortcut.set(model.settings.hotKey)
        render(force: true)
    }

    private func keyPressed(_ keyval: UInt32, _ rawState: UInt32) -> Bool {
        let state = rawState & gtk_accelerator_get_default_mod_mask().rawValue
        let control = state & GDK_CONTROL_MASK.rawValue != 0
        if recording {
            let modifierKeys: Set<UInt32> = [0xffe1, 0xffe2, 0xffe3, 0xffe4, 0xffe7, 0xffe8, 0xffe9, 0xffea, 0xffeb, 0xffec, 0xfe03]
            if modifierKeys.contains(keyval) { return true }
            if keyval == 0xff1b && state == 0 { stopRecording(); return true }
            let lower = gdk_keyval_to_lower(keyval)
            let isFunctionKey = lower >= 0xffbe && lower <= 0xffe0
            let meaningful = state & (GDK_CONTROL_MASK.rawValue | GDK_ALT_MASK.rawValue | GDK_SUPER_MASK.rawValue) != 0
            guard meaningful || isFunctionKey else {
                recorderMessage = "Include Ctrl, Alt or Super (function keys work alone)."
                render(force: true)
                return true
            }
            guard let name = String(owned: gtk_accelerator_name(lower, GdkModifierType(rawValue: state))) else { return true }
            recording = false
            recorderMessage = nil
            model.setHotKey(name)
            render(force: true)
            return true
        }
        // Ctrl+1…9 opens the nth profile, as on the Mac and Windows.
        if model.page == .accounts, control, keyval >= 0x31, keyval <= 0x39, !model.isBusy {
            let index = Int(keyval - 0x31)
            if index < model.state.accounts.count {
                model.open(model.state.accounts[index].id)
                close()
                return true
            }
        }
        if keyval == 0xff1b, model.page != .accounts { goBack(); return true }
        return false
    }
}
