// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using System.Diagnostics;
using System.Text.RegularExpressions;
using Clatch.Core;
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
        // Only the older Store layout (data in the redirected %APPDATA%\Claude)
        // reads several folders. Current versions use one explicit folder.
        IsPackaged && PackageFolder is not null
        && DataFolder.Equals(Path.Combine(PackageFolder, "LocalCache", "Roaming", "Claude"), StringComparison.OrdinalIgnoreCase)
            ? [
                new Clatch.Core.DataFolder("Claude-AppData", ClassicData),
                // The package's redirected %LOCALAPPDATA%\Claude, in case Claude keeps session data there.
                new Clatch.Core.DataFolder("Claude-Local", Path.Combine(PackageFolder!, "LocalCache", "Local", "Claude")),
              ]
            : [];

    /// <summary>%LOCALAPPDATA%\Packages\&lt;family&gt; for the MSIX version.</summary>
    public string? PackageFolder => PackageFamilyName is null ? null : Path.Combine(LocalAppData, "Packages", PackageFamilyName);

    /// <summary>The top two levels of the package's folders (names only), for the log:
    /// shows where a sign-in could live if Claude ever moves it.</summary>
    public string DescribePackageFolders()
    {
        if (PackageFolder is null || !Directory.Exists(PackageFolder)) return "-";
        try
        {
            var lines = new List<string>();
            foreach (var top in Directory.GetDirectories(PackageFolder))
            {
                var children = Directory.GetDirectories(top).Select(Path.GetFileName).Take(12);
                lines.Add($"{Path.GetFileName(top)}/[{string.Join(", ", children)}]");
                foreach (var cache in new[] { "Roaming", "Local" })
                {
                    var sub = Path.Combine(top, cache);
                    if (Directory.Exists(sub))
                        lines.Add($"{Path.GetFileName(top)}/{cache}/[{string.Join(", ", Directory.GetDirectories(sub).Select(Path.GetFileName).Take(12))}]");
                }
            }
            return string.Join(" ", lines);
        }
        catch (Exception e) { return $"({e.GetType().Name})"; }
    }

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

    /// <summary>Claude's data folder as last read from a running Claude (--user-data-dir), remembered across launches.</summary>
    public static string? LastSeenDataFolder { get; set; }

    private static readonly string ClaudeDataRoot = Path.Combine(LocalAppData, "Claude-Data");

    public static ClaudeInstall Detect()
    {
        var classicLauncher = Path.Combine(ClassicFolder, "claude.exe");
        var classicInstalled = File.Exists(classicLauncher);
        var package = FindPackage();
        var running = Snapshot(withPaths: true).Where(LooksLikeClaudeDesktop).ToList();
        if (running.FirstOrDefault(p => p.Path is not null) is { Path: { } seen }) LastSeenExecutable = seen;

        // The most reliable fact of all: the data folder the running Claude was
        // told to use. Electron passes --user-data-dir to every helper process.
        var fromCommandLine = running
            .Select(p => ClaudeCommandLine.UserDataDir(CommandLineOf(p.Pid)))
            .FirstOrDefault(d => d is not null);
        if (fromCommandLine is not null) LastSeenDataFolder = fromCommandLine;

        // 1. Claude is running: its package identity (or the classic folder) says
        //    which installation it is, its command line where the data is.
        if (running.FirstOrDefault(p => p.Family is not null) is { Family: { } family } packagedProcess)
        {
            var root = packagedProcess.Path is { } exe && PackageFromPath(exe) is { } fromPath ? fromPath.Root
                     : package is { } pk && pk.FamilyName.Equals(family, StringComparison.OrdinalIgnoreCase) ? pk.InstallFolder
                     : null;
            var how = fromCommandLine is not null ? "running Claude (package, --user-data-dir)" : "running Claude (package)";
            return Packaged(family, root, how, fromCommandLine ?? PackagedDataFolder(family));
        }
        if (running.Count > 0)
        {
            var how = fromCommandLine is not null ? "running Claude (classic installer, --user-data-dir)" : "running Claude (classic installer)";
            return Classic(classicInstalled, classicLauncher, how, fromCommandLine ?? ClassicDataFolder());
        }

        // 2. Not running: the installed package, if any, decides; its data folder
        //    is where Claude was last seen keeping it, or Claude-Data, or the old place.
        if (package is { } installed)
            return Packaged(installed.FamilyName, installed.InstallFolder, "package database", PackagedDataFolder(installed.FamilyName));
        if (LastSeenExecutable is { } last && IsInWindowsApps(last) && PackageFromPath(last) is { } fromLast)
            return Packaged(fromLast.FamilyName, fromLast.Root, "last seen running (package)", PackagedDataFolder(fromLast.FamilyName));
        return Classic(classicInstalled, classicLauncher, classicInstalled ? "classic installer" : "not found", ClassicDataFolder());
    }

    /// <summary>
    /// Data folder of the Microsoft Store version when Claude is not running to
    /// tell us: where it was last seen, else %LOCALAPPDATA%\Claude-Data\&lt;family&gt;
    /// (current versions), else the redirected %APPDATA%\Claude (older versions).
    /// </summary>
    private static string PackagedDataFolder(string family)
    {
        var legacy = Path.Combine(LocalAppData, "Packages", family, "LocalCache", "Roaming", "Claude");
        var current = Path.Combine(ClaudeDataRoot, family.ToLowerInvariant());
        if (LastSeenDataFolder is { } seen && !seen.Equals(legacy, StringComparison.OrdinalIgnoreCase)
            && (ClaudeCommandLine.LooksLikeUserData(seen) || ClaudeCommandLine.HasMovedAwayMarker(legacy)))
            return seen;
        if (Directory.Exists(current) || ClaudeCommandLine.HasMovedAwayMarker(legacy)) return current;
        if (ClaudeCommandLine.LooksLikeUserData(legacy)) return legacy;
        return Directory.Exists(ClaudeDataRoot) ? current : legacy;
    }

    private static string ClassicDataFolder() =>
        LastSeenDataFolder is { } seen && !ClaudeCommandLine.LooksLikeUserData(ClassicData) && ClaudeCommandLine.LooksLikeUserData(seen)
            ? seen
            : ClassicData;

    private static unsafe string? CommandLineOf(uint pid)
    {
        var handle = Native.OpenProcess(Native.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (handle == 0) return null;
        try { return Native.CommandLineOf(handle); }
        catch (Exception) { return null; }
        finally { Native.CloseHandle(handle); }
    }

    private static ClaudeInstall Classic(bool installed, string launcher, string how, string data) =>
        new(installed || LastSeenExecutable is not null, false, data, [ClassicFolder], null,
            installed ? launcher : LastSeenExecutable, null, how);

    private static ClaudeInstall Packaged(string family, string? root, string how, string data) =>
        new(true, true, data, root is null ? [] : [root], family, null, root, how);

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
        foreach (var data in SafeDirectories(ClaudeDataRoot, "*"))
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

    /// <summary>A process, with its executable and (for MSIX apps) its package family.</summary>
    private readonly record struct ProcessInfo(uint Pid, uint ParentPid, string? Path, string? Family);

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
                string? path = null, family = null;
                if (withPaths) (path, family) = Identify(entry.th32ProcessID);
                result.Add(new ProcessInfo(entry.th32ProcessID, entry.th32ParentProcessID, path, family));
            } while (Native.Process32NextW(snapshot, &entry));
        }
        finally
        {
            Native.CloseHandle(snapshot);
        }
        return result;
    }

    /// <summary>Executable path and package family (null when not packaged) of a process.</summary>
    private static unsafe (string? Path, string? Family) Identify(uint pid)
    {
        var handle = Native.OpenProcess(Native.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (handle == 0) return (null, null);
        try
        {
            var buffer = stackalloc char[1024];
            uint size = 1024;
            var path = Native.QueryFullProcessImageNameW(handle, 0, buffer, ref size) ? new string(buffer, 0, (int)size) : null;
            uint length = 256;
            var familyBuffer = stackalloc char[256];
            var family = Native.GetPackageFamilyName(handle, ref length, familyBuffer) == 0 && length > 1
                ? new string(familyBuffer, 0, (int)length - 1)
                : null;
            return (path, family);
        }
        finally
        {
            Native.CloseHandle(handle);
        }
    }

    private static bool IsUnder(string? path, string folder) =>
        path is not null && folder.Length > 0
        && path.StartsWith(folder.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase);

    /// <summary>The package of Claude Desktop: "Claude_pzs8sxrjxfjjc", or anything published as Anthropic's.</summary>
    private static bool IsClaudeFamily(string? family) =>
        family is not null
        && (family.StartsWith("Claude_", StringComparison.OrdinalIgnoreCase)
            || family.Contains("Anthropic", StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// A Claude Desktop process, either installation. MSIX processes are
    /// recognised by their package identity, whatever the executable is
    /// called; classic ones by living in %LOCALAPPDATA%\AnthropicClaude. The
    /// Claude Code command-line tool (also claude.exe, but unpackaged and
    /// installed elsewhere) never matches.
    /// </summary>
    private static bool LooksLikeClaudeDesktop(ProcessInfo p) =>
        IsClaudeFamily(p.Family) || IsUnder(p.Path, ClassicFolder);

    private bool IsClaudeProcess(ProcessInfo p) =>
        LooksLikeClaudeDesktop(p)
        || (p.Family is not null && PackageFamilyName is not null && p.Family.Equals(PackageFamilyName, StringComparison.OrdinalIgnoreCase))
        || ProgramFolders.Any(f => IsUnder(p.Path, f));

    /// <summary>Claude's main processes: Claude processes whose parent is not a Claude process
    /// (Electron renderers and helpers are children of the main process).</summary>
    private List<ProcessInfo> MainProcesses()
    {
        var claude = Snapshot(withPaths: true).Where(IsClaudeProcess).ToList();
        var claudePids = claude.Select(p => p.Pid).ToHashSet();
        var mains = claude.Where(p => !claudePids.Contains(p.ParentPid)).ToList();
        if (mains.Count > 0 && mains[0].Path is { } path) LastSeenExecutable = path;
        return mains;
    }

    public bool IsRunning => MainProcesses().Count > 0;

    /// <summary>Every running Claude Desktop process (for the log).</summary>
    public string DescribeRunning()
    {
        var claude = Snapshot(withPaths: true).Where(IsClaudeProcess).ToList();
        return claude.Count == 0 ? "none"
            : string.Join("; ", claude.Take(5).Select(p => $"{p.Pid}<-{p.ParentPid} {p.Path} [{p.Family ?? "unpackaged"}]"))
              + (claude.Count > 5 ? $" (+{claude.Count - 5})" : "");
    }

    /// <summary>Anything still running from Claude (any process of its package, its
    /// program folder or its data folders: helpers, local Claude Code sessions).
    /// Nothing may be moved while one is left.</summary>
    public int LeftoverProcessCount()
    {
        var folders = new List<string> { DataFolder };
        folders.AddRange(ExtraDataFolders.Select(f => f.Live));
        return Snapshot(withPaths: true).Count(p => IsClaudeProcess(p) || folders.Any(f => IsUnder(p.Path, f)));
    }

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
