// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import Darwin
import Foundation

/// Finds processes whose executable lives under given folders.
///
/// Claude Desktop is more than its main process: Electron helpers (GPU,
/// renderer, network) live inside `Claude.app`, and local Claude Code sessions
/// run binaries stored in Claude's data folder. They usually exit together with
/// the app, but Clatch waits until none is left before it touches any file.
///
/// Uses `proc_listallpids`/`proc_pidpath`, which work for the user's own
/// processes without any special permission.
public enum ProcessScanner {
    public static func pids(withExecutableUnder folders: [URL]) -> [pid_t] {
        let prefixes = folders.map { $0.standardizedFileURL.resolvingSymlinksInPath().path + "/" }
        guard !prefixes.isEmpty else { return [] }

        var capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            Int(proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size)))
        }
        capacity = min(max(count, 0), pids.count)

        let me = getpid()
        var matches: [pid_t] = []
        // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN; the macro is not imported into Swift.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(capacity) where pid > 0 && pid != me {
            let length = buffer.withUnsafeMutableBufferPointer { pointer in
                proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
            }
            guard length > 0 else { continue }
            let path = String(cString: buffer)
            if prefixes.contains(where: { path.hasPrefix($0) }) {
                matches.append(pid)
            }
        }
        return matches
    }
}
