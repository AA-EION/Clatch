// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import CGtk
import Foundation
import Glibc

// MARK: - The main queue inside GLib's main loop

// libdispatch's hooks for a run loop that hosts the main queue (the ones
// CoreFoundation uses). With them, GLib's loop also runs DispatchQueue.main
// and therefore @MainActor code, woken by an eventfd: no polling.
@_silgen_name("_dispatch_get_main_queue_handle_4CF")
private func dispatchMainQueueHandle() -> Int32
@_silgen_name("_dispatch_main_queue_callback_4CF")
private func dispatchMainQueueCallback(_ message: UnsafeMutableRawPointer?)

enum MainLoop {
    /// Call once, on the main thread, before the GTK application runs.
    static func attachMainQueue() {
        let fd = dispatchMainQueueHandle()
        guard fd >= 0 else { return }
        g_unix_fd_add_full(G_PRIORITY_DEFAULT, fd, G_IO_IN, { fd, _, _ in
            var value: UInt64 = 0
            _ = read(fd, &value, MemoryLayout<UInt64>.size)
            dispatchMainQueueCallback(nil)
            return gboolean(1) // G_SOURCE_CONTINUE
        }, nil, nil)
    }
}

// MARK: - Pointers

/// GTK objects are passed around as raw pointers and converted at each call:
/// `.t()` for a C type whose struct Swift sees, `.op` for an opaque one.
typealias GPtr = UnsafeMutableRawPointer

extension UnsafeMutableRawPointer {
    @inline(__always) func t<T>() -> UnsafeMutablePointer<T> { assumingMemoryBound(to: T.self) }
    @inline(__always) func t() -> OpaquePointer { OpaquePointer(self) }
    @inline(__always) var op: OpaquePointer { OpaquePointer(self) }
}

/// Any pointer GTK returns, as a GPtr.
@inline(__always) func g<T>(_ p: UnsafeMutablePointer<T>?) -> GPtr { GPtr(p!) }
@inline(__always) func g(_ p: OpaquePointer?) -> GPtr { GPtr(p!) }

// MARK: - Closures as GLib callbacks

/// Holds a Swift closure for a C callback; released by GLib's destroy notify.
final class Box<T> {
    let value: T
    init(_ value: T) { self.value = value }
}

private func retained<T>(_ value: T) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(Box(value)).toOpaque()
}

private func unbox<T>(_ pointer: UnsafeMutableRawPointer?, as _: T.Type) -> T {
    Unmanaged<Box<T>>.fromOpaque(pointer!).takeUnretainedValue().value
}

private let releaseAction: GClosureNotify = { data, _ in
    guard let data else { return }
    Unmanaged<AnyObject>.fromOpaque(data).release()
}

private let releaseNotify: GDestroyNotify = { data in
    guard let data else { return }
    Unmanaged<AnyObject>.fromOpaque(data).release()
}

typealias Action = @MainActor () -> Void

/// Connects a signal whose handler takes only (instance, data): clicked, activate, toggled, changed, destroy.
@discardableResult
func onSignal(_ instance: UnsafeMutableRawPointer?, _ signal: String, _ action: @escaping Action) -> UInt {
    let handler: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
        let fn = unbox(data, as: Action.self)
        MainActor.assumeIsolated { fn() }
    }
    return UInt(clatch_connect(instance, signal, unsafeBitCast(handler, to: GCallback.self), retained(action), releaseAction))
}

/// A signal with one extra argument, e.g. notify::<property> (GParamSpec).
@discardableResult
func onSignal1(_ instance: UnsafeMutableRawPointer?, _ signal: String,
               _ action: @escaping @MainActor (UnsafeMutableRawPointer?) -> Void) -> UInt {
    typealias Fn = @MainActor (UnsafeMutableRawPointer?) -> Void
    let handler: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, arg, data in
        let fn = unbox(data, as: Fn.self)
        nonisolated(unsafe) let arg = arg
        MainActor.assumeIsolated { fn(arg) }
    }
    return UInt(clatch_connect(instance, signal, unsafeBitCast(handler, to: GCallback.self), retained(action), releaseAction))
}

/// A signal that returns gboolean and takes (instance, data): close-request.
@discardableResult
func onSignalBool(_ instance: UnsafeMutableRawPointer?, _ signal: String, _ action: @escaping @MainActor () -> Bool) -> UInt {
    typealias Fn = @MainActor () -> Bool
    let handler: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> gboolean = { _, data in
        let fn = unbox(data, as: Fn.self)
        return MainActor.assumeIsolated { fn() } ? 1 : 0
    }
    return UInt(clatch_connect(instance, signal, unsafeBitCast(handler, to: GCallback.self), retained(action), releaseAction))
}

