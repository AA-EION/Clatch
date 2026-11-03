// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using System.Text;
using System.Text.Json;

namespace Clatch.Core;

/// <summary>Per-profile environment variables and launch flags.</summary>
public static class LaunchOptions
{
    /// <summary>Flags Clatch sets itself for each profile.</summary>
    public static readonly string[] ReservedFlags = ["--user-data-dir"];

    /// <summary>Splits a flags line into arguments, honouring "double quotes".</summary>
    public static List<string> ParseArguments(string line)
    {
        var result = new List<string>();
        var current = new StringBuilder();
        bool inQuotes = false, hasToken = false;
        foreach (var c in line)
        {
            if (c == '"') { inQuotes = !inQuotes; hasToken = true; }
            else if (char.IsWhiteSpace(c) && !inQuotes)
            {
                if (hasToken) result.Add(current.ToString());
                current.Clear();
                hasToken = false;
            }
            else { current.Append(c); hasToken = true; }
        }
        if (hasToken) result.Add(current.ToString());
        return result;
    }

    public static string FormatArguments(IEnumerable<string> arguments) =>
        string.Join(" ", arguments.Select(a => a.Length == 0 || a.Any(char.IsWhiteSpace) ? $"\"{a}\"" : a));

    public static List<string> Problems(IEnumerable<string> arguments) =>
        arguments.Select(a => a.Split('=', 2)[0])
                 .Where(name => ReservedFlags.Contains(name, StringComparer.OrdinalIgnoreCase))
                 .Select(name => $"{name} is set by Clatch for each profile.")
                 .ToList();

    /// <summary>"KEY=value" lines; blank lines and # comments are skipped.</summary>
    public static (Dictionary<string, string> Values, List<string> Problems) ParseEnvironment(string text)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var problems = new List<string>();
        var lines = text.Replace("\r\n", "\n").Split('\n');
        for (var i = 0; i < lines.Length; i++)
        {
            var line = lines[i].Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            var equals = line.IndexOf('=');
            if (equals < 0) { problems.Add($"Line {i + 1}: use NAME=value."); continue; }
            var key = line[..equals].Trim();
            if (!IsValidVariableName(key)) { problems.Add($"Line {i + 1}: \"{key}\" is not a valid variable name."); continue; }
            values[key] = line[(equals + 1)..];
        }
        return (values, problems);
    }

    public static string FormatEnvironment(IReadOnlyDictionary<string, string> values) =>
        string.Join("\n", values.Keys.OrderBy(k => k, StringComparer.OrdinalIgnoreCase).Select(k => $"{k}={values[k]}"));

    public static bool IsValidVariableName(string name) =>
        name.Length > 0 && (char.IsAsciiLetter(name[0]) || name[0] == '_') && name.All(c => char.IsAsciiLetterOrDigit(c) || c == '_');

    /// <summary>A Windows command line from separate arguments (CommandLineToArgvW rules).</summary>
    public static string QuoteForCommandLine(string argument)
    {
        if (argument.Length > 0 && !argument.Any(c => char.IsWhiteSpace(c) || c == '"')) return argument;
        var sb = new StringBuilder("\"");
        var backslashes = 0;
        foreach (var c in argument)
        {
            if (c == '\\') { backslashes++; continue; }
            if (c == '"') { sb.Append('\\', backslashes * 2 + 1).Append('"'); }
            else { sb.Append('\\', backslashes).Append(c); }
            backslashes = 0;
        }
        return sb.Append('\\', backslashes * 2).Append('"').ToString();
    }
}

/// <summary>claude:// links, without ever logging their contents (a sign-in link carries a one-time code).</summary>
public static class ClaudeLink
{
    public static bool IsClaudeLink(string? link) =>
        link is not null && link.StartsWith("claude://", StringComparison.OrdinalIgnoreCase) && !link.Any(char.IsControl);

    /// <summary>Sign-in callbacks: claude://login/… (older builds) and claude://claude.ai/sso-callback….</summary>
    public static bool IsSignIn(string link)
    {
        var lower = link.ToLowerInvariant();
        if (lower.StartsWith("claude://login/")) return true;
        const string callback = "claude://claude.ai/sso-callback";
        if (!lower.StartsWith(callback)) return false;
        var rest = lower[callback.Length..];
        return rest.Length == 0 || rest[0] is '/' or '?' or '#';
    }

    public static string Describe(string link)
    {
        if (!Uri.TryCreate(link, UriKind.Absolute, out var uri)) return "(unparseable link)";
        var first = uri.Segments.Length > 1 ? uri.Segments[1].TrimEnd('/') : "";
        return $"{uri.Scheme}://{uri.Host}/{first}…" + (IsSignIn(link) ? " (sign-in)" : "");
    }
}

/// <summary>Version strings like "0.1.0", "0.1.0-beta.1", "v1.2".</summary>
public sealed class AppVersion : IComparable<AppVersion>
{
    public int[] Numbers { get; }
    public string[] Prerelease { get; }
    public string Text { get; }

    private AppVersion(int[] numbers, string[] prerelease, string text) { Numbers = numbers; Prerelease = prerelease; Text = text; }

