// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import CGtk
import Foundation

/// The profile switcher's global shortcut, the way each desktop allows it:
///
/// * The GlobalShortcuts portal (xdg-desktop-portal; GNOME 48+, KDE Plasma
///   5.27+, Hyprland and others), on Wayland and X11. The desktop asks the user
///   once to confirm the shortcut, and tells Clatch both when it is pressed and
///   when it is released, which is what the switcher needs.
/// * GNOME without the portal (Ubuntu 22.04/24.04, Debian 12): a GNOME custom
///   keyboard shortcut that runs `clatch --switch-next`. GNOME reports only the
///   press, so the switcher opens the highlighted profile after a short pause.
/// * Elsewhere: the user can bind `clatch --switch-next` in the desktop's own settings.
@MainActor
final class GlobalShortcut {
    enum Status: Equatable {
        case off
        /// Bound through the portal; `trigger` is how the desktop describes the keys.
        case portal(trigger: String?)
        /// A GNOME custom shortcut.
        case gnome(binding: String)
        /// Waiting for the desktop (the confirmation dialog may be open).
        case pending
        case unsupported
        case failed(String)
    }

    private(set) var status: Status = .off
    /// Pressed: (activation token for focusing the switcher, if the desktop gave one).
    var onPress: ((String?) -> Void)?
    var onRelease: (() -> Void)?
    var onStatusChange: (() -> Void)?

    private var session: String?
    private var subscriptions: [UInt32] = []
    private let shortcutID = "switch-profile"

    static let portalName = "org.freedesktop.portal.Desktop"
    static let portalPath = "/org/freedesktop/portal/desktop"
    static let portalInterface = "org.freedesktop.portal.GlobalShortcuts"

    /// The portal's GlobalShortcuts version, or nil when the desktop has none.
    static var portalVersion: UInt32? {
        DBus.property(portalName, portalPath, portalInterface, "version").map { g_variant_get_uint32($0) }
    }

    var usesPortal: Bool { if case .portal = status { true } else { status == .pending } }

    /// Binds `accelerator` (GTK syntax, "<Control><Alt><Super>c"), or turns the shortcut off with nil.
    func set(_ accelerator: String?) {
        teardown()
        guard let accelerator else {
            removeGnomeBinding()
            update(.off)
            return
        }
        if Self.portalVersion != nil {
            removeGnomeBinding()
            bindWithPortal(accelerator)
        } else if GnomeShortcut.isAvailable {
            update(GnomeShortcut.set(binding: accelerator, command: "\(LinuxShell.quote(Desktop.clatchCommand)) --switch-next")
                   ? .gnome(binding: accelerator) : .failed("GNOME did not accept the shortcut."))
        } else {
            update(.unsupported)
        }
    }

    /// Opens the desktop's own dialog to change the shortcut (portal version 2).
    func configure() {
        guard let session, (Self.portalVersion ?? 0) >= 2 else { return }
        DBus.call(Self.portalName, Self.portalPath, Self.portalInterface, "ConfigureShortcuts",
                  V.tuple([V.objectPath(session), V.string(""), V.dict([])]))
    }

    private func update(_ new: Status) {
        status = new
        Log.write("Shortcut: \(new)")
        onStatusChange?()
    }

    private func removeGnomeBinding() {
        if GnomeShortcut.isAvailable { GnomeShortcut.remove() }
    }

    // MARK: - Portal

    private func bindWithPortal(_ accelerator: String) {
        update(.pending)
        // Lets the portal tell which app this is (xdg-desktop-portal 1.19+), so the
        // user's choice is kept for Clatch. Older portals don't have it; that's fine.
        DBus.call(Self.portalName, Self.portalPath, "org.freedesktop.host.portal.Registry", "Register",
                  V.tuple([V.string(Desktop.appID), V.dict([])]))

        subscriptions.append(DBus.subscribe(sender: Self.portalName, interface: Self.portalInterface, member: "Activated",
                                            path: Self.portalPath) { [weak self] _, parameters in
            guard let self, V.getString(V.child(parameters, 0)) == self.session,
                  V.getString(V.child(parameters, 1)) == self.shortcutID else { return }
            let options = V.readDict(V.child(parameters, 3))
            self.onPress?(options["activation_token"].map(V.getString))
        })
        subscriptions.append(DBus.subscribe(sender: Self.portalName, interface: Self.portalInterface, member: "Deactivated",
                                            path: Self.portalPath) { [weak self] _, parameters in
            guard let self, V.getString(V.child(parameters, 0)) == self.session,
                  V.getString(V.child(parameters, 1)) == self.shortcutID else { return }
            self.onRelease?()
        })

        request("CreateSession", { token in
            V.tuple([V.dict([("handle_token", V.string(token)), ("session_handle_token", V.string("clatch\(UInt32.random(in: 1...UInt32.max))"))])])
        }) { [weak self] results in
            guard let self else { return }
            guard let handle = results?["session_handle"].map(V.getString) else {
                return self.update(.failed("The desktop did not open a shortcuts session."))
            }
            self.session = handle
            self.bind(accelerator)
        }
    }

