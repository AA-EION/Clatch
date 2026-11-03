// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

namespace Clatch.Core;

/// <summary>
/// Claude Desktop's live data folder and Clatch's own folder.
/// </summary>
/// <remarks>
/// Claude Desktop is an Electron app. Everything that makes up a sign-in lives
/// in one user-data folder: <c>Cookies</c>, <c>Local Storage</c>,
/// <c>IndexedDB</c>, and <c>config.json</c> with the encrypted token cache.
/// On Windows the encryption key is in <c>Local State</c> inside the same
/// folder (protected with DPAPI for the Windows user), so each copy of the
/// folder is self-contained.
/// </remarks>
public sealed record ClatchPaths(string ClaudeData, string ClatchRoot)
{
    public string StateFile => Path.Combine(ClatchRoot, "accounts.json");
    public string JournalFile => Path.Combine(ClatchRoot, "switch-journal.json");
    /// <summary>The standard folder holding every account that is not active.</summary>
    public string AccountsFolder => Path.Combine(ClatchRoot, "Accounts");
    public string Stash(Guid id) => Path.Combine(AccountsFolder, id.ToString("D"), "Claude");
}
