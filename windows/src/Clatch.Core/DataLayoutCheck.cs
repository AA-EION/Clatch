// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

namespace Clatch.Core;

/// <summary>
/// Fail-safe against Claude Desktop changing where or how it stores its data.
/// Checked before every switch; when the folder is not what Clatch expects,
/// the switch stops and the user decides whether to continue anyway.
/// </summary>
public sealed record DataLayoutCheck(IReadOnlyList<string> Problems)
{
    public bool IsRecognized => Problems.Count == 0;

    /// <summary>Files Chromium/Electron always creates (newer Chromium keeps cookies under Network\).</summary>
    internal static readonly string[] ElectronMarkers = ["Local State", "Cookies", Path.Combine("Network", "Cookies"), "Preferences"];
    /// <summary>Files Claude itself writes.</summary>
    internal static readonly string[] ClaudeMarkers = ["config.json", "claude_desktop_config.json"];

    /// <param name="claudeData">Claude's live data folder.</param>
    /// <param name="claudeHasRunSinceLastSwitch">Claude was open on this account, so the folder must exist.</param>
    /// <param name="alternatives">Other folders a future Claude might use; mentioned when they exist.</param>
    public static DataLayoutCheck Inspect(string claudeData, bool claudeHasRunSinceLastSwitch,
                                          IEnumerable<string>? alternatives = null)
    {
        var problems = new List<string>();
        if (File.Exists(claudeData))
        {
            problems.Add($"{claudeData} is no longer a folder.");
        }
        else if (Directory.Exists(claudeData))
        {
            var contents = Directory.EnumerateFileSystemEntries(claudeData).Select(Path.GetFileName).ToList();
            var onlyShared = contents.All(n => n is not null && (AccountStore.DefaultSharedItems.Contains(n) || n.StartsWith('.')));
            if (!onlyShared)
            {
                bool Has(string name) => File.Exists(Path.Combine(claudeData, name)) || Directory.Exists(Path.Combine(claudeData, name));
                if (!ElectronMarkers.Any(Has))
                    problems.Add($"Claude's data folder no longer contains the browser storage files Clatch expects ({string.Join(", ", ElectronMarkers)}).");
                if (!ClaudeMarkers.Any(Has))
                    problems.Add($"Claude's data folder no longer contains {string.Join(" or ", ClaudeMarkers)}.");
            }
        }
        else if (claudeHasRunSinceLastSwitch)
        {
            problems.Add($"Claude was used, but its data folder was not found at {claudeData}.");
        }

        if (problems.Count > 0 && alternatives is not null)
        {
            var found = alternatives.Where(Directory.Exists).ToList();
            if (found.Count > 0) problems.Add($"Claude may now keep its data in: {string.Join(", ", found)}.");
        }
        return new DataLayoutCheck(problems);
    }
}
