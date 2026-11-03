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
    /// <summary>Turning side by side off: waiting for the other profiles' Claudes to close.</summary>
    ClosingProfiles,
}

internal enum Page { Accounts, AddAccount, EditProfile, ConfirmRemove, Settings, ConfirmSideBySide, MoveChats, RestoreBackups }

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
    public static readonly Uri TermsUri = new("https://www.anthropic.com/legal/consumer-terms");

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
    /// <summary>A short, non-error message ("Chat copied", "Backup restored").</summary>
    public string? Notice { get; set; }
    public UpdateChecker.Update? AvailableUpdate { get; private set; }
    public ProfileRuntime Runtime { get; }
    public LinkRouter Router { get; }
    public bool SideBySide => Settings.SideBySide;
    /// <summary>Show the switcher (the App owns the window).</summary>
    public event Action? SwitcherRequested;
    /// <summary>Links waiting for a profile's Claude to start.</summary>
    private readonly Dictionary<Guid, string> pendingLinks = [];
    /// <summary>Watchdog: Claude's version when each unexpected exit happened.</summary>
    private readonly Dictionary<Guid, (string? Version, DateTimeOffset Since)> watchedExits = [];
    private DispatcherQueueTimer? watchdogTimer;

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
        Runtime = new ProfileRuntime(dispatcher, () => Claude, ProfileFor);
        Router = new LinkRouter(Settings);
    }

    /// <summary>Profiles live directly under %LOCALAPPDATA% (Cowork only finds them there).</summary>
    private static ClatchPaths PathsFor(ClaudeInstall claude) =>
        new(claude.DataFolder, Clatch.Settings.Folder, claude.ExtraDataFolders,
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));

    private static string Normalize(string path) => Path.GetFullPath(path).TrimEnd('\\');

    /// <summary>Which profile a running Claude belongs to, from its data folder (null: Claude's default).</summary>
    private Guid? ProfileFor(string? dataFolder)
    {
        if (dataFolder is null) return State.ActiveId;
        string wanted;
        try { wanted = Normalize(dataFolder); } catch (Exception) { return null; }
        foreach (var account in State.Accounts)
            if (string.Equals(Normalize(store.DataFolder(account.Id)), wanted, StringComparison.OrdinalIgnoreCase)) return account.Id;
        return null;
    }

    public bool IsRunning(Guid id) => Runtime.IsRunning(id);
    public Account? Account(Guid id) => State.Accounts.FirstOrDefault(a => a.Id == id);
    public string IconPath(Account account) => ProfileIcons.Png(account, Claude.Executable);

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
        if (!Claude.IsRunning)
        {
            var moved = store.MigrateLegacyProfiles();
            if (moved.Count > 0) Log.Write($"Moved {moved.Count} profile folder(s) directly under %LOCALAPPDATA%");
        }
        Runtime.Changed += RuntimeChanged;
        Runtime.UnexpectedExit += WatchUnexpectedExit;
        Runtime.WindowShown += ApplyTaskbarIdentity;
        Runtime.Start();
        SyncShortcuts();
        // Routing hygiene: claude:// must reach Claude whenever routing is off.
        if (Settings.RouteSignIns && SideBySide) Router.Enable();
        else if (LinkRouter.IsHandler()) Router.Disable();
        CheckForUpdates();
        Log.Write($"Mode: {(SideBySide ? "side by side" : "one at a time")}; {State.Accounts.Count} profile(s)");
    }

    public void PanelWillOpen()
    {
        Notice = null;
        CheckForUpdates();
        if (Phase != Phase.Idle) return;
        RefreshClaude("panel opened");
        FinishInterruptedSwitchIfPossible();
        Runtime.Rescan();
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

    public void Update(Account account) { Try(() => store.Update(account)); SyncShortcuts(); ShowPage(Page.Accounts); }
    public void Move(Guid id, int offset) => Try(() => store.Move(id, offset));

    public void Remove(Guid id)
    {
        if (IsRunning(id))
        {
            ErrorMessage = "Close this profile's Claude first.";
            ShowPage(Page.Accounts);
            return;
        }
        Try(() => store.Remove(id, Interop.Native.SendToRecycleBin));
        SyncShortcuts();
        ShowPage(Page.Accounts);
    }
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

    /// <summary>
    /// The main action for a profile (the menu, the switcher, a shortcut).
    /// One at a time: switch Claude to it. Side by side: bring its Claude to the front, or start it.
    /// </summary>
    public void Open(Guid id)
    {
        if (Account(id) is not { } account) return;
        if (SideBySide) _ = Launch(account);
        else if (id == State.ActiveId) _ = Launch(account);
        else Begin(new PendingOperation.SwitchTo(id));
    }

    private async Task Launch(Account account, bool activate = true)
    {
        var folder = account.Id == State.ActiveId ? null : store.DataFolder(account.Id);
        if (!HasSignIn(account.Id) && Settings.RouteSignIns) Router.ExpectSignIn(account.Id);
        var problem = await Runtime.LaunchOrFocus(account, folder, activate);
        if (problem is not null) { ErrorMessage = problem; Notify(); }
        store.MarkUsed(account.Id);
    }

    private bool HasSignIn(Guid id)
    {
        var folder = store.DataFolder(id);
        return File.Exists(Path.Combine(folder, "Network", "Cookies")) || File.Exists(Path.Combine(folder, "Cookies"));
    }

    public void CloseProfile(Guid id) => Runtime.Close(id);

    public void RestartProfile(Guid id)
    {
        if (Account(id) is not { } account) return;
        if (!IsRunning(id)) { Open(id); return; }
        Runtime.Close(id, () =>
        {
            var timer = dispatcher.CreateTimer();
            timer.Interval = TimeSpan.FromMilliseconds(500);
            timer.IsRepeating = false;
            timer.Tick += (_, _) => _ = Launch(account);
            timer.Start();
        });
    }

    public void SwitchTo(Guid id) => Open(id);

    public void AddAccount(string name, string? renameCurrentTo)
    {
        Page = Page.Accounts;
        if (SideBySide)
        {
            Account? created = null;
            Try(() =>
            {
                if (renameCurrentTo is { } rename && State.ActiveId is { } current) store.Rename(current, rename);
                created = store.CreateProfile(name);
            });
            if (created is null) return;
            Router.ExpectSignIn(created.Id);
            SyncShortcuts();
            _ = Launch(created);
            return;
        }
        Begin(new PendingOperation.AddAccount(name, renameCurrentTo));
    }

    public void HotKeyPressed()
    {
        if (IsBusy) return;
        store.Load();
        if (State.Accounts.Count > 1) SwitcherRequested?.Invoke();
        else PanelRequested?.Invoke();
    }

    /// <summary>The profile the switcher starts from (it highlights the next one).</summary>
    public Guid? CurrentForSwitcher() => SideBySide ? Runtime.LastActive ?? State.ActiveId : State.ActiveId;

    private void RuntimeChanged()
    {
        foreach (var (id, link) in pendingLinks.ToList())
        {
            if (!IsRunning(id)) continue;
            pendingLinks.Remove(id);
            var timer = dispatcher.CreateTimer();
            timer.Interval = TimeSpan.FromSeconds(2);
            timer.IsRepeating = false;
            timer.Tick += (_, _) => DeliverLink(id, link);
            timer.Start();
        }
        Notify();
    }

    // ---- Links (shortcuts and claude:// routing) -----------------------------------

    /// <summary>Arguments from the command line or forwarded by a second Clatch.exe.</summary>
    public void RunCommand(string[] args)
    {
        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i].ToLowerInvariant())
            {
                case "--launch" when i + 1 < args.Length && Guid.TryParse(args[i + 1], out var id):
                    Log.Write("A profile shortcut was opened");
                    Open(id);
                    return;
                case "--open-link" when i + 1 < args.Length:
                    HandleLink(args[i + 1]);
                    return;
                case "--add-account":
                    var name = i + 1 < args.Length ? args[i + 1] : "";
                    Log.Write($"Command line: add account \"{name}\"");
                    AddAccount(name, null);
                    return;
                case "--switch-next":
                    Log.Write("Command line: switch to next account");
                    store.Load();
                    if (State.Next is { } next) Open(next.Id);
                    return;
            }
        }
        PanelRequested?.Invoke();
    }

    private void HandleLink(string link)
    {
        if (!ClaudeLink.IsClaudeLink(link)) return;
        var target = SideBySide && Settings.RouteSignIns ? Router.Target(link, Runtime.LastActive, State.ActiveId) : State.ActiveId;
        if (target is not { } id || Account(id) is not { } account)
        {
            Log.Write($"Passing {ClaudeLink.Describe(link)} to Claude");
            Runtime.SendLink(link, null);
            return;
        }
        Log.Write($"Routing {ClaudeLink.Describe(link)} to a profile");
        if (ClaudeLink.IsSignIn(link)) Router.ClearPending();
        if (IsRunning(id)) DeliverLink(id, link);
        else
        {
            pendingLinks[id] = link;
            _ = Launch(account);
        }
    }

    private void DeliverLink(Guid id, string link)
    {
        var problem = Runtime.SendLink(link, store.DataFolder(id));
        if (problem is not null) { ErrorMessage = problem; Notify(); }
    }

    public void SetRouting(bool on)
    {
        Settings.RouteSignIns = on && SideBySide;
        Settings.Save();
        try
        {
            if (Settings.RouteSignIns) Router.Enable(); else Router.Disable();
            if (Settings.RouteSignIns && LinkRouter.ChoiceOverridesClatch())
                Notice = "Windows uses the app you once chose for claude:// links. Choose Clatch for claude in Settings › Apps › Default apps (button below).";
        }
        catch (Exception e) { ErrorMessage = e.Message; }
        Notify();
    }

    public static void OpenDefaultAppsSettings() =>
        OpenUri(new Uri("ms-settings:defaultapps?registeredAppUser=Clatch"));

    // ---- Taskbar identity ----------------------------------------------------------------

    private void ApplyTaskbarIdentity(Guid id, nint hwnd)
    {
        if (!SideBySide || !Settings.SeparateTaskbarButtons || Account(id) is not { } account) return;
        string icon;
        try { icon = ProfileIcons.Ico(account, Claude.Executable); } catch (Exception) { return; }
        var exe = Environment.ProcessPath!;
        Interop.Shell.SetWindowIdentity(hwnd, ProfileShortcuts.AppUserModelId(id), $"\"{exe}\" --launch {id:D}",
                                        $"Claude - {account.Name}", $"{icon},0");
    }

    // ---- Modes ------------------------------------------------------------------------

    public void RequestSideBySide(bool on)
    {
        if (on == SideBySide) return;
        if (on) ShowPage(Page.ConfirmSideBySide);
        else TurnSideBySideOff();
    }

    public void ConfirmSideBySide()
    {
        BackUpSignIns("Turning side by side on");
        Settings.SideBySide = true;
        Settings.Save();
        Runtime.Rescan();
        Log.Write("Side by side turned on");
        ShowPage(Page.Settings);
    }

    /// <summary>Closes every other profile's Claude politely, backs up the sign-ins, then
    /// goes back to one at a time. Every profile keeps its folder: nothing has to be signed in again.</summary>
    private void TurnSideBySideOff()
    {
        void Finish()
        {
            BackUpSignIns("Turning side by side off");
            Settings.SideBySide = false;
            Settings.Save();
            if (Settings.RouteSignIns) SetRouting(false);
            Log.Write("Side by side turned off");
            SetPhase(Phase.Idle);
        }
        Guid[] keep = State.ActiveId is { } active ? [active] : [];
        if (Runtime.Instances.Keys.All(keep.Contains)) { Finish(); return; }
        SetPhase(Phase.ClosingProfiles);
        Page = Page.Accounts;
        Runtime.CloseAll(keep, Finish);
    }

    public string BackupsFolder => Path.Combine(store.Paths.ClatchRoot, "Backups");

    public void BackUpSignIns(string reason)
    {
        var folders = State.Accounts.Where(a => !IsRunning(a.Id)).ToDictionary(a => a.Id, a => store.DataFolder(a.Id));
        try
        {
            if (SignInBackup.BackUp(folders, BackupsFolder, reason) is { } snapshot)
                Log.Write($"Backed up the sign-ins of {snapshot.Profiles.Count} profile(s): {reason}");
        }
        catch (Exception e) { Log.Error("backing up sign-ins", e); }
    }

    public List<SignInBackup.Snapshot> Backups() => SignInBackup.List(BackupsFolder);

    public void Restore(SignInBackup.Snapshot snapshot)
    {
        int restored = 0, skipped = 0;
        foreach (var id in snapshot.Profiles.Where(id => Account(id) is not null))
        {
            if (IsRunning(id)) { skipped++; continue; }
            try { SignInBackup.Restore(id, snapshot, store.DataFolder(id)); restored++; }
            catch (Exception e) { ErrorMessage = e.Message; }
        }
        Notice = $"Restored {restored} profile(s)." + (skipped > 0 ? $" {skipped} skipped because their Claude is open: close it and restore again." : "");
        ShowPage(Page.Accounts);
    }

    // ---- Code-tab chats ---------------------------------------------------------------

    /// <summary>A profile's session roots (the Store version may redirect part of them into its LocalCache).</summary>
    private IEnumerable<string> SessionRoots(Guid id)
    {
        var folder = store.DataFolder(id);
        yield return Path.Combine(folder, CodeSessions.FolderName);
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData).TrimEnd('\\') + "\\";
        if (Claude.IsPackaged && Claude.PackageFolder is { } package && folder.StartsWith(local, StringComparison.OrdinalIgnoreCase))
            yield return Path.Combine(package, "LocalCache", "Local", folder[local.Length..], CodeSessions.FolderName);
    }

    public List<CodeSession> CodeSessionsOf(Guid id) => CodeSessions.Discover(SessionRoots(id));

    public void CopySession(CodeSession session, Guid target)
    {
        if (Account(target) is not { } account) return;
        try
        {
            CodeSessions.Copy(session, SessionRoots(target), account.Name);
            Notice = $"Copied “{session.Title}” to {account.Name}." + (IsRunning(target) ? " Restart its Claude to see it." : "");
            ErrorMessage = null;
        }
        catch (Exception e) { ErrorMessage = e.Message; }
        Notify();
    }

    // ---- Watchdog ---------------------------------------------------------------------

    /// <summary>A profile's Claude ended on its own. If Claude got updated meanwhile, reopen it on the new version.</summary>
    private void WatchUnexpectedExit(Guid id)
    {
        if (!SideBySide || !Settings.Watchdog) return;
        watchedExits[id] = (ClaudeInstall.InstalledVersion(), DateTimeOffset.Now);
        if (watchdogTimer is not null) return;
        watchdogTimer = dispatcher.CreateTimer();
        watchdogTimer.Interval = TimeSpan.FromSeconds(3);
        watchdogTimer.Tick += (_, _) => CheckWatchedExits();
        watchdogTimer.Start();
    }

    private void CheckWatchedExits()
    {
        var now = DateTimeOffset.Now;
        var current = ClaudeInstall.InstalledVersion();
        foreach (var (id, exit) in watchedExits.ToList())
        {
            if (IsRunning(id) || now - exit.Since > TimeSpan.FromMinutes(3)) { watchedExits.Remove(id); continue; }
            if (current is null || current == exit.Version || now - exit.Since < TimeSpan.FromSeconds(6) || Account(id) is not { } account) continue;
            Log.Write($"Claude was updated to {current}; reopening a profile it closed");
            watchedExits.Remove(id);
            RefreshClaude("after a Claude update");
            _ = Launch(account, activate: false);
        }
        if (watchedExits.Count == 0) { watchdogTimer?.Stop(); watchdogTimer = null; }
    }

    // ---- Shortcuts and updates -----------------------------------------------------------

    public void SyncShortcuts()
    {
        try { ProfileShortcuts.Sync(State.Accounts, Settings.ProfileShortcuts, Claude.Executable); }
        catch (Exception e) { Log.Error("updating the profile shortcuts", e); }
    }

    public void SetProfileShortcuts(bool value) { Settings.ProfileShortcuts = value; Settings.Save(); SyncShortcuts(); }
    public void SetWatchdog(bool value) { Settings.Watchdog = value; Settings.Save(); }
    public void SetSeparateTaskbarButtons(bool value) { Settings.SeparateTaskbarButtons = value; Settings.Save(); }
    public void SetCheckForUpdates(bool value) { Settings.CheckForUpdates = value; Settings.Save(); }

    public void CheckForUpdates(bool force = false)
    {
        if (!force && (!Settings.CheckForUpdates || !UpdateChecker.IsDue(Settings))) return;
        var version = Version;
        Task.Run(async () =>
        {
            try
            {
                var update = await UpdateChecker.CheckAsync(version);
                dispatcher.TryEnqueue(() =>
                {
                    Settings.LastUpdateCheck = DateTimeOffset.Now;
                    Settings.Save();
                    AvailableUpdate = update;
                    if (force && update is null) Notice = "Clatch is up to date.";
                    Notify();
                });
            }
            catch (Exception e)
            {
                dispatcher.TryEnqueue(() =>
                {
                    if (force) { ErrorMessage = $"Could not check for updates: {e.Message}"; Notify(); }
                });
            }
        });
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
        if (Phase == Phase.ClosingProfiles)
        {
            Runtime.CancelClosing();
            SetPhase(Phase.Idle);
            return;
        }
        var reopen = claudeWasRunning && Phase is Phase.WaitingForHelpers or Phase.ConfirmLayout;
        Pending = null;
        QuitDeclined = false;
        SetPhase(Phase.Idle);
        if (reopen && !Claude.IsRunning && State.Active is { } active) _ = Launch(active);
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
        Runtime.Rescan();
        SyncShortcuts();
        if (openClaude && State.Active is { } nowActive) _ = Launch(nowActive);
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

    /// <summary>The version, with a prerelease suffix if this build is one (from the informational version).</summary>
    public static string Version
    {
        get
        {
            var info = typeof(AppModel).Assembly.GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
                .OfType<System.Reflection.AssemblyInformationalVersionAttribute>().FirstOrDefault()?.InformationalVersion;
            if (info is not null) return info.Split('+')[0];
            return typeof(AppModel).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "dev";
        }
    }
}
