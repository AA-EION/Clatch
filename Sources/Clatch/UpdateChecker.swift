// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import Foundation
import ClatchCore

/// Checks Clatch's GitHub releases at most once a day (when the panel opens or
/// Clatch starts; no timer runs in between) and offers newer versions. It
/// never downloads or installs anything itself.
@MainActor
final class UpdateChecker {
    struct Update: Equatable {
        let version: String
        let page: URL
    }

    static let releasesAPI = URL(string: "https://api.github.com/repos/AA-EION/Clatch/releases?per_page=15")!
    private let defaults = UserDefaults.standard
    private let lastCheckKey = "lastUpdateCheck"
    private var checking = false

    /// Checks if the last check is more than a day old (or `force`).
    func checkIfDue(currentVersion: String, force: Bool = false, completion: @escaping (Result<Update?, Error>) -> Void) {
        if !force, let last = defaults.object(forKey: lastCheckKey) as? Date, Date().timeIntervalSince(last) < 24 * 3600 { return }
        guard !checking else { return }
        checking = true
        Task { @MainActor in
            defer { self.checking = false }
            do {
                var request = URLRequest(url: Self.releasesAPI)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("Clatch/\(currentVersion)", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 15
                let (data, _) = try await URLSession.shared.data(for: request)
                self.defaults.set(Date(), forKey: self.lastCheckKey)
                completion(.success(Self.newest(in: data, than: currentVersion)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// The newest published release above the current version. Prereleases
    /// only count while you are running a prerelease yourself.
    nonisolated static func newest(in data: Data, than current: String) -> Update? {
        guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let mine = AppVersion(current) else { return nil }
        let acceptPrerelease = !mine.prerelease.isEmpty
        let candidates = releases.compactMap { release -> (AppVersion, URL)? in
            guard (release["draft"] as? Bool) != true,
                  acceptPrerelease || (release["prerelease"] as? Bool) != true,
                  let tag = release["tag_name"] as? String, let version = AppVersion(tag),
                  let page = (release["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return (version, page)
        }
        guard let best = candidates.max(by: { $0.0 < $1.0 }), mine < best.0 else { return nil }
        return Update(version: best.0.description, page: best.1)
    }
}
