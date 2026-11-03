// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using System.Diagnostics;
using System.Runtime.InteropServices;
using Clatch.Core;
using Clatch.Interop;
using Microsoft.UI.Dispatching;

namespace Clatch;

/// <summary>
/// Which Claude runs for which profile. Kept up to date without polling:
/// Windows tells Clatch when a profile's Claude ends (process exit wait), and
/// when any window is shown or brought to the front (a window event hook,
/// delivered on the UI thread). Side by side, it also starts, focuses,
/// closes and restarts each profile's Claude, and gives each profile's
/// windows their own taskbar button.
/// </summary>
internal sealed class ProfileRuntime : IDisposable
{
    public sealed record Instance(uint MainPid, IReadOnlyList<uint> Tree);

    private static ProfileRuntime? current;
    private readonly DispatcherQueue dispatcher;
    private readonly Func<ClaudeInstall> claude;
    private readonly Func<string?, Guid?> profileFor;
    private readonly Dictionary<Guid, Instance> instances = [];
    private readonly HashSet<uint> watchedMains = [];
    private readonly HashSet<Guid> closing = [];
    private readonly Dictionary<Guid, List<Action>> exitWaiters = [];
    private readonly Dictionary<uint, bool> isClaudeCache = [];
    private nint showHook, foregroundHook;
    private bool rescanQueued;

    /// <summary>Something started or ended.</summary>
    public event Action? Changed;
    /// <summary>A profile's Claude ended without Clatch asking (the watchdog listens).</summary>
    public event Action<Guid>? UnexpectedExit;
    /// <summary>A window of a profile's Claude was shown (for its taskbar identity).</summary>
    public event Action<Guid, nint>? WindowShown;

    /// <summary>The profile whose Claude was in front most recently.</summary>
    public Guid? LastActive { get; private set; }

    public ProfileRuntime(DispatcherQueue dispatcher, Func<ClaudeInstall> claude, Func<string?, Guid?> profileFor)
    {
        this.dispatcher = dispatcher;
        this.claude = claude;
        this.profileFor = profileFor;
    }

    public unsafe void Start()
    {
        current = this;
        showHook = Shell.SetWinEventHook(Shell.EVENT_OBJECT_SHOW, Shell.EVENT_OBJECT_SHOW, 0, &OnWinEvent, 0, 0,
                                         Shell.WINEVENT_OUTOFCONTEXT | Shell.WINEVENT_SKIPOWNPROCESS);
        foregroundHook = Shell.SetWinEventHook(Shell.EVENT_SYSTEM_FOREGROUND, Shell.EVENT_SYSTEM_FOREGROUND, 0, &OnWinEvent, 0, 0,
                                               Shell.WINEVENT_OUTOFCONTEXT | Shell.WINEVENT_SKIPOWNPROCESS);
        Rescan();
    }

    public IReadOnlyDictionary<Guid, Instance> Instances => instances;
    public bool IsRunning(Guid id) => instances.ContainsKey(id);

    /// <summary>Re-reads every running Claude (at start, when the profiles change, when an unknown Claude window appears).</summary>
    public void Rescan()
    {
        rescanQueued = false;
        var found = new Dictionary<Guid, Instance>();
        foreach (var running in claude().RunningInstances())
        {
            if (profileFor(running.DataFolder) is not { } id) continue;
            found[id] = new Instance(running.MainPid, running.Tree);
            Watch(id, running.MainPid);
        }
        instances.Clear();
        foreach (var (id, instance) in found) instances[id] = instance;
        Changed?.Invoke();
    }

    private void QueueRescan()
    {
        if (rescanQueued) return;
        rescanQueued = true;
        var timer = dispatcher.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(400);
        timer.IsRepeating = false;
        timer.Tick += (_, _) => Rescan();
        timer.Start();
    }

    /// <summary>Waits for a main process to end with Windows' exit notification (no polling).</summary>
    private void Watch(Guid id, uint mainPid)
    {
        if (!watchedMains.Add(mainPid)) return;
        Process process;
        try { process = Process.GetProcessById((int)mainPid); }
        catch (ArgumentException) { watchedMains.Remove(mainPid); return; }
        process.WaitForExitAsync().ContinueWith(_ =>
        {
            process.Dispose();
            dispatcher.TryEnqueue(() => Ended(mainPid));
        });
    }

    private void Ended(uint mainPid)
    {
        watchedMains.Remove(mainPid);
        var match = instances.FirstOrDefault(kv => kv.Value.MainPid == mainPid);
        if (match.Value is null) return;
        var id = match.Key;
        instances.Remove(id);
        var expected = closing.Remove(id);
        Log.Write($"A profile's Claude ended ({(expected ? "closed by Clatch" : "on its own")})");
        if (!expected) UnexpectedExit?.Invoke(id);
        if (exitWaiters.Remove(id, out var waiters)) foreach (var waiter in waiters) waiter();
        Changed?.Invoke();
    }

    // ---- Window events ------------------------------------------------------------

    [UnmanagedCallersOnly]
    private static void OnWinEvent(nint hook, uint eventType, nint hwnd, int idObject, int idChild, uint thread, uint time)
    {
        var runtime = current;
        if (runtime is null || hwnd == 0 || idObject != Shell.OBJID_WINDOW || idChild != 0) return;
        try { runtime.WindowEvent(eventType, hwnd); }
        catch (Exception e) { Log.Error("window event", e); }
    }

