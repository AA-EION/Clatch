// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import Darwin
import Foundation

/// The command-line arguments another process of the same user was started
/// with (sysctl KERN_PROCARGS2: no special permission needed). Side by side,
/// this is how Clatch tells which profile each running Claude belongs to.
public enum ProcessArguments {
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

    /// The value of --user-data-dir ("--user-data-dir=X" or "--user-data-dir X").
    public static func userDataDir(in arguments: [String]) -> String? {
        for (i, argument) in arguments.enumerated() {
            if argument.hasPrefix("--user-data-dir=") {
                let value = String(argument.dropFirst("--user-data-dir=".count))
                return trimmed(value)
            }
            if argument == "--user-data-dir", i + 1 < arguments.count {
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
