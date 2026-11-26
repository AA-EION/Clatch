// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import ClatchCore
import Foundation

/// A small diagnostic log at `$XDG_STATE_HOME/Clatch/clatch.log` (normally
/// `~/.local/state/Clatch/clatch.log`, kept under 256 KB). Records what Clatch
/// did and any error, never account data or link contents.
enum Log {
    static let fileURL: URL = {
        ClatchPaths.xdg("XDG_STATE_HOME", ".local/state").appendingPathComponent("Clatch/clatch.log")
    }()

    private static let queue = DispatchQueue(label: "clatch.log")

    /// Also echoed to stderr (useful when run from a terminal, and in CI).
    static func write(_ message: String) {
        let line = "\(timestamp()) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > 256 * 1024 {
                let old = fileURL.appendingPathExtension("old")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: fileURL, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                _ = try? handle.seekToEnd()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: fileURL)
            }
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
