// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import AppKit
import ClatchCore
import CoreServices

/// Sign-in routing for profiles running side by side.
///
/// Signing in to Claude finishes in the browser, which hands a claude:// link
/// back to "Claude". With several Claudes open, macOS picks one, often the
/// wrong profile. With routing on, Clatch is the handler for claude:// links:
/// a sign-in goes to the profile waiting for one (a profile just added), else
/// to the Claude used most recently; any other link goes to the Claude used
/// most recently. Clatch hands the link to that exact Claude with the
/// standard "open URL" Apple Event, so macOS asks once for permission to
/// control Claude (System Settings › Privacy & Security › Automation).
///
/// Link contents are never logged: a sign-in link carries a one-time code.
@MainActor
final class LinkRouter {
    private static let pendingWindow: TimeInterval = 15 * 60

    /// Profile waiting for a sign-in, and until when.
    private(set) var pending: (id: UUID, until: Date)?
    /// The profile whose Claude was in front most recently.
    var lastActiveProfile: UUID?

    /// A profile was just started at its sign-in screen.
    func expectSignIn(for id: UUID) {
        pending = (id, Date().addingTimeInterval(Self.pendingWindow))
    }

    func clearPending() { pending = nil }

    /// Which profile a link should go to.
    func target(for link: String, active: UUID?) -> UUID? {
        if ClaudeLink.isSignIn(link), let pending, pending.until > Date() {
            return pending.id
        }
        return lastActiveProfile ?? active
    }

    // MARK: - Delivering

    /// Gives a link to one specific running Claude. Returns an error message, or nil.
    nonisolated static func deliver(_ link: String, toProcess pid: pid_t) -> String? {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                                           targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: link), forKeyword: keyDirectObject)
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 10)
            return nil
        } catch {
            let code = (error as NSError).code
            if code == Int(errAEEventNotPermitted) {
                return "Clatch is not allowed to hand links to Claude. Allow it in System Settings › Privacy & Security › Automation."
            }
            return "Could not hand the link to Claude (error \(code))."
        }
    }

    /// Asks macOS for permission to send Claude links (shows the prompt once). Blocking: call off the main thread.
    nonisolated static func requestPermission(pid: pid_t) -> Bool {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        guard let desc = target.aeDesc else { return false }
        let status = AEDeterminePermissionToAutomateTarget(desc, AEEventClass(kInternetEventClass), AEEventID(kAEGetURL), true)
        return status == noErr
    }

    /// Gives a link to Claude the ordinary way (routing off): macOS picks the Claude.
    static func forwardToClaude(_ url: URL) {
        guard let claude = ClaudeApp.url else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: claude, configuration: configuration) { _, _ in }
    }

    // MARK: - Default handler

    /// Makes Clatch (on) or Claude (off) the app for claude:// links.
    static func setHandler(clatch: Bool) {
        let bundleID = clatch ? (Bundle.main.bundleIdentifier ?? "com.issen.clatch") : ClaudeApp.bundleIdentifier
        let appURL = clatch ? Bundle.main.bundleURL : ClaudeApp.url
        if #available(macOS 12.0, *), let appURL {
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "claude") { error in
                if let error { Log.write("Could not change the claude:// handler: \(error.localizedDescription)") }
            }
        } else {
            LSSetDefaultHandlerForURLScheme("claude" as CFString, bundleID as CFString)
        }
        Log.write("claude:// links now go to \(clatch ? "Clatch (routing on)" : "Claude")")
    }

    /// Whether Clatch is the app for claude:// links right now.
    static var clatchIsHandler: Bool {
        guard let url = URL(string: "claude://"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }
}