    private func bind(_ accelerator: String) {
        guard let session else { return }
        let trigger = PortalTrigger.from(accelerator: accelerator)
        let shortcut = V.tuple([V.string(shortcutID), V.dict([
            ("description", V.string("Open the Claude profile switcher")),
            ("preferred_trigger", V.string(trigger)),
        ])])
        request("BindShortcuts", { token in
            V.tuple([V.objectPath(session), V.array("(sa{sv})", [shortcut]), V.string(""), V.dict([("handle_token", V.string(token))])])
        }) { [weak self] results in
            guard let self else { return }
            guard let results else { return self.update(.failed("The shortcut was not confirmed.")) }
            var description: String?
            if let list = results["shortcuts"] {
                for i in 0..<V.count(list) {
                    let entry = V.child(list, i)
                    if V.getString(V.child(entry, 0)) == self.shortcutID {
                        description = V.readDict(V.child(entry, 1))["trigger_description"].map(V.getString)
                    }
                }
            }
            self.update(.portal(trigger: description?.isEmpty == false ? description : nil))
        }
    }

    /// A portal request: subscribes to its Response first (the request path is
    /// predictable from the token), then calls the method.
    private func request(_ method: String, _ parameters: (String) -> OpaquePointer,
                         _ done: @escaping @MainActor ([String: OpaquePointer]?) -> Void) {
        guard let unique = DBus.uniqueName else { return done(nil) }
        let token = "clatch\(UInt32.random(in: 1...UInt32.max))"
        let sender = unique.dropFirst().replacingOccurrences(of: ".", with: "_")
        let path = "/org/freedesktop/portal/desktop/request/\(sender)/\(token)"
        var subscription: UInt32 = 0
        subscription = DBus.subscribe(sender: Self.portalName, interface: "org.freedesktop.portal.Request",
                                      member: "Response", path: path) { _, parameters in
            DBus.unsubscribe(subscription)
            let response = V.getUInt32(V.child(parameters, 0))
            done(response == 0 ? V.readDict(V.child(parameters, 1)) : nil)
        }
        if DBus.call(Self.portalName, Self.portalPath, Self.portalInterface, method, parameters(token), timeout: 10000) == nil {
            DBus.unsubscribe(subscription)
            done(nil)
        }
    }

    private func teardown() {
        subscriptions.forEach(DBus.unsubscribe)
        subscriptions = []
        if let session {
            DBus.call(Self.portalName, session, "org.freedesktop.portal.Session", "Close")
        }
        session = nil
    }
}

/// The portal's trigger syntax (XDG shortcuts spec): "CTRL+ALT+LOGO+c".
enum PortalTrigger {
    static func from(accelerator: String) -> String {
        var key = accelerator, parts: [String] = []
        let names: [(String, String)] = [("<Control>", "CTRL"), ("<Primary>", "CTRL"), ("<Alt>", "ALT"),
                                         ("<Shift>", "SHIFT"), ("<Super>", "LOGO"), ("<Meta>", "LOGO")]
        for (gtk, portal) in names where key.contains(gtk) {
            key = key.replacingOccurrences(of: gtk, with: "")
            if !parts.contains(portal) { parts.append(portal) }
        }
        return (parts + [key]).joined(separator: "+")
    }
}

/// A GNOME custom keyboard shortcut (Settings › Keyboard › Custom Shortcuts),
/// written through GSettings like GNOME Settings itself does.
@MainActor
enum GnomeShortcut {
    static let schema = "org.gnome.settings-daemon.plugins.media-keys"
    static let entrySchema = "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding"
    static let path = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/clatch/"

    static var isAvailable: Bool {
        guard let source = g_settings_schema_source_get_default(),
              let found = g_settings_schema_source_lookup(source, entrySchema, 1) else { return false }
        g_settings_schema_unref(found)
        return true
    }

    static func set(binding: String, command: String) -> Bool {
        guard let entry = g_settings_new_with_path(entrySchema, path), let list = g_settings_new(schema) else { return false }
        defer { g_object_unref(g(entry)); g_object_unref(g(list)) }
        g_settings_set_string(entry, "name", "Clatch: profile switcher")
        g_settings_set_string(entry, "command", command)
        g_settings_set_string(entry, "binding", binding)
        var paths = strv(list, "custom-keybindings")
        if !paths.contains(path) { paths.append(path) }
        setStrv(list, "custom-keybindings", paths)
        g_settings_sync()
        return true
    }

    static func remove() {
        guard let list = g_settings_new(schema) else { return }
        defer { g_object_unref(g(list)) }
        let paths = strv(list, "custom-keybindings")
        guard paths.contains(path) else { return }
        setStrv(list, "custom-keybindings", paths.filter { $0 != path })
        if let entry = g_settings_new_with_path(entrySchema, path) {
            for key in ["name", "command", "binding"] { g_settings_reset(entry, key) }
            g_object_unref(g(entry))
        }
        g_settings_sync()
    }

    private static func strv(_ settings: UnsafeMutablePointer<GSettings>, _ key: String) -> [String] {
        guard let values = g_settings_get_strv(settings, key) else { return [] }
        defer { g_strfreev(values) }
        var result: [String] = []
        var i = 0
        while let item = values[i] { result.append(String(cString: item)); i += 1 }
        return result
    }

    private static func setStrv(_ settings: UnsafeMutablePointer<GSettings>, _ key: String, _ values: [String]) {
        var cStrings: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) } + [nil]
        defer { cStrings.forEach { free($0) } }
        cStrings.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
                _ = g_settings_set_strv(settings, key, $0)
            }
        }
    }
}

enum LinuxShell {
    /// Single-quotes an argument for a shell command line (GNOME runs custom shortcuts through one).
    static func quote(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) } ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
