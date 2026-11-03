// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using System.Diagnostics;
using System.Text.RegularExpressions;
using Clatch.Interop;
using Windows.Management.Deployment;

namespace Clatch;

/// <summary>Where Claude Desktop is installed and keeps its data, and how to start it.</summary>
/// <remarks>
/// Claude Desktop for Windows comes two ways:
/// <list type="bullet">
/// <item>the classic installer: <c>%LOCALAPPDATA%\AnthropicClaude</c>, data in <c>%APPDATA%\Claude</c>;</item>
/// <item>an MSIX package under <c>C:\Program Files\WindowsApps</c>: Windows redirects its
/// <c>%APPDATA%</c> writes to <c>%LOCALAPPDATA%\Packages\&lt;family&gt;\LocalCache\Roaming\Claude</c>.</item>
/// </list>
/// Detection does not rely on any single source. In order of trust: the
/// Claude process that is running right now (its path says which kind it is),
/// the package database, the folders that exist on disk (the most recently
/// used data folder wins), and finally where Claude was last seen running.
/// </remarks>
internal sealed record ClaudeInstall(bool IsInstalled, bool IsPackaged, string DataFolder,
                                     IReadOnlyList<string> ProgramFolders, string? PackageFamilyName,
                                     string? LauncherPath, string? PackageRoot, string How)
{
    private static readonly string RoamingAppData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
    private static readonly string LocalAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
    private static readonly string ClassicFolder = Path.Combine(LocalAppData, "AnthropicClaude");
    private static readonly string ClassicData = Path.Combine(RoamingAppData, "Claude");

    /// <summary>
    /// Folders besides <see cref="DataFolder"/> that Claude reads and that must
    /// move with the account. The Microsoft Store version reads %APPDATA%\Claude
    /// wherever its private copy has nothing, so a sign-in left there would
    /// otherwise come back after every switch.
    /// </summary>
    public IReadOnlyList<Clatch.Core.DataFolder> ExtraDataFolders =>
        IsPackaged ? [new Clatch.Core.DataFolder("Claude-AppData", ClassicData)] : [];

    /// <summary>One line per data folder: does it exist, and does it hold a sign-in?</summary>
    public string DescribeFolders()
    {
        static string Describe(string folder)
        {
            if (!Directory.Exists(folder)) return "absent";
            var markers = new[] { "Local State", "Cookies", Path.Combine("Network", "Cookies"), "config.json", "Local Storage" }
                .Where(m => File.Exists(Path.Combine(folder, m)) || Directory.Exists(Path.Combine(folder, m)));
            return $"present [{string.Join(", ", markers)}], modified {LastUsed(folder):u}";
        }
        var lines = new List<string> { $"main {DataFolder}: {Describe(DataFolder)}" };
        lines.AddRange(ExtraDataFolders.Select(f => $"{f.Key} {f.Live}: {Describe(f.Live)}"));
        if (!IsPackaged)
            lines.AddRange(PackageDataFolders().Select(p => $"(unused package copy) {p.Data}: {Describe(p.Data)}"));
        return string.Join("; ", lines);
    }

    /// <summary>Where Claude was last seen running (remembered across launches, for relaunching).</summary>
    public static string? LastSeenExecutable { get; set; }

    public static ClaudeInstall Detect()
    {
        var classicLauncher = Path.Combine(ClassicFolder, "claude.exe");
        var classicInstalled = File.Exists(classicLauncher);
        var package = FindPackage();
        var running = Snapshot(withPaths: true).Where(p => LooksLikeClaudeDesktop(p.Path)).Select(p => p.Path!).ToList();
        if (running.Count > 0) LastSeenExecutable = running[0];

        // 1. A running Claude tells us exactly which installation is in use.
        var runningPackaged = running.FirstOrDefault(IsInWindowsApps);
        if (runningPackaged is not null && PackageFromPath(runningPackaged) is { } fromProcess)
        {
            return Packaged(fromProcess.FamilyName, fromProcess.Root, "running Claude (package)");
        }
        if (running.Count > 0 && runningPackaged is null)
        {
            return Classic(classicInstalled, classicLauncher, "running Claude (classic installer)");
        }

        // 2. Not running: compare the data folders that exist; the most recently used one wins.
        var candidates = new List<(string Data, DateTime Used, Func<ClaudeInstall> Make)>();
        if (Directory.Exists(ClassicData))
            candidates.Add((ClassicData, LastUsed(ClassicData), () => Classic(classicInstalled, classicLauncher, "classic data folder")));
        foreach (var (family, data) in PackageDataFolders())
        {
            var root = package is { } p && p.FamilyName == family ? p.InstallFolder : PackageRootFromLastSeen(family);
            candidates.Add((data, LastUsed(data), () => Packaged(family, root, "package data folder")));
        }
        if (candidates.Count > 0)
            return candidates.OrderByDescending(c => c.Used).First().Make();

        // 3. No data yet (fresh install or a brand-new account): go by what is installed.
        if (package is { } installed) return Packaged(installed.FamilyName, installed.InstallFolder, "package database");
        if (LastSeenExecutable is { } last && IsInWindowsApps(last) && PackageFromPath(last) is { } fromLast)
            return Packaged(fromLast.FamilyName, fromLast.Root, "last seen running (package)");
        return Classic(classicInstalled, classicLauncher, classicInstalled ? "classic installer" : "not found");
    }

    private static ClaudeInstall Classic(bool installed, string launcher, string how) =>
        new(installed || LastSeenExecutable is not null, false, ClassicData, [ClassicFolder], null,
            installed ? launcher : LastSeenExecutable, null, how);

    private static ClaudeInstall Packaged(string family, string? root, string how) =>
        new(true, true, Path.Combine(LocalAppData, "Packages", family, "LocalCache", "Roaming", "Claude"),
            root is null ? [] : [root], family, null, root, how);

    // ---- Package helpers ---------------------------------------------------------

    private static (string FamilyName, string InstallFolder)? FindPackage()
    {
        try
        {
            foreach (var package in new PackageManager().FindPackagesForUser(string.Empty))
            {
                var id = package.Id;
                var looksLikeClaude = id.Name.Contains("Claude", StringComparison.OrdinalIgnoreCase);
                var publisher = $"{package.PublisherDisplayName} {id.Publisher}";
                if (!looksLikeClaude || !publisher.Contains("Anthropic", StringComparison.OrdinalIgnoreCase)) continue;
                return (id.FamilyName, package.InstalledLocation.Path);
            }
        }
        catch (Exception e)
        {
            Log.Write($"Package lookup failed: {e.GetType().Name}: {e.Message}");
        }
        return null;
    }

    /// <summary>Package data folders that hold a Claude user-data folder, whatever the package is called.</summary>
    private static IEnumerable<(string Family, string Data)> PackageDataFolders()
    {
        foreach (var folder in SafeDirectories(Path.Combine(LocalAppData, "Packages"), "*Claude*"))
        {
            var data = Path.Combine(folder, "LocalCache", "Roaming", "Claude");
            if (Directory.Exists(data)) yield return (Path.GetFileName(folder), data);
        }
    }

    private static bool IsInWindowsApps(string path) =>
        path.Contains(@"\WindowsApps\", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// "C:\Program Files\WindowsApps\Claude_1.0.0.0_x64__pzs8sxrjxfjjc\app\claude.exe"
    /// → family "Claude_pzs8sxrjxfjjc", root "...\Claude_1.0.0.0_x64__pzs8sxrjxfjjc".
    /// </summary>
    internal static (string FamilyName, string Root)? PackageFromPath(string path)
    {
        var match = Regex.Match(path, @"^(?<root>.*\\WindowsApps\\(?<name>[^\\_]+)_[^\\]*__(?<publisher>[^\\]+))\\", RegexOptions.IgnoreCase);
        return match.Success ? ($"{match.Groups["name"].Value}_{match.Groups["publisher"].Value}", match.Groups["root"].Value) : null;
    }

    private static string? PackageRootFromLastSeen(string family) =>
        LastSeenExecutable is { } last && PackageFromPath(last) is { } p && p.FamilyName.Equals(family, StringComparison.OrdinalIgnoreCase)
            ? p.Root : null;

    private static DateTime LastUsed(string folder)
    {
        try
        {
            var times = new[] { "Local State", "Cookies", Path.Combine("Network", "Cookies"), "config.json" }
                .Select(name => Path.Combine(folder, name))
                .Where(File.Exists)
                .Select(File.GetLastWriteTimeUtc)
                .ToList();
            return times.Count > 0 ? times.Max() : Directory.GetLastWriteTimeUtc(folder);
        }
        catch (Exception) { return DateTime.MinValue; }
    }

    /// <summary>Other folders a future Claude might use; mentioned by the fail-safe when they exist.</summary>
    public IEnumerable<string> AlternativeDataFolders()
    {
        yield return Path.Combine(RoamingAppData, "Claude-3p");
        yield return Path.Combine(RoamingAppData, "Anthropic");
        yield return Path.Combine(RoamingAppData, "Anthropic Claude");
        yield return Path.Combine(LocalAppData, "Claude");
        foreach (var (_, data) in PackageDataFolders())
            if (!data.Equals(DataFolder, StringComparison.OrdinalIgnoreCase)) yield return data;
        if (IsPackaged) yield return Path.Combine(Path.GetDirectoryName(DataFolder)!, "Claude-3p");
    }

    private static IEnumerable<string> SafeDirectories(string folder, string pattern)
    {
        try { return Directory.Exists(folder) ? Directory.GetDirectories(folder, pattern) : []; }
        catch (IOException) { return []; }
        catch (UnauthorizedAccessException) { return []; }
    }

    // ---- Processes ------------------------------------------------------------

    private readonly record struct ProcessInfo(uint Pid, uint ParentPid, string? Path);

    private static unsafe List<ProcessInfo> Snapshot(bool withPaths)
    {
        var result = new List<ProcessInfo>();
        var snapshot = Native.CreateToolhelp32Snapshot(Native.TH32CS_SNAPPROCESS, 0);
        if (snapshot == -1) return result;
        try
        {
            var entry = new Native.PROCESSENTRY32W { dwSize = (uint)sizeof(Native.PROCESSENTRY32W) };
            if (!Native.Process32FirstW(snapshot, &entry)) return result;
            var self = (uint)Environment.ProcessId;
            do
            {
                if (entry.th32ProcessID == 0 || entry.th32ProcessID == self) continue;
                result.Add(new ProcessInfo(entry.th32ProcessID, entry.th32ParentProcessID,
                                           withPaths ? ImagePath(entry.th32ProcessID) : null));
            } while (Native.Process32NextW(snapshot, &entry));
        }
        finally
        {
            Native.CloseHandle(snapshot);
        }
        return result;
    }

    private static unsafe string? ImagePath(uint pid)
    {
        var handle = Native.OpenProcess(Native.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (handle == 0) return null;
        try
        {
            var buffer = stackalloc char[1024];
            uint size = 1024;
            return Native.QueryFullProcessImageNameW(handle, 0, buffer, ref size) ? new string(buffer, 0, (int)size) : null;
        }
        finally
        {
            Native.CloseHandle(handle);
        }
    }

    private static bool IsUnder(string? path, string folder) =>
        path is not null && folder.Length > 0
        && path.StartsWith(folder.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// claude.exe from the Desktop app, either installation. The Claude Code
    /// command-line tool is also called claude.exe, but lives elsewhere
    /// (npm or ~\.local\bin), so it never matches.
    /// </summary>
    private static bool LooksLikeClaudeDesktop(string? path)
    {
        if (path is null || !System.IO.Path.GetFileName(path).Equals("claude.exe", StringComparison.OrdinalIgnoreCase)) return false;
        if (IsUnder(path, ClassicFolder)) return true;
        return IsInWindowsApps(path) && PackageFromPath(path) is { } p
               && (p.FamilyName.Contains("Claude", StringComparison.OrdinalIgnoreCase)
                   || p.FamilyName.Contains("Anthropic", StringComparison.OrdinalIgnoreCase));
    }

    private bool IsClaudeExecutable(string? path) =>
        LooksLikeClaudeDesktop(path) || (path is not null && ProgramFolders.Any(f => IsUnder(path, f))
                                         && System.IO.Path.GetFileName(path).Equals("claude.exe", StringComparison.OrdinalIgnoreCase));

    /// <summary>Claude's main processes: claude.exe whose parent is not itself claude.exe
    /// (Electron renderers and helpers are children of the main process).</summary>
    private List<ProcessInfo> MainProcesses()
    {
        var all = Snapshot(withPaths: true);
        var claude = all.Where(p => IsClaudeExecutable(p.Path)).ToList();
        var claudePids = claude.Select(p => p.Pid).ToHashSet();
        var mains = claude.Where(p => !claudePids.Contains(p.ParentPid)).ToList();
        if (mains.Count > 0) LastSeenExecutable = mains[0].Path;
        return mains;
    }

    public bool IsRunning => MainProcesses().Count > 0;

    /// <summary>Every running Claude Desktop process (for the log).</summary>
    public string DescribeRunning()
    {
        var claude = Snapshot(withPaths: true).Where(p => IsClaudeExecutable(p.Path)).ToList();
        return claude.Count == 0 ? "none" : string.Join("; ", claude.Take(4).Select(p => $"{p.Pid}<-{p.ParentPid} {p.Path}")) + (claude.Count > 4 ? $" (+{claude.Count - 4})" : "");
    }

    /// <summary>Anything still running from Claude's program folder or data folder
    /// (helpers, local Claude Code sessions). The data folder can only be moved once none is left.</summary>
    public int LeftoverProcessCount() =>
        Snapshot(withPaths: true).Count(p => IsClaudeExecutable(p.Path) || IsUnder(p.Path, DataFolder));

    /// <summary>
    /// Asks Claude to close through the Restart Manager, the mechanism installers
    /// use: Claude receives the "please close" messages it would get when Windows
    /// shuts down, and is allowed to refuse. Never forced.
    /// </summary>
    /// <returns>The Restart Manager result (0 when Claude agreed to close).</returns>
    public unsafe int RequestQuit()
    {
        var mains = MainProcesses();
        if (mains.Count == 0) return 0;
        var key = stackalloc char[33];
        var status = Native.RmStartSession(out var session, 0, key);
        if (status != 0) return status;
        try
        {
            var apps = stackalloc Native.RM_UNIQUE_PROCESS[mains.Count];
            var count = 0;
            foreach (var main in mains)
            {
                var handle = Native.OpenProcess(Native.PROCESS_QUERY_LIMITED_INFORMATION, false, main.Pid);
                if (handle == 0) continue;
                try
                {
                    if (!Native.GetProcessTimes(handle, out var created, out _, out _, out _)) continue;
                    apps[count++] = new Native.RM_UNIQUE_PROCESS { dwProcessId = main.Pid, ProcessStartTime = created };
                }
                finally
                {
                    Native.CloseHandle(handle);
                }
            }
            if (count == 0) return -1;
            status = Native.RmRegisterResources(session, 0, 0, (uint)count, apps, 0, 0);
            if (status != 0) return status;
            // flags 0: no RmForceShutdown. Returns an error if Claude declined.
            return Native.RmShutdown(session, 0, 0);
        }
        finally
        {
            Native.RmEndSession(session);
        }
    }

    /// <summary>
    /// Fallback when the Restart Manager can't do it: send Claude's top-level
    /// windows the messages Windows sends when the session ends with
    /// ENDSESSION_CLOSEAPP (exactly what the Restart Manager would send).
    /// Claude may refuse via WM_QUERYENDSESSION; then nothing else is sent.
    /// </summary>
    /// <returns>true when every window agreed.</returns>
    public bool RequestQuitBySessionEnd()
    {
        var pids = MainProcesses().Select(p => p.Pid).ToHashSet();
        if (pids.Count == 0) return true;
        var windows = WindowsOf(pids);
        Log.Write($"Session-end fallback: {windows.Count} window(s) of Claude");
        if (windows.Count == 0) return false;
        foreach (var hwnd in windows)
        {
            Native.SendMessageTimeoutW(hwnd, Native.WM_QUERYENDSESSION, 0, (nint)Native.ENDSESSION_CLOSEAPP,
                                       Native.SMTO_ABORTIFHUNG, 5000, out var agreed);
            if (agreed == 0)
            {
                Log.Write("Claude declined to close (WM_QUERYENDSESSION)");
                return false;
            }
        }
        foreach (var hwnd in windows)
            Native.SendMessageTimeoutW(hwnd, Native.WM_ENDSESSION, 1, (nint)Native.ENDSESSION_CLOSEAPP,
                                       Native.SMTO_ABORTIFHUNG, 5000, out _);
        return true;
    }

    private static readonly object EnumGate = new();
    private static HashSet<uint>? enumPids;
    private static List<nint>? enumResult;

    private static unsafe List<nint> WindowsOf(HashSet<uint> pids)
    {
        lock (EnumGate)
        {
            enumPids = pids;
            enumResult = [];
            Native.EnumWindows(&CollectWindow, 0);
            var result = enumResult;
            enumPids = null;
            enumResult = null;
            return result;
        }
    }

    [System.Runtime.InteropServices.UnmanagedCallersOnly]
    private static int CollectWindow(nint hwnd, nint parameter)
    {
        Native.GetWindowThreadProcessId(hwnd, out var pid);
        if (enumPids is not null && enumPids.Contains(pid)) enumResult?.Add(hwnd);
        return 1; // continue
    }

    public async Task OpenAsync()
    {
        try
        {
            if (IsPackaged && PackageFamilyName is not null)
            {
                // Package database first; works for any app id.
                try
                {
                    var package = new PackageManager().FindPackagesForUser(string.Empty, PackageFamilyName).FirstOrDefault();
                    if (package is not null)
                    {
                        var entries = await package.GetAppListEntriesAsync();
                        if (entries.Count > 0 && await entries[0].LaunchAsync())
                        {
                            Log.Write($"Opened Claude through the package database ({PackageFamilyName})");
                            return;
                        }
                    }
                }
                catch (Exception e)
                {
                    Log.Write($"Package launch failed: {e.GetType().Name}: {e.Message}");
                }
                // Then the Start menu entry (shell:AppsFolder\<family>!<app id from the manifest>).
                var appId = AppIdFromManifest() ?? "Claude";
                Process.Start(new ProcessStartInfo("explorer.exe", $"shell:AppsFolder\\{PackageFamilyName}!{appId}") { UseShellExecute = true });
                Log.Write($"Opened Claude through shell:AppsFolder\\{PackageFamilyName}!{appId}");
                return;
            }
            var exe = LauncherPath ?? LastSeenExecutable;
            if (exe is not null && File.Exists(exe))
            {
                Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true });
                Log.Write($"Opened Claude: {exe}");
            }
            else
            {
                Log.Write("Could not open Claude: no launcher found");
            }
        }
        catch (Exception e)
        {
            Log.Error("opening Claude", e);
        }
    }

    private string? AppIdFromManifest()
    {
        try
        {
            if (PackageRoot is null) return null;
            var manifest = Path.Combine(PackageRoot, "AppxManifest.xml");
            if (!File.Exists(manifest)) return null;
            var match = Regex.Match(File.ReadAllText(manifest), "<Application\\s[^>]*Id=\"([^\"]+)\"");
            return match.Success ? match.Groups[1].Value : null;
        }
        catch (Exception) { return null; }
    }
}
