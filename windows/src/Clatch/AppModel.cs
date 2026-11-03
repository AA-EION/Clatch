// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using System.Diagnostics;
using Clatch.Core;
using Microsoft.UI.Dispatching;

namespace Clatch;

internal enum Phase
{
    Idle,
    /// <summary>Claude was asked to close and has not closed yet.</summary>
    WaitingForClaude,
    /// <summary>Claude's main window is gone; helpers or sessions are still exiting.</summary>
    WaitingForHelpers,
    /// <summary>Claude's data folder looks different from what Clatch expects. Nothing moved yet.</summary>
    ConfirmLayout,
    Switching,
}

internal enum Page { Accounts, AddAccount, Rename, ConfirmRemove, Settings }

internal abstract record PendingOperation
{
    public sealed record SwitchTo(Guid Id) : PendingOperation;
    public sealed record AddAccount(string Name, string? RenameCurrentTo) : PendingOperation;
}

/// <summary>
/// The app's single source of truth, on the UI thread. Holds no timer while
/// idle: the only background work happens during a switch.
/// </summary>
internal sealed class AppModel
{
    public static readonly Uri DonateUri = new("https://www.paypal.com/donate/?business=juanesgtgt2%40gmail.com&no_recurring=0&item_name=Issen+Software+Group");
    public static readonly Uri ProjectUri = new("https://github.com/AA-EION/Clatch");

    private readonly DispatcherQueue dispatcher;
    private AccountStore store;
    private DispatcherQueueTimer? pollTimer;
    private bool claudeWasRunning;
    /// <summary>Bumped by every new switch or cancel, so late notifications from an old one are ignored.</summary>
    private int generation;
    private DateTimeOffset quitRequestedAt;
    private int moveAttempts;
    private int lastLeftovers = -1;
    private DateTimeOffset phaseSince = DateTimeOffset.Now;

    public Settings Settings { get; }
    public ClaudeInstall Claude { get; private set; }
    public AccountsState State => store.State;
    public Phase Phase { get; private set; } = Phase.Idle;
    public PendingOperation? Pending { get; private set; }
    public IReadOnlyList<string> LayoutProblems { get; private set; } = [];
    /// <summary>Claude refused the close request (the user said no in its dialog, or it ignored it).</summary>
    public bool QuitDeclined { get; private set; }
    public string? ErrorMessage { get; set; }
    public Page Page { get; set; } = Page.Accounts;
    public Guid? PageAccount { get; set; }
    public bool HotKeyRegistered { get; private set; } = true;

    /// <summary>Anything changed: the open panel redraws.</summary>
    public event Action? Changed;
    /// <summary>Show the panel (the shortcut found nothing to switch to, or a decision is needed).</summary>
    public event Action? PanelRequested;
    /// <summary>Re-register the global shortcut (true when it worked).</summary>
    public Func<KeyCombo?, bool>? RegisterHotKey { get; set; }

    public AppModel(DispatcherQueue dispatcher)
    {
        this.dispatcher = dispatcher;
        Settings = Settings.Load();
        ClaudeInstall.LastSeenExecutable = Settings.LastClaudeExecutable;
        ClaudeInstall.LastSeenDataFolder = Settings.LastClaudeDataFolder;
        Claude = ClaudeInstall.Detect();
        store = new AccountStore(PathsFor(Claude), SharedItems);
    }

    private static ClatchPaths PathsFor(ClaudeInstall claude) =>
        new(claude.DataFolder, Clatch.Settings.Folder, claude.ExtraDataFolders);

    /// <summary>Re-detects Claude and points the account store at the data folder in use.</summary>
    private void RefreshClaude(string why)
    {
        Claude = ClaudeInstall.Detect();
        var paths = PathsFor(Claude);
        if (paths.Signature != store.Paths.Signature)
        {
            Log.Write($"Claude's data folders are now {paths.Signature} (were {store.Paths.Signature})");
            store = new AccountStore(paths, SharedItems);
        }
        else
        {
            store.Load();
        }
        if ((ClaudeInstall.LastSeenExecutable is { } exe && exe != Settings.LastClaudeExecutable)
            || (ClaudeInstall.LastSeenDataFolder is { } dataDir && dataDir != Settings.LastClaudeDataFolder))
        {
            Settings.LastClaudeExecutable = ClaudeInstall.LastSeenExecutable ?? Settings.LastClaudeExecutable;
            Settings.LastClaudeDataFolder = ClaudeInstall.LastSeenDataFolder ?? Settings.LastClaudeDataFolder;
            Settings.Save();
        }
        Log.Write($"Claude ({why}): installed={Claude.IsInstalled} packaged={Claude.IsPackaged} via {Claude.How}; " +
                  $"family={Claude.PackageFamilyName ?? "-"}; folders: {Claude.DescribeFolders()}; package: {Claude.DescribePackageFolders()}");
    }