/// GtkEventControllerKey's key-pressed / key-released: (controller, keyval, keycode, state, data).
@discardableResult
func onKey(_ controller: GPtr, released: Bool,
           _ action: @escaping @MainActor (_ keyval: UInt32, _ state: UInt32) -> Bool) -> UInt {
    typealias Fn = @MainActor (UInt32, UInt32) -> Bool
    let pressed: @convention(c) (UnsafeMutableRawPointer?, guint, guint, GdkModifierType, UnsafeMutableRawPointer?) -> gboolean = { _, keyval, _, state, data in
        let fn = unbox(data, as: Fn.self)
        return MainActor.assumeIsolated { fn(keyval, state.rawValue) } ? 1 : 0
    }
    let releasedHandler: @convention(c) (UnsafeMutableRawPointer?, guint, guint, GdkModifierType, UnsafeMutableRawPointer?) -> Void = { _, keyval, _, state, data in
        let fn = unbox(data, as: Fn.self)
        _ = MainActor.assumeIsolated { fn(keyval, state.rawValue) }
    }
    let callback = released ? unsafeBitCast(releasedHandler, to: GCallback.self) : unsafeBitCast(pressed, to: GCallback.self)
    return UInt(clatch_connect(controller, released ? "key-released" : "key-pressed",
                               callback, retained(action), releaseAction))
}

/// GFileMonitor's "changed": (monitor, file, other_file, event, data). Reports the names involved:
/// for a rename (how most programs save: a temporary file renamed over the real one) both the
/// old and the new name, so a watcher sees "mimeapps.list" whichever way it was written.
@discardableResult
func onFileChanged(_ monitor: GPtr, _ action: @escaping @MainActor (String?) -> Void) -> UInt {
    typealias Fn = @MainActor (String?) -> Void
    let handler: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?) -> Void = { _, file, other, _, data in
        let fn = unbox(data, as: Fn.self)
        let names = [file, other].compactMap { $0.flatMap { String(owned: g_file_get_basename($0.t())) } }
        MainActor.assumeIsolated {
            if names.isEmpty { fn(nil) }
            for name in Set(names) { fn(name) }
        }
    }
    return UInt(clatch_connect(monitor, "changed", unsafeBitCast(handler, to: GCallback.self), retained(action), releaseAction))
}

/// Watches a folder (inotify through GIO). Lives as long as this object.
@MainActor
final class FolderWatch {
    private let monitor: GPtr?

    init?(_ folder: URL, _ changed: @escaping @MainActor (String?) -> Void) {
        let file = g_file_new_for_path(folder.path)
        defer { g_object_unref(file.map { GPtr($0) }) }
        var error: UnsafeMutablePointer<GError>?
        guard let monitor = g_file_monitor_directory(file, G_FILE_MONITOR_WATCH_MOVES, nil, &error) else {
            g_clear_error(&error)
            return nil
        }
        self.monitor = GPtr(monitor)
        onFileChanged(GPtr(monitor), changed)
    }

    isolated deinit {
        if let monitor {
            g_file_monitor_cancel(monitor.t())
            g_object_unref(monitor)
        }
    }
}

// MARK: - Timers, idle callbacks and file descriptor watches

/// A GLib timeout. Exists only while something is waiting; cancel() or deinit removes it.
@MainActor
final class GTimer {
    /// Shared with the callback, so a one-shot timer knows it has already run.
    private final class State { var source: guint = 0 }
    private let state = State()

    /// Fires every `interval` seconds (or once, if `repeats` is false).
    init(_ interval: TimeInterval, repeats: Bool, _ action: @escaping @MainActor () -> Void) {
        typealias Fn = @MainActor () -> Bool
        let state = self.state
        let body: Fn = {
            if !repeats { state.source = 0 } // GLib removes a one-shot source itself
            action()
            return repeats
        }
        state.source = g_timeout_add_full(G_PRIORITY_DEFAULT, guint(max(1, interval * 1000)), { data in
            let fn = unbox(data, as: Fn.self)
            return MainActor.assumeIsolated { fn() } ? 1 : 0
        }, retained(body), releaseNotify)
    }

    func cancel() {
        if state.source != 0 { g_source_remove(state.source) }
        state.source = 0
    }

    var isActive: Bool { state.source != 0 }

    isolated deinit { cancel() }
}

/// Runs `action` once after `delay`, with nothing to keep alive.
func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
    typealias Fn = @MainActor () -> Void
    g_timeout_add_full(G_PRIORITY_DEFAULT, guint(max(1, delay * 1000)), { data in
        let fn = unbox(data, as: Fn.self)
        MainActor.assumeIsolated { fn() }
        return 0
    }, retained(action as Fn), releaseNotify)
}

