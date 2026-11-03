// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

namespace Clatch.Core;

/// <summary>
/// Copies of each profile's sign-in, taken when the way profiles run changes
/// (side by side ⇄ one at a time), so no profile ever has to sign in again.
/// Only what makes up the sign-in is copied (cookies, "Local State" with the
/// DPAPI-protected key, the encrypted token cache in config.json, preferences,
/// local storage); caches, Code-tab data and Cowork's VM images are not.
/// </summary>
public static class SignInBackup
{
    public static readonly string[] Items =
        ["Local State", "Cookies", "Cookies-journal", Path.Combine("Network", "Cookies"), Path.Combine("Network", "Cookies-journal"),
         "config.json", "Preferences", "Local Storage"];
    public const int Kept = 3;

    public sealed record Snapshot(string Folder, DateTime Date, IReadOnlyList<Guid> Profiles)
    {
        public string Id => Path.GetFileName(Folder);
    }

    /// <summary>Backs up the given profiles (id → data folder); folders that do not exist are skipped.</summary>
    public static Snapshot? BackUp(IReadOnlyDictionary<Guid, string> profiles, string root, string reason)
    {
        var now = DateTime.Now;
        var folder = Path.Combine(root, now.ToString("yyyy-MM-dd'T'HH-mm-ss-fff"));
        var copied = new List<Guid>();
        foreach (var (id, data) in profiles)
        {
            var any = false;
            foreach (var item in Items)
            {
                var source = Path.Combine(data, item);
                var destination = Path.Combine(folder, id.ToString("D"), item);
                if (File.Exists(source))
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                    File.Copy(source, destination, overwrite: true);
                    any = true;
                }
                else if (Directory.Exists(source))
                {
                    CopyDirectory(source, destination);
                    any = true;
                }
            }
            if (any) copied.Add(id);
        }
        if (copied.Count == 0) return null;
        File.WriteAllText(Path.Combine(folder, "reason.txt"), reason);
        foreach (var old in List(root).Skip(Kept))
        {
            try { Directory.Delete(old.Folder, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
        return new Snapshot(folder, now, copied);
    }

    /// <summary>The backups in a folder, newest first.</summary>
    public static List<Snapshot> List(string root)
    {
        if (!Directory.Exists(root)) return [];
        return Directory.GetDirectories(root)
            .Select(folder => new Snapshot(folder, Directory.GetCreationTime(folder),
                Directory.GetDirectories(folder).Select(d => Guid.TryParse(Path.GetFileName(d), out var g) ? g : Guid.Empty)
                         .Where(g => g != Guid.Empty).ToList()))
            .Where(s => s.Profiles.Count > 0)
            .OrderByDescending(s => s.Date)
            .ToList();
    }

    /// <summary>Puts a profile's sign-in back. Claude must not be running in that folder.</summary>
    public static void Restore(Guid id, Snapshot snapshot, string data)
    {
        var source = Path.Combine(snapshot.Folder, id.ToString("D"));
        Directory.CreateDirectory(data);
        foreach (var item in Items)
        {
            var from = Path.Combine(source, item);
            var to = Path.Combine(data, item);
            if (File.Exists(from))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(to)!);
                File.Copy(from, to, overwrite: true);
            }
            else if (Directory.Exists(from))
            {
                if (Directory.Exists(to)) Directory.Delete(to, recursive: true);
                CopyDirectory(from, to);
            }
        }
    }

    private static void CopyDirectory(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var file in Directory.GetFiles(from)) File.Copy(file, Path.Combine(to, Path.GetFileName(file)), overwrite: true);
        foreach (var dir in Directory.GetDirectories(from)) CopyDirectory(dir, Path.Combine(to, Path.GetFileName(dir)));
    }
}