    private IReadOnlyList<string> SharedItems => Settings.ShareToolSettings ? AccountStore.DefaultSharedItems : [];

    public void Start()
    {
        HotKeyRegistered = RegisterHotKey?.Invoke(Settings.EffectiveHotKey) ?? false;
        FinishInterruptedSwitchIfPossible();
    }

    public void PanelWillOpen()
    {
        if (Phase != Phase.Idle) return;
        RefreshClaude("panel opened");
        FinishInterruptedSwitchIfPossible();
    }

    public void PanelDidClose()
    {
        if (Phase == Phase.Idle) Page = Page.Accounts;
    }

    private void Notify() => Changed?.Invoke();

    private void FinishInterruptedSwitchIfPossible()
    {
        if (!store.HasInterruptedSwitch || Claude.IsRunning) return;
        Try(store.RecoverInterruptedSwitch);
    }

    private void Try(Action action)
    {
        try
        {
            action();
            ErrorMessage = null;
        }
        catch (Exception e)
        {
            ErrorMessage = e.Message;
        }
        Notify();
    }

    // ---- Editing --------------------------------------------------------------

    public void Rename(Guid id, string name) { Try(() => store.Rename(id, name)); ShowPage(Page.Accounts); }
    public void Move(Guid id, int offset) => Try(() => store.Move(id, offset));
    public void Remove(Guid id) { Try(() => store.Remove(id, Interop.Native.SendToRecycleBin)); ShowPage(Page.Accounts); }
    public string SuggestedNewName() => store.SuggestedNewName();
    public bool HasStoredData(Guid id) => store.HasStoredData(id);
    public string AccountsFolder => store.Paths.ClatchRoot;

    public void ShowPage(Page page, Guid? account = null)
    {
        Page = page;
        PageAccount = account;
        Notify();
    }

    // ---- Switching ------------------------------------------------------------

    public bool IsBusy => Phase != Phase.Idle;

    public void SwitchTo(Guid id)
    {
        if (id != State.ActiveId) Begin(new PendingOperation.SwitchTo(id));
    }

    public void AddAccount(string name, string? renameCurrentTo)
    {
        Page = Page.Accounts;
        Begin(new PendingOperation.AddAccount(name, renameCurrentTo));
    }

    public void HotKeyPressed()
    {
        if (IsBusy) return;
        store.Load();
        if (State.Next is { } next) SwitchTo(next.Id);
        else PanelRequested?.Invoke();
    }

    private void Begin(PendingOperation operation)
    {
        if (IsBusy) return;
        ErrorMessage = null;
        Pending = operation;
        RefreshClaude("switch requested");
        claudeWasRunning = Claude.IsRunning;
        try
        {
            var credentials = Interop.Native.ClaudeCredentialNames();
            Log.Write($"Saved Windows credentials mentioning Claude: {(credentials.Count == 0 ? "none" : string.Join("; ", credentials))}");
        }
        catch (Exception e) { Log.Write($"Could not list saved credentials: {e.Message}"); }
        Log.Write($"Switch requested: {Describe(operation)}; active={State.Active?.Name}; Claude running={claudeWasRunning} [{Claude.DescribeRunning()}]");
        generation++;
        moveAttempts = 0;
        if (claudeWasRunning)
        {
            SetPhase(Phase.WaitingForClaude);
            WatchClaudeExit(Claude.ProcessTree());
            AskClaudeToQuit();
            // A slow safety net only: the exit notifications do the real work.
            StartPolling(TimeSpan.FromSeconds(1));
        }
        else
        {
            SetPhase(Phase.WaitingForHelpers);
            StartPolling(TimeSpan.FromMilliseconds(150));
        }
    }

    private string Describe(PendingOperation operation) => operation switch
    {
        PendingOperation.SwitchTo s => $"switch to {State.Accounts.FirstOrDefault(a => a.Id == s.Id)?.Name ?? s.Id.ToString()}",
        PendingOperation.AddAccount a => $"add account \"{a.Name}\"",
        _ => operation.ToString(),
    };

    private void SetPhase(Phase phase)
    {
        if (phase != Phase) Log.Write($"Phase {Phase} -> {phase}");
        Phase = phase;
        phaseSince = DateTimeOffset.Now;
        Notify();
    }

