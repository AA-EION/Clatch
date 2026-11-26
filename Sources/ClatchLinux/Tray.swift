// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import CGtk
import Foundation

/// The notification area icon: a StatusNotifierItem, the protocol KDE
/// Plasma, Ubuntu's GNOME (AppIndicator extension), Xfce, Cinnamon, MATE and
/// others show in their tray. Implemented over GDBus (libappindicator is GTK 3 only).
///
/// Like the menu bar icon on macOS, a click (left or right) opens Clatch's own
/// window. The item deliberately offers no D-Bus menu ("/NO_DBUSMENU"): with
/// one, desktops show their own generic menu instead of activating the app.
@MainActor
final class Tray {
    var onActivate: (() -> Void)?
    private var tooltip = "Clatch"
    private var busName: String?
    private(set) var isShown = false
    private let itemPath = "/StatusNotifierItem"

    /// Exports the item and registers it with the tray host (now, and again whenever a host appears).
    func start() {
        guard DBus.session != nil else { return }
        let name = "org.kde.StatusNotifierItem-\(getpid())-1"
        busName = DBus.requestName(name) ? name : DBus.uniqueName
        _ = DBus.export(path: itemPath, xml: Self.itemXML, methods: { [weak self] method, _ in
            switch method {
            case "Activate", "SecondaryActivate", "ContextMenu":
                // After the host's own click handling has finished.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onActivate?() } }
            default: break
            }
            return nil
        }, properties: { [weak self] name in self?.itemProperty(name) })
        DBus.watchName("org.kde.StatusNotifierWatcher") { [weak self] in self?.register() }
    }

    private func register() {
        guard let busName else { return }
        let ok = DBus.call("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
                           "RegisterStatusNotifierItem", V.tuple([V.string(busName)])) != nil
        isShown = ok
        Log.write("Notification area icon registered=\(ok)")
    }

    /// Is any tray host running (a desktop that shows StatusNotifierItems)?
    static var hostAvailable: Bool {
        guard let value = DBus.property("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
                                        "org.kde.StatusNotifierWatcher", "IsStatusNotifierHostRegistered") else { return false }
        return g_variant_get_boolean(value) != 0
    }

    func setTooltip(_ text: String) {
        guard text != tooltip else { return }
        tooltip = text
        DBus.emit(itemPath, "org.kde.StatusNotifierItem", "NewToolTip", nil)
        DBus.emit(itemPath, "org.kde.StatusNotifierItem", "NewTitle", nil)
    }

    private func itemProperty(_ name: String) -> OpaquePointer? {
        switch name {
        case "Category": return V.string("ApplicationStatus")
        case "Id": return V.string("clatch")
        case "Title": return V.string(tooltip)
        case "Status": return V.string("Active")
        case "WindowId": return V.int32(0)
        case "IconName": return V.string(Desktop.appID)
        case "IconThemePath": return V.string(Self.iconThemePath)
        case "IconPixmap", "OverlayIconPixmap", "AttentionIconPixmap": return V.array("(iiay)", [])
        case "OverlayIconName", "AttentionIconName", "AttentionMovieName": return V.string("")
        case "ToolTip":
            return V.tuple([V.string(Desktop.appID), V.array("(iiay)", []), V.string("Clatch"), V.string(tooltip)])
        case "ItemIsMenu": return V.bool(false)
        case "Menu": return V.objectPath("/NO_DBUSMENU")
        default: return nil
        }
    }

    /// Where the icon theme can find Clatch's icon when it is not installed system-wide (running from a build).
    static var iconThemePath: String {
        let installed = "/usr/share/icons/hicolor/scalable/apps/\(Desktop.appID).svg"
        if FileManager.default.fileExists(atPath: installed) { return "" }
        return URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("icons").path
    }

    private static let itemXML = """
    <node><interface name="org.kde.StatusNotifierItem">
      <property name="Category" type="s" access="read"/>
      <property name="Id" type="s" access="read"/>
      <property name="Title" type="s" access="read"/>
      <property name="Status" type="s" access="read"/>
      <property name="WindowId" type="i" access="read"/>
      <property name="IconName" type="s" access="read"/>
      <property name="IconThemePath" type="s" access="read"/>
      <property name="IconPixmap" type="a(iiay)" access="read"/>
      <property name="OverlayIconName" type="s" access="read"/>
      <property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
      <property name="AttentionIconName" type="s" access="read"/>
      <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
      <property name="AttentionMovieName" type="s" access="read"/>
      <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
      <property name="ItemIsMenu" type="b" access="read"/>
      <property name="Menu" type="o" access="read"/>
      <method name="ContextMenu"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
      <method name="Activate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
      <method name="SecondaryActivate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
      <method name="Scroll"><arg name="delta" type="i" direction="in"/><arg name="orientation" type="s" direction="in"/></method>
      <signal name="NewTitle"/><signal name="NewIcon"/><signal name="NewAttentionIcon"/><signal name="NewOverlayIcon"/>
      <signal name="NewToolTip"/><signal name="NewStatus"><arg name="status" type="s"/></signal>
    </interface></node>
    """
}
