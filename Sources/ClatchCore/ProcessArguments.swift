// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// The command-line arguments another process of the same user was started
/// with (macOS: sysctl KERN_PROCARGS2; Linux: /proc/<pid>/cmdline; no special
/// permission needed). Side by side, this is how Clatch tells which profile
/// each running Claude belongs to.
public enum ProcessArguments {
    #if os(Linux)
    public static func of(_ pid: pid_t) -> [String]? {
        guard let data = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline"), !data.isEmpty else { return nil }
        var parts = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if parts.last == "" { parts.removeLast() }
        return parts
    }
    #else
    public static func of(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        // The executable path, then padding NULs, then argv[0…].
        while index < size && buffer[index] != 0 { index += 1 }
        while index < size && buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc && index < size {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
    #endif

    /// The value of --user-data-dir ("--user-data-dir=X" or "--user-data-dir X").
    public static func userDataDir(in arguments: [String]) -> String? {
        value(of: "--user-data-dir", in: arguments)
    }

    /// The value of a switch ("--name=X" or "--name X").
    public static func value(of name: String, in arguments: [String]) -> String? {
        for (i, argument) in arguments.enumerated() {
            if argument.hasPrefix(name + "=") {
                return trimmed(String(argument.dropFirst(name.count + 1)))
            }
            if argument == name, i + 1 < arguments.count {
                return trimmed(arguments[i + 1])
            }
        }
        return nil
    }

    private static func trimmed(_ value: String) -> String? {
        var v = value.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
        while v.count > 1 && v.hasSuffix("/") { v.removeLast() }
        return v.isEmpty ? nil : v
    }
}