    /// <summary>Restart Manager blocks while Claude decides, so it runs off the UI thread.</summary>
    /// <summary>
    /// Waits on Claude's processes with Windows' own exit notifications (no
    /// polling): the moment the last one ends, the switch continues.
    /// </summary>
    private void WatchClaudeExit(List<uint> pids)
    {
        var mine = generation;
        var processes = new List<Process>();
        foreach (var pid in pids)
        {
            try { processes.Add(Process.GetProcessById((int)pid)); }
            catch (ArgumentException) { } // already gone
            catch (InvalidOperationException) { }
        }
        Log.Write($"Watching {processes.Count} Claude process(es) for exit");
        Task.WhenAll(processes.Select(p => p.WaitForExitAsync())).ContinueWith(_ =>
        {
            foreach (var p in processes) p.Dispose();
            dispatcher.TryEnqueue(() =>
            {
                if (mine != generation || Phase != Phase.WaitingForClaude) return;
                Log.Write($"Claude closed ({(DateTimeOffset.Now - quitRequestedAt).TotalMilliseconds:N0} ms after the request)");
                OnClaudeClosed();
            });
        });
    }

    private void OnClaudeClosed()
    {
        SetPhase(Phase.WaitingForHelpers);
        StartPolling(TimeSpan.FromMilliseconds(150));
        Poll();
    }

    public void AskClaudeToQuit()
    {
        QuitDeclined = false;
        quitRequestedAt = DateTimeOffset.Now;
        var install = Claude;
        Task.Run(() =>
        {
            int result;
            try { result = install.RequestQuit(); }
            catch (Exception e) { Log.Error("asking Claude to close", e); result = -1; }
            Log.Write($"Asked Claude to close (Restart Manager): result={result}");
            if (result != 0)
            {
                try { result = install.RequestQuitBySessionEnd() ? 0 : result; }
                catch (Exception e) { Log.Error("session-end fallback", e); }
            }
            var agreed = result == 0;
            dispatcher.TryEnqueue(() =>
            {
                if (!agreed && Phase == Phase.WaitingForClaude)
                {
                    QuitDeclined = true;
                    Notify();
                }
            });
        });
    }

    public void CancelSwitch()
    {
        generation++;
        StopPolling();
        var reopen = claudeWasRunning && Phase is Phase.WaitingForHelpers or Phase.ConfirmLayout;
        Pending = null;
        QuitDeclined = false;
        SetPhase(Phase.Idle);
        if (reopen && !Claude.IsRunning) _ = Claude.OpenAsync();
    }

    public void ContinueDespiteLayout()
    {
        if (Phase == Phase.ConfirmLayout) Commit(layoutConfirmed: true);
    }

    private void StartPolling(TimeSpan interval)
    {
        StopPolling();
        pollTimer = dispatcher.CreateTimer();
        pollTimer.Interval = interval;
        pollTimer.Tick += (_, _) => Poll();
        pollTimer.Start();
    }

    private void StopPolling()
    {
        pollTimer?.Stop();
        pollTimer = null;
    }

    private void Poll()
    {
        switch (Phase)
        {
            case Phase.WaitingForClaude:
                // Safety net (e.g. Claude was restarted meanwhile): the exit
                // notifications normally get here first.
                if (!Claude.IsRunning) OnClaudeClosed();
                break;
            case Phase.WaitingForHelpers:
                // Only programs running from the data folder itself can hold it
                // (local sessions); anything else holding a file just makes the
                // move fail harmlessly, and it is retried (see Commit).
                var leftovers = Claude.DataFolderProcessCount();
                if (leftovers != lastLeftovers) { Log.Write($"Processes running from Claude's data folder: {leftovers}"); lastLeftovers = leftovers; }
                if (leftovers == 0 && DateTimeOffset.Now - phaseSince > TimeSpan.FromMilliseconds(150))
                    Commit(layoutConfirmed: false);
                break;
            default:
                StopPolling();
                break;
        }
    }

