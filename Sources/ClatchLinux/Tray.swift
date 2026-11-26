// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import CGtk
import Foundation

/// The notification area icon: a StatusNotifierItem with a dbusmenu menu,
/// the protocol KDE Plasma, Ubuntu's GNOME (AppIndicator extension), Xfce,
/// Cinnamon, MATE and others show in their tray. Implemented over GDBus
/// (libappindicator is GTK 3 only). Clicking the icon opens Clatch's window
/// where the desktop supports it; the menu has the profiles and actions.
///
/// It costs nothing at rest: the host reads the menu when it is opened.
@MainActor
final class Tray {
    struct Item {
        var label: String
        var checked: Bool? = nil
        var enabled = true
        var action: (@MainActor () -> Void)?
        static let separator = Item(label: "")
        var isSeparator: Bool { label.isEmpty && action == nil }
    }

    var onActivate: (() -> Void)?
    /// Builds the menu each time the host asks for it.
    var menu: () -> [Item] = { [] }
    private var items: [Item] = []
    private var revision: UInt32 = 1
    private var tooltip = "Clatch"
    private var busName: String?
    private(set) var isShown = false
    private let itemPath = "/StatusNotifierItem"
    private let menuPath = "/MenuBar"

    /// Exports the item and registers it with the tray host (now, and again whenever a host appears).
    func start() {
        guard DBus.session != nil else { return }
        let name = "org.kde.StatusNotifierItem-\(getpid())-1"
        busName = DBus.requestName(name) ? name : DBus.uniqueName
        _ = DBus.export(path: itemPath, xml: Self.itemXML, methods: { [weak self] method, _ in
            switch method {
            case "Activate", "SecondaryActivate": self?.onActivate?()
            case "ContextMenu": break
            default: break
            }
            return nil
        }, properties: { [weak self] name in self?.itemProperty(name) })
        _ = DBus.export(path: menuPath, xml: Self.menuXML, methods: { [weak self] method, parameters in
            self?.menuMethod(method, parameters)
        }, properties: { name in
            switch name {
            case "Version": V.uint32(3)
            case "TextDirection": V.string("ltr")
            case "Status": V.string("normal")
            case "IconThemePath": V.strings([])
            default: nil
            }
        })
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

    /// The menu changed (profiles, running state): hosts re-read it.
    func menuChanged() {
        revision += 1
        DBus.emit(menuPath, "com.canonical.dbusmenu", "LayoutUpdated", V.tuple([V.uint32(revision), V.int32(0)]))
    }

    // MARK: - StatusNotifierItem

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
        case "Menu": return V.objectPath(menuPath)
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

    // MARK: - dbusmenu

    private func menuMethod(_ method: String, _ parameters: OpaquePointer) -> OpaquePointer? {
        switch method {
        case "GetLayout":
            items = menu()
            let children = items.enumerated().map { V.variant(layout(id: Int32($0.offset + 1), $0.element)) }
            let root = V.tuple([V.int32(0), V.dict([("children-display", V.string("submenu"))]), V.array("v", children)])
            return V.tuple([V.uint32(revision), root])
        case "GetGroupProperties":
            if items.isEmpty { items = menu() }
            let ids = V.child(parameters, 0)
            var requested: [Int32] = (0..<V.count(ids)).map { V.getInt32(V.child(ids, $0)) }
            if requested.isEmpty { requested = Array(1...Int32(max(items.count, 1))) }
            let entries = requested.compactMap { id -> OpaquePointer? in
                guard id >= 1, Int(id) <= items.count else { return nil }
                return V.tuple([V.int32(id), properties(items[Int(id) - 1])])
            }
            return V.tuple([V.array("(ia{sv})", entries)])
        case "GetProperty":
            let id = Int(V.getInt32(V.child(parameters, 0)))
            let name = V.getString(V.child(parameters, 1))
            guard id >= 1, id <= items.count else { return V.tuple([V.variant(V.string(""))]) }
            let dict = V.readDict(properties(items[id - 1]))
            return V.tuple([V.variant(dict[name] ?? V.string(""))])
        case "Event":
            let id = Int(V.getInt32(V.child(parameters, 0)))
            if V.getString(V.child(parameters, 1)) == "clicked" { click(id) }
            return nil
        case "EventGroup":
            let events = V.child(parameters, 0)
            for i in 0..<V.count(events) {
                let event = V.child(events, i)
                if V.getString(V.child(event, 1)) == "clicked" { click(Int(V.getInt32(V.child(event, 0)))) }
            }
            return V.tuple([V.array("i", [])])
        case "AboutToShow":
            return V.tuple([V.bool(false)])
        case "AboutToShowGroup":
            return V.tuple([V.array("i", []), V.array("i", [])])
        default:
            return nil
        }
    }

    private func click(_ id: Int) {
        guard id >= 1, id <= items.count, items[id - 1].enabled, let action = items[id - 1].action else { return }
        // Let the host close its menu first.
        DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
    }

    private func layout(id: Int32, _ item: Item) -> OpaquePointer {
        V.tuple([V.int32(id), properties(item), V.array("v", [])])
    }

    private func properties(_ item: Item) -> OpaquePointer {
        if item.isSeparator { return V.dict([("type", V.string("separator"))]) }
        var entries: [(String, OpaquePointer)] = [("label", V.string(item.label.replacingOccurrences(of: "_", with: "__"))),
                                                  ("enabled", V.bool(item.enabled))]
        if let checked = item.checked {
            entries.append(("toggle-type", V.string("checkmark")))
            entries.append(("toggle-state", V.int32(checked ? 1 : 0)))
        }
        return V.dict(entries)
    }

    // MARK: - Interfaces

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

    private static let menuXML = """
    <node><interface name="com.canonical.dbusmenu">
      <property name="Version" type="u" access="read"/>
      <property name="TextDirection" type="s" access="read"/>
      <property name="Status" type="s" access="read"/>
      <property name="IconThemePath" type="as" access="read"/>
      <method name="GetLayout">
        <arg type="i" name="parentId" direction="in"/><arg type="i" name="recursionDepth" direction="in"/>
        <arg type="as" name="propertyNames" direction="in"/>
        <arg type="u" name="revision" direction="out"/><arg type="(ia{sv}av)" name="layout" direction="out"/>
      </method>
      <method name="GetGroupProperties">
        <arg type="ai" name="ids" direction="in"/><arg type="as" name="propertyNames" direction="in"/>
        <arg type="a(ia{sv})" name="properties" direction="out"/>
      </method>
      <method name="GetProperty">
        <arg type="i" name="id" direction="in"/><arg type="s" name="name" direction="in"/>
        <arg type="v" name="value" direction="out"/>
      </method>
      <method name="Event">
        <arg type="i" name="id" direction="in"/><arg type="s" name="eventId" direction="in"/>
        <arg type="v" name="data" direction="in"/><arg type="u" name="timestamp" direction="in"/>
      </method>
      <method name="EventGroup">
        <arg type="a(isvu)" name="events" direction="in"/><arg type="ai" name="idErrors" direction="out"/>
      </method>
      <method name="AboutToShow">
        <arg type="i" name="id" direction="in"/><arg type="b" name="needUpdate" direction="out"/>
      </method>
      <method name="AboutToShowGroup">
        <arg type="ai" name="ids" direction="in"/><arg type="ai" name="updatesNeeded" direction="out"/>
        <arg type="ai" name="idErrors" direction="out"/>
      </method>
      <signal name="ItemsPropertiesUpdated">
        <arg type="a(ia{sv})" name="updatedProps"/><arg type="a(ias)" name="removedProps"/>
      </signal>
      <signal name="LayoutUpdated"><arg type="u" name="revision"/><arg type="i" name="parent"/></signal>
      <signal name="ItemActivationRequested"><arg type="i" name="id"/><arg type="u" name="timestamp"/></signal>
    </interface></node>
    """
}
