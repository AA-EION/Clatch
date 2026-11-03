// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using System.Text.Json;
using Clatch.Core;
using Clatch.Interop;

namespace Clatch;

/// <summary>
/// "Claude - &lt;profile&gt;" shortcuts on the Desktop and in the Start menu
/// (Clatch Profiles folder), with the profile's badged icon. They run
/// "Clatch.exe --launch &lt;id&gt;", and Clatch does what the current mode means:
/// one at a time it switches Claude to that profile; side by side it brings
/// that profile's Claude to the front or starts it. Each shortcut carries the
/// profile's AppUserModelID, so a pinned one shares its taskbar button with
/// that profile's Claude windows.
///
/// Created, renamed and removed as profiles change, and only while the
/// setting is on. Clatch records the shortcuts it made (shortcuts.json) and
/// never touches any other file.
/// </summary>
internal static class ProfileShortcuts
{
    private static string RecordFile => Path.Combine(Settings.Folder, "shortcuts.json");
    public static string StartMenuFolder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Clatch Profiles");
    private static string Desktop => Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);

    public static string AppUserModelId(Guid id) => $"IssenSoftware.Clatch.Profile.{id:N}";

    public static void Sync(IReadOnlyList<Account> accounts, bool enabled, string? claudeExe)
    {
        var record = Load();
        var wanted = new Dictionary<Guid, List<string>>();
        if (enabled)
        {
            foreach (var account in accounts)
            {
                var file = $"Claude - {SafeName(account.Name)}.lnk";
                wanted[account.Id] = [Path.Combine(Desktop, file), Path.Combine(StartMenuFolder, file)];
            }
        }

        // Remove what is no longer wanted (profile removed or renamed, or setting off).
        foreach (var (id, paths) in record)
            foreach (var path in paths.Where(p => !wanted.TryGetValue(id, out var keep) || !keep.Contains(p, StringComparer.OrdinalIgnoreCase)))
                TryDelete(path);

        // Create or refresh the rest (refreshing also picks up a new icon or Clatch location).
        var exe = Environment.ProcessPath!;
        foreach (var account in accounts.Where(a => wanted.ContainsKey(a.Id)))
        {
            string icon;
            try { icon = ProfileIcons.Ico(account, claudeExe); ProfileIcons.Prune(account, claudeExe); }
            catch (Exception e) { Log.Error("drawing a profile icon", e); icon = exe; }
            foreach (var path in wanted[account.Id])
            {
                try
                {
                    Shell.CreateShortcut(path, exe, $"--launch {account.Id:D}", icon,
                                         $"Open Claude with the profile {account.Name} (Clatch)", AppUserModelId(account.Id));
                }
                catch (Exception e)
                {
                    Log.Error($"creating the shortcut {Path.GetFileName(path)}", e);
                }
            }
        }
        if (!enabled) TryDeleteFolder(StartMenuFolder);
        Save(wanted);
    }

    public static string SafeName(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var cleaned = new string(name.Select(c => invalid.Contains(c) ? '-' : c).ToArray()).Trim().TrimEnd('.');
        return cleaned.Length == 0 ? "Profile" : cleaned[..Math.Min(60, cleaned.Length)];
    }

    private static Dictionary<Guid, List<string>> Load()
    {
        try
        {
            if (File.Exists(RecordFile))
                return JsonSerializer.Deserialize(File.ReadAllText(RecordFile), AppJsonContext.Default.DictionaryGuidListString) ?? [];
        }
        catch (Exception e) when (e is JsonException or IOException) { }
        return [];
    }

    private static void Save(Dictionary<Guid, List<string>> record)
    {
        try
        {
            Directory.CreateDirectory(Settings.Folder);
            File.WriteAllText(RecordFile, JsonSerializer.Serialize(record, AppJsonContext.Default.DictionaryGuidListString));
        }
        catch (IOException) { }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path) && path.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase)) File.Delete(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    private static void TryDeleteFolder(string folder)
    {
        try { if (Directory.Exists(folder) && !Directory.EnumerateFileSystemEntries(folder).Any()) Directory.Delete(folder); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
