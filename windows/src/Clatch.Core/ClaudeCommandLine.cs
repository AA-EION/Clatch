// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using System.Text.RegularExpressions;

namespace Clatch.Core;

/// <summary>
/// Reading Claude's real data folder from how it was started.
/// </summary>
/// <remarks>
/// Electron apps can be told where to keep their data with
/// <c>--user-data-dir</c>, and pass it on to every helper process. The
/// Microsoft Store version of Claude does exactly that: its data lives in
/// <c>%LOCALAPPDATA%\Claude-Data\claude_&lt;publisher id&gt;</c>, excluded from
/// Windows' package redirection, and the old location keeps only a
/// <c>.user-data-left.*</c> marker file. Reading the switch from the running
/// processes follows Claude wherever it decides to keep its data.
/// </remarks>
public static partial class ClaudeCommandLine
{
    [GeneratedRegex("""--user-data-dir=(?:"(?<q>[^"]+)"|(?<u>[^\s"]+))""", RegexOptions.IgnoreCase)]
    private static partial Regex UserDataDirPattern();

    /// <summary>The value of --user-data-dir, or null.</summary>
    public static string? UserDataDir(string? commandLine)
    {
        if (string.IsNullOrEmpty(commandLine)) return null;
        var match = UserDataDirPattern().Match(commandLine);
        if (!match.Success) return null;
        var value = match.Groups["q"].Success ? match.Groups["q"].Value : match.Groups["u"].Value;
        return value.Trim().TrimEnd('\\', '/');
    }

    /// <summary>
    /// Whether a folder holds an Electron profile (rather than, say, only a
    /// marker saying the data moved elsewhere).
    /// </summary>
    public static bool LooksLikeUserData(string folder)
    {
        if (!Directory.Exists(folder)) return false;
        string[] markers = ["Local State", "Cookies", Path.Combine("Network", "Cookies"), "config.json", "Preferences"];
        return markers.Any(m => File.Exists(Path.Combine(folder, m)));
    }

    /// <summary>A ".user-data-left.*" marker: Claude moved its data away from this folder.</summary>
    public static bool HasMovedAwayMarker(string folder) =>
        Directory.Exists(folder) && Directory.EnumerateFiles(folder, ".user-data-left*").Any();
}