    private void Commit(bool layoutConfirmed)
    {
        StopPolling();
        if (Pending is not { } operation)
        {
            SetPhase(Phase.Idle);
            return;
        }

        if (!layoutConfirmed)
        {
            var check = DataLayoutCheck.Inspect(Claude.DataFolder, claudeWasRunning, Claude.AlternativeDataFolders());
            if (!check.IsRecognized)
            {
                Log.Write("Data layout not recognized: " + string.Join(" | ", check.Problems));
                LayoutProblems = check.Problems;
                SetPhase(Phase.ConfirmLayout);
                PanelRequested?.Invoke();
                return;
            }
        }

        // Last line of defence: never move anything while any Claude process
        // runs. Chromium opens its files so that Windows still lets the folder
        // be renamed, so a running Claude would keep its session in memory
        // and simply come back to the front on the same account.
        var stillRunning = Claude.IsRunning ? 1 : Claude.DataFolderProcessCount();
        if (stillRunning > 0)
        {
            Log.Write($"Not switching yet: {stillRunning} Claude process(es) still running [{Claude.DescribeRunning()}]");
            claudeWasRunning = true;
            SetPhase(Phase.WaitingForClaude);
            WatchClaudeExit(Claude.ProcessTree());
            AskClaudeToQuit();
            StartPolling(TimeSpan.FromSeconds(1));
            return;
        }

        SetPhase(Phase.Switching);
        store.SharedItems = SharedItems;
        var openClaude = claudeWasRunning && Settings.ReopenClaude;
        try
        {
            Log.Write($"Moving data: {string.Join(", ", store.Paths.Folders.Select(f => $"{f.Key}={f.Live} (exists={Directory.Exists(f.Live)})"))}; accounts={store.Paths.AccountsFolder}");
            store.RecoverInterruptedSwitch();
            switch (operation)
            {
                case PendingOperation.SwitchTo s:
                    store.SwitchTo(s.Id);
                    break;
                case PendingOperation.AddAccount a:
                    if (a.RenameCurrentTo is { } rename && State.ActiveId is { } current) store.Rename(current, rename);
                    store.AddAccount(a.Name);
                    openClaude = true; // Claude opens fresh and asks for a sign-in.
                    break;
            }
            ErrorMessage = null;
            Log.Write($"Switched: active={State.Active?.Name}; folders now: {Claude.DescribeFolders()}");
        }
        catch (AccountStoreException e) when (e.InnerException is IOException or UnauthorizedAccessException
                                              && !store.HasInterruptedSwitch && moveAttempts < 40)
        {
            // Nothing moved: something (often Windows itself, right after Claude
            // exits) still holds a file. Try again shortly instead of failing.
            moveAttempts++;
            if (moveAttempts == 1 || moveAttempts % 10 == 0)
                Log.Write($"Claude's files still in use, retrying ({moveAttempts}): {e.InnerException?.Message}");
            Phase = Phase.WaitingForHelpers;
            Notify();
            var retry = dispatcher.CreateTimer();
            retry.Interval = TimeSpan.FromMilliseconds(500);
            retry.IsRepeating = false;
            var mine = generation;
            retry.Tick += (_, _) => { if (mine == generation && Pending is not null) Commit(layoutConfirmed: true); };
            retry.Start();
            return;
        }
        catch (Exception e)
        {
            Log.Error("switching", e);
            ErrorMessage = e.Message;
            openClaude = claudeWasRunning; // Nothing switched: give Claude back.
        }
        Pending = null;
        LayoutProblems = [];
        if (openClaude) _ = Claude.OpenAsync();
        SetPhase(Phase.Idle);
    }

    // ---- Settings -------------------------------------------------------------

    public void SetHotKey(KeyCombo? combo)
    {
        Settings.HotKey = combo ?? Settings.HotKey;
        Settings.HotKeyDisabled = combo is null;
        Settings.Save();
        HotKeyRegistered = RegisterHotKey?.Invoke(Settings.EffectiveHotKey) ?? false;
        Notify();
    }

    public void SuspendHotKey() => RegisterHotKey?.Invoke(null);
    public void ResumeHotKey() { HotKeyRegistered = RegisterHotKey?.Invoke(Settings.EffectiveHotKey) ?? false; Notify(); }

    public void SetReopenClaude(bool value) { Settings.ReopenClaude = value; Settings.Save(); }
    public void SetShareToolSettings(bool value) { Settings.ShareToolSettings = value; Settings.Save(); store.SharedItems = SharedItems; }

    public void SetStartAtLogin(bool value)
    {
        try { StartAtLogin.Set(value); }
        catch (Exception e) { ErrorMessage = e.Message; Notify(); }
    }

    public static void OpenUri(Uri uri)
    {
        try { Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true }); }
        catch (Exception e) { Debug.WriteLine(e); }
    }

    public void OpenLog()
    {
        try { Process.Start(new ProcessStartInfo(Log.FilePath) { UseShellExecute = true }); }
        catch (Exception e) { Debug.WriteLine(e); }
    }

    public void RevealAccountsFolder()
    {
        Directory.CreateDirectory(AccountsFolder);
        try { Process.Start(new ProcessStartInfo("explorer.exe", $"\"{AccountsFolder}\"") { UseShellExecute = true }); }
        catch (Exception e) { Debug.WriteLine(e); }
    }

    public static string Version =>
        typeof(AppModel).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "dev";
}