    public static AppVersion? Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var body = text.Trim();
        if (body.StartsWith('v') || body.StartsWith('V')) body = body[1..];
        var parts = body.Split('-', 2);
        var numbers = new List<int>();
        foreach (var piece in parts[0].Split('.'))
        {
            if (!int.TryParse(piece, out var n)) return null;
            numbers.Add(n);
        }
        return new AppVersion([.. numbers], parts.Length > 1 ? parts[1].Split('.') : [], body);
    }

    public int CompareTo(AppVersion? other)
    {
        if (other is null) return 1;
        for (var i = 0; i < Math.Max(Numbers.Length, other.Numbers.Length); i++)
        {
            var a = i < Numbers.Length ? Numbers[i] : 0;
            var b = i < other.Numbers.Length ? other.Numbers[i] : 0;
            if (a != b) return a.CompareTo(b);
        }
        if ((Prerelease.Length == 0) != (other.Prerelease.Length == 0)) return Prerelease.Length == 0 ? 1 : -1;
        for (var i = 0; i < Math.Min(Prerelease.Length, other.Prerelease.Length); i++)
        {
            string a = Prerelease[i], b = other.Prerelease[i];
            if (a == b) continue;
            var aNum = int.TryParse(a, out var x);
            var bNum = int.TryParse(b, out var y);
            if (aNum && bNum) return x.CompareTo(y);
            if (aNum) return -1;
            if (bNum) return 1;
            return string.CompareOrdinal(a, b);
        }
        return Prerelease.Length.CompareTo(other.Prerelease.Length);
    }

    public override string ToString() => Text;
}

/// <summary>A chat from Claude Desktop's Code tab (see <see cref="CodeSessions"/>).</summary>
public sealed record CodeSession(string File, string AccountId, string OrganisationId, string Title, string Folder, DateTime Updated)
{
    public string Id => Path.GetFileName(File);
}

public sealed class CodeSessionException(string message) : Exception(message);

/// <summary>
/// Claude Desktop keeps one small file per Code-tab chat inside the profile:
/// claude-code-sessions\&lt;account&gt;\&lt;organisation&gt;\local_&lt;id&gt;.json. The
/// conversation itself is in Claude Code's own history, shared by every profile
/// on this PC, so copying that file into another profile (under the account and
/// organisation it is signed in to) makes the chat appear there. Regular
/// claude.ai chats are stored on Anthropic's servers and cannot be moved.
/// </summary>
public static class CodeSessions
{
    public const string FolderName = "claude-code-sessions";

    /// <param name="roots">The profile's session roots (the Store version can keep part of a
    /// profile's files in its package's LocalCache under the same relative path).</param>
    public static List<CodeSession> Discover(IEnumerable<string> roots)
    {
        var found = new Dictionary<string, CodeSession>(StringComparer.OrdinalIgnoreCase);
        foreach (var root in roots)
            foreach (var account in SafeDirectories(root))
                foreach (var organisation in SafeDirectories(account))
                    foreach (var file in SafeFiles(organisation, "local_*.json"))
                    {
                        var session = Read(file, Path.GetFileName(account), Path.GetFileName(organisation));
                        if (found.TryGetValue(session.Id, out var existing) && existing.Updated >= session.Updated) continue;
                        found[session.Id] = session;
                    }
        return [.. found.Values.OrderByDescending(s => s.Updated)];
    }

    public static string Copy(CodeSession session, IEnumerable<string> targetRoots, string profileName)
    {
        var target = targetRoots.SelectMany(SafeDirectories).SelectMany(SafeDirectories)
            .OrderByDescending(LastUsed).FirstOrDefault()
            ?? throw new CodeSessionException($"Open the Code tab once in “{profileName}” first, so Claude creates its chat folder there.");
        var destination = Path.Combine(target, Path.GetFileName(session.File));
        if (File.Exists(destination))
        {
            if (File.ReadAllBytes(destination).AsSpan().SequenceEqual(File.ReadAllBytes(session.File)))
                throw new CodeSessionException("That chat is already in this profile.");
        }
        File.Copy(session.File, destination, overwrite: true);
        return destination;
    }

    internal static CodeSession Read(string file, string account, string organisation)
    {
        string title = "", folder = "";
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllBytes(file));
            if (doc.RootElement.ValueKind == JsonValueKind.Object)
            {
                title = First(doc.RootElement, "title", "name", "summary", "customTitle", "displayName") ?? "";
                var path = First(doc.RootElement, "cwd", "workingDirectory", "projectPath", "folder", "path") ?? "";
                folder = path.Contains("scratch-workspaces", StringComparison.OrdinalIgnoreCase) ? "(no folder)"
                       : path.Length == 0 ? "" : Path.GetFileName(path.Replace('/', '\\').TrimEnd('\\'));
            }
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException) { }
        if (title.Length == 0)
        {
            var id = Path.GetFileNameWithoutExtension(file)["local_".Length..];
            title = "Chat " + id[..Math.Min(8, id.Length)];
        }
        return new CodeSession(file, account, organisation, title, folder, System.IO.File.GetLastWriteTime(file));
    }

    private static string? First(JsonElement element, params string[] keys)
    {
        foreach (var key in keys)
            if (element.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(value.GetString()))
                return value.GetString()!.Trim();
        return null;
    }

    private static DateTime LastUsed(string folder)
    {
        var files = SafeFiles(folder, "*").Select(System.IO.File.GetLastWriteTimeUtc).ToList();
        return files.Count > 0 ? files.Max() : Directory.GetLastWriteTimeUtc(folder);
    }

    private static IEnumerable<string> SafeDirectories(string folder)
    {
        try { return Directory.Exists(folder) ? Directory.GetDirectories(folder) : []; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return []; }
    }

    private static IEnumerable<string> SafeFiles(string folder, string pattern)
    {
        try { return Directory.Exists(folder) ? Directory.GetFiles(folder, pattern) : []; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return []; }
    }
}
