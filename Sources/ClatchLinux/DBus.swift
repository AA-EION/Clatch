// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import CGtk
import Foundation

/// The session bus and a few GDBus helpers.
@MainActor
enum DBus {
    static let session: GPtr? = {
        var error: UnsafeMutablePointer<GError>?
        let connection = g_bus_get_sync(G_BUS_TYPE_SESSION, nil, &error)
        if connection == nil { Log.write("No D-Bus session bus: \(error.flatMap { String(gstring: $0.pointee.message) } ?? "?")") }
        g_clear_error(&error)
        return connection.map { GPtr($0) }
    }()

    static var uniqueName: String? {
        guard let session else { return nil }
        return String(gstring: g_dbus_connection_get_unique_name(session.t()))
    }

    /// A blocking call with a short timeout (local services answer in milliseconds). Returns the reply tuple.
    @discardableResult
    static func call(_ destination: String, _ path: String, _ interface: String, _ method: String,
                     _ parameters: OpaquePointer? = nil, timeout: Int32 = 2000) -> OpaquePointer? {
        guard let session else { return nil }
        var error: UnsafeMutablePointer<GError>?
        let reply = g_dbus_connection_call_sync(session.t(), destination, path, interface, method, parameters,
                                                nil, G_DBUS_CALL_FLAGS_NONE, timeout, nil, &error)
        if reply == nil, let message = error.flatMap({ String(gstring: $0.pointee.message) }) {
            lastError = message
        }
        g_clear_error(&error)
        return reply
    }

    static var lastError: String?

    /// A property of a remote object, unwrapped.
    static func property(_ destination: String, _ path: String, _ interface: String, _ name: String) -> OpaquePointer? {
        guard let reply = call(destination, path, "org.freedesktop.DBus.Properties", "Get",
                               V.tuple([V.string(interface), V.string(name)])) else { return nil }
        return V.unwrap(V.child(reply, 0))
    }

    static func emit(_ path: String, _ interface: String, _ signal: String, _ parameters: OpaquePointer?) {
        guard let session else { return }
        var error: UnsafeMutablePointer<GError>?
        g_dbus_connection_emit_signal(session.t(), nil, path, interface, signal, parameters, &error)
        g_clear_error(&error)
    }

    /// Subscribes to a signal; the handler gets (object path, parameters).
    @discardableResult
    static func subscribe(sender: String?, interface: String, member: String?, path: String?,
                          _ handler: @escaping @MainActor (String, OpaquePointer) -> Void) -> UInt32 {
        guard let session else { return 0 }
        typealias Fn = @MainActor (String, OpaquePointer) -> Void
        let callback: GDBusSignalCallback = { _, _, path, _, _, parameters, data in
            let fn = Unmanaged<Box<Fn>>.fromOpaque(data!).takeUnretainedValue().value
            let p = String(gstring: path) ?? ""
            nonisolated(unsafe) let params = parameters!
            MainActor.assumeIsolated { fn(p, params) }
        }
        let box = Unmanaged.passRetained(Box(handler as Fn)).toOpaque()
        return g_dbus_connection_signal_subscribe(session.t(), sender, interface, member, path, nil,
                                                  G_DBUS_SIGNAL_FLAGS_NONE, callback, box) { data in
            Unmanaged<AnyObject>.fromOpaque(data!).release()
        }
    }

    static func unsubscribe(_ id: UInt32) {
        guard let session, id != 0 else { return }
        g_dbus_connection_signal_unsubscribe(session.t(), guint(id))
    }

    /// Exports an object: `xml` is the interface's introspection XML.
    /// `methods(name, parameters) -> reply tuple (or nil for an empty reply)`, `properties(name) -> value`.
    static func export(path: String, xml: String,
                       methods: @escaping @MainActor (String, OpaquePointer) -> OpaquePointer?,
                       properties: @escaping @MainActor (String) -> OpaquePointer?) -> Bool {
        guard let session else { return false }
        var error: UnsafeMutablePointer<GError>?
        guard let node = g_dbus_node_info_new_for_xml(xml, &error), let iface = node.pointee.interfaces?[0] else {
            Log.write("Bad D-Bus interface XML: \(error.flatMap { String(gstring: $0.pointee.message) } ?? "?")")
            g_clear_error(&error)
            return false
        }
        let handlers = ExportedObject(methods: methods, properties: properties)
        var vtable = GDBusInterfaceVTable()
        vtable.method_call = { _, _, _, _, method, parameters, invocation, data in
            let object = Unmanaged<ExportedObject>.fromOpaque(data!).takeUnretainedValue()
            let name = String(gstring: method) ?? ""
            nonisolated(unsafe) let params = parameters!
            nonisolated(unsafe) let invocation = invocation
            MainActor.assumeIsolated {
                let reply = object.methods(name, params)
                g_dbus_method_invocation_return_value(invocation, reply)
            }
        }
        vtable.get_property = { _, _, _, _, property, _, data in
            let object = Unmanaged<ExportedObject>.fromOpaque(data!).takeUnretainedValue()
            let name = String(gstring: property) ?? ""
            // Returned as a raw pointer: OpaquePointer is not Sendable across the isolation hop.
            let bits = MainActor.assumeIsolated { object.properties(name).map { Int(bitPattern: UnsafeMutableRawPointer($0)) } ?? 0 }
            return OpaquePointer(bitPattern: bits)
        }
        // GDBus copies the vtable; the handlers live as long as the export (for the app's lifetime).
        let id = g_dbus_connection_register_object(session.t(), path, iface, &vtable,
                                                   Unmanaged.passRetained(handlers).toOpaque(), nil, &error)
        if id == 0 { Log.write("Could not export \(path): \(error.flatMap { String(gstring: $0.pointee.message) } ?? "?")") }
        g_clear_error(&error)
        return id != 0
    }

    final class ExportedObject {
        let methods: @MainActor (String, OpaquePointer) -> OpaquePointer?
        let properties: @MainActor (String) -> OpaquePointer?
        init(methods: @escaping @MainActor (String, OpaquePointer) -> OpaquePointer?,
             properties: @escaping @MainActor (String) -> OpaquePointer?) {
            self.methods = methods
            self.properties = properties
        }
    }

    /// Asks the bus for a well-known name. Returns true when it is ours.
    static func requestName(_ name: String) -> Bool {
        guard let reply = call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                               V.tuple([V.string(name), V.uint32(4)])) else { return false } // DBUS_NAME_FLAG_DO_NOT_QUEUE
        let result = V.getUInt32(V.child(reply, 0))
        return result == 1 || result == 4 // primary owner / already owner
    }

    /// Calls `appeared` each time a name gets an owner (and once now if it has one).
    static func watchName(_ name: String, appeared: @escaping @MainActor () -> Void) {
        subscribe(sender: "org.freedesktop.DBus", interface: "org.freedesktop.DBus", member: "NameOwnerChanged",
                  path: "/org/freedesktop/DBus") { _, parameters in
            guard V.getString(V.child(parameters, 0)) == name, !V.getString(V.child(parameters, 2)).isEmpty else { return }
            appeared()
        }
        if let reply = call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
                            V.tuple([V.string(name)])),
           g_variant_get_boolean(V.child(reply, 0)) != 0 {
            appeared()
        }
    }
}