    private void WindowEvent(uint eventType, nint hwnd)
    {
        if (Shell.GetAncestor(hwnd, Shell.GA_ROOT) != hwnd) return;
        Native.GetWindowThreadProcessId(hwnd, out var pid);
        var owner = instances.FirstOrDefault(kv => kv.Value.Tree.Contains(pid));
        if (eventType == Shell.EVENT_SYSTEM_FOREGROUND)
        {
            if (owner.Value is not null) LastActive = owner.Key;
            return;
        }
        if (owner.Value is not null)
        {
            WindowShown?.Invoke(owner.Key, hwnd);
            return;
        }
        // A window of a Claude Clatch does not know yet (started from elsewhere): look again shortly.
        if (!isClaudeCache.TryGetValue(pid, out var isClaude))
        {
            isClaude = claude().IsClaudeProcessId(pid);
            if (isClaudeCache.Count > 512) isClaudeCache.Clear();
            isClaudeCache[pid] = isClaude;
        }
        if (isClaude) QueueRescan();
    }

    // ---- Side by side -------------------------------------------------------------------

    /// <summary>Brings a profile's Claude to the front, or starts it.</summary>
    /// <param name="dataFolder">The profile's folder; null: Claude's own folder.</param>
    public async Task<string?> LaunchOrFocus(Account account, string? dataFolder, bool activate = true)
    {
        if (instances.TryGetValue(account.Id, out var running))
        {
            if (activate) Focus(running);
            return null;
        }
        var install = claude();
        var plain = dataFolder is null && account.Environment.Count == 0 && account.Arguments.Count == 0;
        if (plain)
        {
            // Claude's own folder, nothing special: start it the usual way (keeps its package identity).
            await install.OpenAsync();
            QueueRescan();
            return null;
        }
        var exe = install.Executable;
        if (exe is null) return "Claude Desktop was not found.";
        var folder = dataFolder ?? install.DataFolder;
        Directory.CreateDirectory(folder);
        var start = new ProcessStartInfo(exe) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(exe)! };
        start.ArgumentList.Add($"--user-data-dir={folder}");
        foreach (var argument in account.Arguments.Where(a => LaunchOptions.Problems([a]).Count == 0)) start.ArgumentList.Add(argument);
        foreach (var (key, value) in account.Environment) start.Environment[key] = value;
        try
        {
            using var process = Process.Start(start);
            Log.Write($"Started Claude for a profile{(dataFolder is null ? " (Claude's own folder)" : "")}");
        }
        catch (Exception e)
        {
            Log.Error("starting Claude", e);
            return $"Claude could not be started: {e.Message}";
        }
        QueueRescan();
        return null;
    }

    /// <summary>Gives a link to a profile's Claude (it reaches the running one through Electron's single-instance handoff).</summary>
    public string? SendLink(string link, string? dataFolder)
    {
        var install = claude();
        var exe = install.Executable;
        if (exe is null) return "Claude Desktop was not found.";
        var start = new ProcessStartInfo(exe) { UseShellExecute = false };
        start.ArgumentList.Add($"--user-data-dir={dataFolder ?? install.DataFolder}");
        start.ArgumentList.Add(link);
        try { using var _ = Process.Start(start); return null; }
        catch (Exception e) { return $"Could not hand the link to Claude: {e.Message}"; }
    }

    private static void Focus(Instance instance)
    {
        var windows = ClaudeInstall.WindowsOf([.. instance.Tree])
            .Where(h => Shell.IsWindowVisible(h) && Shell.GetWindow(h, Shell.GW_OWNER) == 0 && Shell.GetWindowTextLengthW(h) > 0)
            .ToList();
        if (windows.Count == 0) return;
        var window = windows[0];
        if (Shell.IsIconic(window)) Shell.ShowWindow(window, Shell.SW_RESTORE);
        Native.SetForegroundWindow(window);
    }

    /// <summary>Asks a profile's Claude to close (it may ask the user first; never forced).</summary>
    public void Close(Guid id, Action? then = null)
    {
        if (!instances.TryGetValue(id, out var instance)) { then?.Invoke(); return; }
        closing.Add(id);
        if (then is not null)
        {
            if (!exitWaiters.TryGetValue(id, out var list)) exitWaiters[id] = list = [];
            list.Add(then);
        }
        var install = claude();
        var main = new[] { instance.MainPid };
        Task.Run(() =>
        {
            var result = install.RequestQuit(main);
            if (result != 0) install.RequestQuitBySessionEnd(main);
        });
    }

    /// <summary>Asks every profile's Claude except <paramref name="keep"/> to close; then runs once all ended.</summary>
    public void CloseAll(IReadOnlyCollection<Guid> keep, Action then)
    {
        var targets = instances.Keys.Where(id => !keep.Contains(id)).ToList();
        if (targets.Count == 0) { then(); return; }
        var remaining = targets.Count;
        foreach (var id in targets) Close(id, () => { if (--remaining == 0) then(); });
    }

    public void CancelClosing()
    {
        closing.Clear();
        exitWaiters.Clear();
    }

    public void Dispose()
    {
        if (showHook != 0) Shell.UnhookWinEvent(showHook);
        if (foregroundHook != 0) Shell.UnhookWinEvent(foregroundHook);
        showHook = foregroundHook = 0;
        current = null;
    }
}
