// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import AppKit
import SwiftUI

/// The menu bar icon and its panel.
///
/// The panel's SwiftUI content only exists while the panel is open: it is
/// created when the icon is clicked and released when the panel closes. While
/// closed, Clatch draws nothing and runs nothing, it is a status item and a
/// registered hot key.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private var popover: NSPopover?

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Clatch: switch Claude accounts"
        }
        statusItem.isVisible = true
        updateIcon(for: .idle)

        model.onPhaseChange = { [weak self] phase in self?.updateIcon(for: phase) }
        model.requestPanel = { [weak self] in self?.showPanel() }
    }

    private func updateIcon(for phase: SwitchPhase) {
        let name = phase.isBusy ? "arrow.triangle.2.circlepath" : "person.2.circle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Clatch")
            ?? NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "Clatch")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = false
    }

    @objc private func togglePanel(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
        } else {
            showPanel()
        }
    }

    func showPanel() {
        guard let button = statusItem.button else { return }
        if let popover, popover.isShown { return }

        model.panelWillOpen()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hosting = NSHostingController(rootView: PanelView(model: model))
        popover.contentViewController = hosting
        self.popover = popover

        // An agent app has to activate itself so text fields in the panel get keys.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        // Tear the view hierarchy down: nothing renders while the panel is closed.
        popover?.contentViewController = nil
        popover = nil
        model.panelDidClose()
    }
}