/// Calls `action` once when the file descriptor becomes readable (e.g. a pidfd when its process exits).
@MainActor
final class FDWatch {
    private final class State { var source: guint = 0 }
    private let state = State()
    private let fd: Int32

    init(fd: Int32, _ action: @escaping @MainActor () -> Void) {
        self.fd = fd
        typealias Fn = @MainActor () -> Void
        let state = self.state
        let body: Fn = {
            state.source = 0 // GLib removes the source when it returns G_SOURCE_REMOVE
            action()
        }
        state.source = g_unix_fd_add_full(G_PRIORITY_DEFAULT, fd, G_IO_IN, { _, _, data in
            let fn = unbox(data, as: Fn.self)
            MainActor.assumeIsolated { fn() }
            return 0 // G_SOURCE_REMOVE: once is enough
        }, retained(body), releaseNotify)
    }

    func cancel() {
        if state.source != 0 { g_source_remove(state.source) }
        state.source = 0
    }

    isolated deinit {
        cancel()
        close(fd)
    }
}

// MARK: - Strings

extension String {
    /// A Swift string from a C string that GLib owns (nil stays nil).
    init?(gstring: UnsafePointer<CChar>?) {
        guard let gstring else { return nil }
        self.init(cString: gstring)
    }

    /// A Swift string from a C string that we own, freed with g_free.
    init?(owned: UnsafeMutablePointer<CChar>?) {
        guard let owned else { return nil }
        self.init(cString: owned)
        g_free(owned)
    }
}

// MARK: - GVariant

/// Small helpers to build and read GVariants without g_variant_new's varargs.
enum V {
    static func string(_ s: String) -> OpaquePointer { g_variant_new_string(s) }
    static func objectPath(_ s: String) -> OpaquePointer { g_variant_new_object_path(s) }
    static func int32(_ v: Int32) -> OpaquePointer { g_variant_new_int32(v) }
    static func uint32(_ v: UInt32) -> OpaquePointer { g_variant_new_uint32(v) }
    static func bool(_ v: Bool) -> OpaquePointer { g_variant_new_boolean(v ? 1 : 0) }
    static func variant(_ v: OpaquePointer) -> OpaquePointer { g_variant_new_variant(v) }

    static func tuple(_ items: [OpaquePointer]) -> OpaquePointer {
        var items: [OpaquePointer?] = items
        return items.withUnsafeMutableBufferPointer { g_variant_new_tuple($0.baseAddress, gsize($0.count)) }
    }

    /// An array of `type` (e.g. "s", "(sa{sv})", "v"); works when empty.
    static func array(_ type: String, _ items: [OpaquePointer]) -> OpaquePointer {
        let elementType = g_variant_type_new(type)
        defer { g_variant_type_free(elementType) }
        var items: [OpaquePointer?] = items
        return items.withUnsafeMutableBufferPointer { g_variant_new_array(elementType, $0.baseAddress, gsize($0.count)) }
    }

    /// An a{sv} dictionary.
    static func dict(_ entries: [(String, OpaquePointer)]) -> OpaquePointer {
        array("{sv}", entries.map { g_variant_new_dict_entry(string($0.0), variant($0.1)) })
    }

    static func strings(_ values: [String]) -> OpaquePointer { array("s", values.map(string)) }

    // Reading

    static func child(_ v: OpaquePointer, _ index: Int) -> OpaquePointer { g_variant_get_child_value(v, gsize(index)) }
    static func count(_ v: OpaquePointer) -> Int { Int(g_variant_n_children(v)) }

    static func getString(_ v: OpaquePointer) -> String {
        String(cString: g_variant_get_string(v, nil))
    }

    static func getInt32(_ v: OpaquePointer) -> Int32 { g_variant_get_int32(v) }
    static func getUInt32(_ v: OpaquePointer) -> UInt32 { g_variant_get_uint32(v) }

    static func type(_ v: OpaquePointer) -> String { String(cString: g_variant_get_type_string(v)) }

    /// Unwraps a "v" to its contents.
    static func unwrap(_ v: OpaquePointer) -> OpaquePointer {
        type(v) == "v" ? g_variant_get_variant(v) : v
    }

    /// Reads an a{sv} into Swift values (only the types Clatch needs).
    static func readDict(_ v: OpaquePointer) -> [String: OpaquePointer] {
        var result: [String: OpaquePointer] = [:]
        for i in 0..<count(v) {
            let entry = child(v, i)
            let key = getString(child(entry, 0))
            result[key] = unwrap(child(entry, 1))
        }
        return result
    }
}
