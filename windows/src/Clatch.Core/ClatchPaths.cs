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
public sealed record ClatchPaths(string ClaudeData, string ClatchRoot, IReadOnlyList<DataFolder>? ExtraData = null,
                                 string? ProfileRoot = null)
{
    /// <summary>Key of the main data folder (its stash keeps the original "Claude" name).</summary>
    public const string MainKey = "Claude";

    /// <summary>
    /// Every folder that belongs to the active account and moves with it: the
    /// main data folder first, then any extra one (the Microsoft Store version
    /// of Claude also reads %APPDATA%\Claude, see <see cref="DataFolder"/>).
    /// </summary>
    public IReadOnlyList<DataFolder> Folders =>
        [new DataFolder(MainKey, ClaudeData), .. ExtraData ?? []];

    /// <summary>A stable description, to notice when detection changes.</summary>
    public string Signature => string.Join("|", Folders.Select(f => $"{f.Key}={f.Live}")).ToUpperInvariant();

    /// <summary>
    /// Where an inactive account keeps the folder with this key. With a
    /// <see cref="ProfileRoot"/> (Windows: %LOCALAPPDATA%), each profile's
    /// main folder sits directly in it as "Clatch-&lt;id&gt;": Claude's Cowork VM
    /// service only looks for a profile's files directly under %LOCALAPPDATA%,
    /// so in a nested folder Cowork would not start. Side by side, this folder
    /// is what that profile's Claude runs from.
    /// </summary>
    public string Stash(Guid id, string key)
    {
        if (ProfileRoot is null) return LegacyStash(id, key);
        var name = "Clatch-" + id.ToString("N")[..12];
        return key == MainKey ? Path.Combine(ProfileRoot, name) : Path.Combine(ProfileRoot, $"{name}-{key}");
    }

    /// <summary>The layout before <see cref="ProfileRoot"/>: Accounts\&lt;id&gt;\&lt;key&gt;.</summary>
    public string LegacyStash(Guid id, string key) => Path.Combine(AccountsFolder, id.ToString("D"), key);

    public string StateFile => Path.Combine(ClatchRoot, "accounts.json");
    public string JournalFile => Path.Combine(ClatchRoot, "switch-journal.json");
    /// <summary>The standard folder holding every account that is not active.</summary>
    public string AccountsFolder => Path.Combine(ClatchRoot, "Accounts");
    public string Stash(Guid id) => Stash(id, MainKey);
}

/// <summary>One live folder of Claude's data and the name its parked copy gets.</summary>
/// <remarks>
/// The Microsoft Store (MSIX) version of Claude gets a merged view of two
/// folders: its private copy under %LOCALAPPDATA%\Packages\…\LocalCache\Roaming\Claude
/// is read first, and %APPDATA%\Claude fills in whatever the private copy
/// lacks. If only the private copy moved, Claude would fall back to a sign-in
/// left in %APPDATA%\Claude, so both belong to the account.
/// </remarks>
public sealed record DataFolder(string Key, string Live);
