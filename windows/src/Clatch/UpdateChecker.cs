// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using System.Net.Http;
using System.Text.Json;
using Clatch.Core;

namespace Clatch;

/// <summary>
/// Checks Clatch's GitHub releases at most once a day (at start and when the
/// panel opens; no timer in between) and offers newer versions. It never
/// downloads or installs anything itself.
/// </summary>
internal static class UpdateChecker
{
    public sealed record Update(string Version, Uri Page);

    private static readonly Uri ReleasesApi = new("https://api.github.com/repos/AA-EION/Clatch/releases?per_page=15");

    public static bool IsDue(Settings settings) =>
        settings.LastUpdateCheck is not { } last || DateTimeOffset.Now - last > TimeSpan.FromHours(24);

    public static async Task<Update?> CheckAsync(string currentVersion)
    {
        using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd($"Clatch/{currentVersion}");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        var json = await client.GetStringAsync(ReleasesApi);
        return Newest(json, currentVersion);
    }

    /// <summary>The newest release above the current version; prereleases only while running one.</summary>
    public static Update? Newest(string json, string currentVersion)
    {
        if (AppVersion.Parse(currentVersion) is not { } mine) return null;
        var acceptPrerelease = mine.Prerelease.Length > 0;
        (AppVersion Version, Uri Page)? best = null;
        using var doc = JsonDocument.Parse(json);
        foreach (var release in doc.RootElement.EnumerateArray())
        {
            if (release.TryGetProperty("draft", out var draft) && draft.GetBoolean()) continue;
            if (!acceptPrerelease && release.TryGetProperty("prerelease", out var pre) && pre.GetBoolean()) continue;
            if (!release.TryGetProperty("tag_name", out var tag) || AppVersion.Parse(tag.GetString()) is not { } version) continue;
            if (!release.TryGetProperty("html_url", out var url) || !Uri.TryCreate(url.GetString(), UriKind.Absolute, out var page)) continue;
            if (best is null || version.CompareTo(best.Value.Version) > 0) best = (version, page);
        }
        return best is { } b && b.Version.CompareTo(mine) > 0 ? new Update(b.Version.Text, b.Page) : null;
    }
}
