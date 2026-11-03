// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import Foundation

/// Per-profile environment variables and launch flags: parsing what the user
/// types, and refusing what would break the profile.
public enum LaunchOptions {
    /// Flags Clatch manages itself and must not be overridden per profile.
    public static let reservedFlags = ["--user-data-dir"]

    /// Splits a flags line into arguments, honouring "double quotes".
    public static func parseArguments(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
                hasToken = true
            } else if character.isWhitespace && !inQuotes {
                if hasToken { result.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken { result.append(current) }
        return result
    }

    /// The reverse of parseArguments, for editing.
    public static func formatArguments(_ arguments: [String]) -> String {
        arguments.map { $0.contains(where: \.isWhitespace) || $0.isEmpty ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }

    /// Problems with a set of flags, empty when they are fine.
    public static func problems(arguments: [String]) -> [String] {
        arguments.compactMap { argument in
            let name = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            return reservedFlags.contains(name.lowercased()) ? "\(name) is set by Clatch for each profile." : nil
        }
    }

    /// "KEY=value" lines into a dictionary. Blank lines and # comments are skipped.
    public static func parseEnvironment(_ text: String) -> (values: [String: String], problems: [String]) {
        var values: [String: String] = [:]
        var problems: [String] = []
        for (number, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let equals = line.firstIndex(of: "=") else {
                problems.append("Line \(number + 1): use NAME=value.")
                continue
            }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...])
            guard isValidVariableName(key) else {
                problems.append("Line \(number + 1): \"\(key)\" is not a valid variable name.")
                continue
            }
            values[key] = value
        }
        return (values, problems)
    }

    public static func formatEnvironment(_ values: [String: String]) -> String {
        values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "\n")
    }

    public static func isValidVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || CharacterSet.alphanumerics.contains($0) } && name.allSatisfy(\.isASCII)
    }
}

/// claude:// links: which ones are sign-ins, without ever logging their contents
/// (a sign-in link carries a one-time code).
public enum ClaudeLink {
    /// Sign-in callbacks: claude://login/… (older builds) and claude://claude.ai/sso-callback….
    public static func isSignIn(_ link: String) -> Bool {
        let lower = link.lowercased()
        if lower.hasPrefix("claude://login/") { return true }
        guard lower.hasPrefix("claude://claude.ai/sso-callback") else { return false }
        let rest = lower.dropFirst("claude://claude.ai/sso-callback".count)
        return rest.isEmpty || rest.first == "/" || rest.first == "?" || rest.first == "#"
    }

    /// A safe description for the log: scheme and first path segment only.
    public static func describe(_ link: String) -> String {
        guard let url = URL(string: link), let scheme = url.scheme else { return "(unparseable link)" }
        let host = url.host ?? ""
        let first = url.pathComponents.dropFirst().first ?? ""
        return "\(scheme)://\(host)/\(first)…" + (isSignIn(link) ? " (sign-in)" : "")
    }
}

/// Version strings like "0.1.0", "0.1.0-beta.1", "v1.2".
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let numbers: [Int]
    /// Prerelease identifiers ("beta", "1"); empty for a final release.
    public let prerelease: [String]
    public let description: String

    public init?(_ text: String) {
        var body = text.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("v") || body.hasPrefix("V") { body.removeFirst() }
        let parts = body.split(separator: "-", maxSplits: 1)
        guard let core = parts.first else { return nil }
        let numbers = core.split(separator: ".").map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        self.numbers = numbers.compactMap { $0 }
        self.prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
        self.description = body
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for i in 0..<count {
            let a = i < lhs.numbers.count ? lhs.numbers[i] : 0
            let b = i < rhs.numbers.count ? rhs.numbers[i] : 0
            if a != b { return a < b }
        }
        // A final release ranks above its prereleases.
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            if let x = Int(a), let y = Int(b) { return x < y }
            if Int(a) != nil { return true }
            if Int(b) != nil { return false }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}
