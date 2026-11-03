// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using System.Diagnostics;
using Clatch.Interop;
using Windows.Management.Deployment;

namespace Clatch;

/// <summary>Where Claude Desktop is installed and keeps its data, and how to start it.</summary>
/// <remarks>
/// Claude Desktop for Windows comes two ways:
/// <list type="bullet">
/// <item>the classic installer: <c>%LOCALAPPDATA%\AnthropicClaude</c>, data in <c>%APPDATA%\Claude</c>;</item>
/// <item>an MSIX package: Windows redirects its <c>%APPDATA%</c> writes to
/// <c>%LOCALAPPDATA%\Packages\&lt;family&gt;\LocalCache\Roaming\Claude</c>.</item>
/// </list>
/// </remarks>
internal sealed record ClaudeInstall(bool IsInstalled, bool IsPackaged, string DataFolder,
                                     IReadOnlyList<string> ProgramFolders, string? PackageFamilyName,
                                     string? LauncherPath)
{
    private static readonly string RoamingAppData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
    private static readonly string LocalAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    public static ClaudeInstall Detect()
    {
        var classicFolder = Path.Combine(LocalAppData, "AnthropicClaude");
        var classicLauncher = Path.Combine(classicFolder, "claude.exe");
        var classicData = Path.Combine(RoamingAppData, "Claude");
        var classicInstalled = File.Exists(classicLauncher);

        var package = FindPackage();
        if (package is not null)
        {
            var data = Path.Combine(LocalAppData, "Packages", package.Value.FamilyName, "LocalCache", "Roaming", "Claude");
            // Both installed: follow the one whose data exists, preferring the package.
            if (!classicInstalled || Directory.Exists(data) || !Directory.Exists(classicData))
            {
                return new ClaudeInstall(true, true, data, [package.Value.InstallFolder], package.Value.FamilyName, null);
            }
        }
        return new ClaudeInstall(classicInstalled, false, classicData, [classicFolder], null,
                                 classicInstalled ? classicLauncher : null);
    }

    private static (string FamilyName, string InstallFolder)? FindPackage()
    {
        try
        {
            foreach (var package in new PackageManager().FindPackagesForUser(string.Empty))
            {
                var id = package.Id;
                if (!id.Name.Equals("Claude", StringComparison.OrdinalIgnoreCase)
                    && !id.Name.StartsWith("Anthropic", StringComparison.OrdinalIgnoreCase)) continue;
                var publisher = package.PublisherDisplayName ?? "";
                if (!publisher.Contains("Anthropic", StringComparison.OrdinalIgnoreCase)) continue;
                return (id.FamilyName, package.InstalledLocation.Path);
            }
        }
        catch (Exception e)
        {
            Debug.WriteLine($"Package lookup failed: {e.Message}");
        }
        return null;
    }

    /// <summary>Other folders a future Claude might use; mentioned by the fail-safe when they exist.</summary>
    public IEnumerable<string> AlternativeDataFolders()
    {
        yield return Path.Combine(RoamingAppData, "Claude-3p");
        yield return Path.Combine(RoamingAppData, "Anthropic");
        yield return Path.Combine(RoamingAppData, "Anthropic Claude");
        yield return Path.Combine(LocalAppData, "Claude");
        if (IsPackaged)
        {
            yield return Path.Combine(RoamingAppData, "Claude");
            yield return Path.Combine(Path.GetDirectoryName(DataFolder)!, "Claude-3p");
        }
        else
        {
            foreach (var packages in SafeDirectories(Path.Combine(LocalAppData, "Packages"), "Claude*"))
                yield return Path.Combine(packages, "LocalCache", "Roaming", "Claude");
        }
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

    private bool IsClaudeExecutable(string? path) =>
        path is not null && ProgramFolders.Any(f => IsUnder(path, f))
        && System.IO.Path.GetFileName(path).Equals("claude.exe", StringComparison.OrdinalIgnoreCase);

    /// <summary>Claude's main processes: claude.exe whose parent is not itself claude.exe
    /// (Electron renderers and helpers are children of the main process).</summary>
    private List<ProcessInfo> MainProcesses()
    {
        var all = Snapshot(withPaths: true);
        var claude = all.Where(p => IsClaudeExecutable(p.Path)).ToList();
        var claudePids = claude.Select(p => p.Pid).ToHashSet();
        return claude.Where(p => !claudePids.Contains(p.ParentPid)).ToList();
    }

    public bool IsRunning => MainProcesses().Count > 0;

    /// <summary>Anything still running from Claude's program folder or data folder
    /// (helpers, local Claude Code sessions). The data folder can only be moved once none is left.</summary>
    public int LeftoverProcessCount() =>
        Snapshot(withPaths: true).Count(p => IsClaudeExecutable(p.Path) || IsUnder(p.Path, DataFolder));

    /// <summary>
    /// Asks Claude to close through the Restart Manager, the mechanism installers
    /// use: Claude receives the "please close" messages it would get when Windows
    /// shuts down, and is allowed to refuse. Never forced.
    /// </summary>
    /// <returns>true when Claude agreed to close.</returns>
    public unsafe bool RequestQuit()
    {
        var mains = MainProcesses();
        if (mains.Count == 0) return true;
        var key = stackalloc char[33];
        if (Native.RmStartSession(out var session, 0, key) != 0) return false;
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
            if (count == 0) return false;
            if (Native.RmRegisterResources(session, 0, 0, (uint)count, apps, 0, 0) != 0) return false;
            // flags 0: no RmForceShutdown. Returns an error if Claude declined.
            return Native.RmShutdown(session, 0, 0) == 0;
        }
        finally
        {
            Native.RmEndSession(session);
        }
    }

    public async Task OpenAsync()
    {
        try
        {
            if (IsPackaged && PackageFamilyName is not null)
            {
                var package = new PackageManager().FindPackagesForUser(string.Empty, PackageFamilyName).FirstOrDefault();
                if (package is not null)
                {
                    var entries = await package.GetAppListEntriesAsync();
                    if (entries.Count > 0) { await entries[0].LaunchAsync(); return; }
                }
            }
            if (LauncherPath is not null)
            {
                Process.Start(new ProcessStartInfo(LauncherPath) { UseShellExecute = true });
            }
        }
        catch (Exception e)
        {
            Debug.WriteLine($"Could not open Claude: {e.Message}");
        }
    }
}
