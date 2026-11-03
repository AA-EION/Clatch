// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import AppKit
import CoreServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?
    /// Links that arrived before the model was ready (Clatch started by a link).
    private var earlyURLs: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Registered before launch finishes, so the link that started Clatch
        // (a profile launcher, or a claude:// sign-in) is not lost.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:withReply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        self.model = model
        statusItem = StatusItemController(model: model)
        model.start()
        earlyURLs.forEach(model.handle(url:))
        earlyURLs.removeAll()
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text) else { return }
        if let model { model.handle(url: url) } else { earlyURLs.append(url) }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
