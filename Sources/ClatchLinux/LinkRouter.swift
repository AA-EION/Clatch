// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import CGtk
import ClatchCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sign-in routing for profiles running side by side.
///
/// Signing in finishes in the browser, which opens a claude:// link. With
/// several Claudes open, that would reach whichever profile's Claude the
/// desktop starts. With routing on, Clatch is the default handler for
/// claude:// links (the x-scheme-handler/claude entry in mimeapps.list): a
/// sign-in goes to the profile waiting for one (a profile added in the last
/// 15 minutes), anything else to the Claude used most recently. Clatch hands
/// the link to that profile's Claude by starting Claude on the profile's
/// folder with the link; Claude passes it to the running instance.
///
/// Claude makes itself the handler again each time it starts, so while
/// routing is on Clatch watches mimeapps.list and takes the handler back,
/// remembering Claude's entry to restore when routing is turned off.
///
/// Link contents are never logged: a sign-in link carries a one-time code.
@MainActor
final class LinkRouter {
    static let mimeType = "x-scheme-handler/claude"
    private static let pendingWindow: TimeInterval = 15 * 60

    private(set) var pending: (id: UUID, until: Date)?
    private var watch: FolderWatch?
    private var settleTimer: GTimer?
    /// Called with the handler Clatch displaced, to keep for later.
    var onDisplacedHandler: ((String) -> Void)?

    func expectSignIn(for id: UUID) { pending = (id, Date().addingTimeInterval(Self.pendingWindow)) }
    func clearPending() { pending = nil }

    func target(for link: String, lastActive: UUID?, active: UUID?) -> UUID? {
        if ClaudeLink.isSignIn(link), let pending, pending.until > Date() { return pending.id }
        return lastActive ?? active
    }

    // MARK: - The handler

    /// The desktop entry that handles claude:// links now (e.g. com.anthropic.Claude.desktop).
    static var currentHandler: String? {
        guard let info = g_app_info_get_default_for_type(mimeType, 0) else { return nil }
        defer { g_object_unref(GPtr(info)) }
        return String(gstring: g_app_info_get_id(info))
    }

    static var clatchIsHandler: Bool { currentHandler == Desktop.desktopEntry }

    /// Makes the desktop entry with this id the default for claude:// links.
    @discardableResult
    static func setHandler(_ desktopID: String) -> Bool {
        guard let list = g_app_info_get_all_for_type(mimeType) else { return false }
        defer { g_list_free_full(list) { g_object_unref($0) } }
        var node: UnsafeMutablePointer<GList>? = list
        while let current = node {
            let info = OpaquePointer(current.pointee.data)
            if String(gstring: g_app_info_get_id(info)) == desktopID {
                var error: UnsafeMutablePointer<GError>?
                let ok = g_app_info_set_as_default_for_type(info, mimeType, &error) != 0
                if !ok { Log.write("Could not set the claude:// handler: \(error.flatMap { String(gstring: $0.pointee.message) } ?? "?")") }
                g_clear_error(&error)
                return ok
            }
            node = current.pointee.next
        }
        Log.write("No desktop entry \(desktopID) offers claude:// links")
        return false
    }

    /// Routing on: Clatch becomes the handler, and stays it while Claude takes it back.
    func enable() {
        if let current = Self.currentHandler, current != Desktop.desktopEntry { onDisplacedHandler?(current) }
        Self.setHandler(Desktop.desktopEntry)
        watch = FolderWatch(ClatchPaths.configHome) { [weak self] name in
            guard name == "mimeapps.list" else { return }
            self?.handlerMayHaveChanged()
        }
        Log.write("claude:// links now go to Clatch (routing on)")
    }

    /// Routing off: Claude's handler comes back.
    func disable(restoring backup: String?) {
        watch = nil
        settleTimer = nil
        if Self.clatchIsHandler { Self.setHandler(backup ?? Claude.desktopEntry) }
        Log.write("claude:// links go to Claude again")
    }

    private func handlerMayHaveChanged() {
        // Let the writer finish (it rewrites the whole file), then look.
        settleTimer = GTimer(0.4, repeats: false) { [weak self] in
            guard let self, self.watch != nil, let current = Self.currentHandler, current != Desktop.desktopEntry else { return }
            self.onDisplacedHandler?(current)
            Self.setHandler(Desktop.desktopEntry)
            Log.write("Claude made itself the claude:// handler again; routing restored")
        }
    }
}

/// Checks Clatch's GitHub releases at most once a day (when Clatch starts or
/// its window opens; no timer in between) and offers newer versions. It never
/// downloads or installs anything itself.
@MainActor
final class UpdateChecker {
    struct Update: Equatable {
        let version: String
        let page: URL
    }

    nonisolated static let releasesAPI = URL(string: "https://api.github.com/repos/AA-EION/Clatch/releases?per_page=15")!
    private var checking = false

    func check(currentVersion: String, completion: @escaping @MainActor (Result<Update?, Error>) -> Void) {
        guard !checking else { return }
        checking = true
        let request = Self.request(currentVersion)
        // URLSession's callback arrives off the main thread; hop back.
        // Ephemeral: no cookie store or cache folders in the user's home for one small request.
        let task = URLSession(configuration: .ephemeral).dataTask(with: request) { data, _, error in
            let result: Result<Update?, Error> = data.map { .success(Self.newest(in: $0, than: currentVersion)) }
                ?? .failure(error ?? URLError(.badServerResponse))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.checking = false
                    completion(result)
                }
            }
        }
        task.resume()
    }

    nonisolated private static func request(_ version: String) -> URLRequest {
        var request = URLRequest(url: releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Clatch/\(version)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        return request
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
