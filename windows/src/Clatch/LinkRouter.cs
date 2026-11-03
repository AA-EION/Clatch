// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using System.Runtime.InteropServices;
using Clatch.Core;
using Microsoft.Win32;

namespace Clatch;

/// <summary>
/// Sign-in routing for profiles running side by side.
/// </summary>
/// <remarks>
/// Signing in finishes in the browser, which hands a claude:// link back to
/// Claude. With several Claudes open, the link would reach whichever Claude
/// Windows starts, often the wrong profile. With routing on, Clatch is the
/// handler for claude:// links (per user, in HKCU\Software\Classes\claude):
/// a sign-in goes to the profile waiting for one (a profile just added), else
/// to the Claude used most recently; it is handed to that profile's Claude
/// with --user-data-dir, which Electron delivers to the running instance.
///
/// Claude may register itself again when it starts; Clatch watches the key
/// (RegNotifyChangeKeyValue, no polling) and puts itself back, keeping
/// Claude's newest handler as the one to restore. Turning routing off
/// restores Claude's handler. If the user once picked a default app for
/// claude:// in Windows' settings, Windows uses that choice instead, and the
/// user has to pick Clatch there once (Settings › Apps › Default apps).
///
/// Link contents are never logged: a sign-in link carries a one-time code.
/// </remarks>
internal sealed partial class LinkRouter : IDisposable
{
    private const string ClassesKey = @"Software\Classes\claude";
    private const string CommandKey = @"Software\Classes\claude\shell\open\command";
    private const string ProgId = "Clatch.claude";
    private static readonly TimeSpan PendingWindow = TimeSpan.FromMinutes(15);

    private readonly Settings settings;
    private Thread? watcher;
    private volatile bool watching;
    private AutoResetEvent? stopWatching;

    public (Guid Id, DateTimeOffset Until)? Pending { get; private set; }

    public LinkRouter(Settings settings) => this.settings = settings;

    public void ExpectSignIn(Guid id) => Pending = (id, DateTimeOffset.Now + PendingWindow);
    public void ClearPending() => Pending = null;

    public Guid? Target(string link, Guid? lastActive, Guid? active)
    {
        if (ClaudeLink.IsSignIn(link) && Pending is { } pending && pending.Until > DateTimeOffset.Now) return pending.Id;
        return lastActive ?? active;
    }

    private static string OurCommand => $"\"{Environment.ProcessPath}\" --open-link \"%1\"";

    /// <summary>Whether Windows would hand claude:// links to Clatch right now.</summary>
    public static bool IsHandler()
    {
        using var command = Registry.CurrentUser.OpenSubKey(CommandKey);
        return (command?.GetValue(null) as string)?.Equals(OurCommand, StringComparison.OrdinalIgnoreCase) == true;
    }

    /// <summary>The ProgId the user picked for claude:// in Windows' settings, if any.</summary>
    public static string? UserChoice()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\Shell\Associations\UrlAssociations\claude\UserChoice");
        return key?.GetValue("ProgId") as string;
    }

    /// <summary>True when a choice made in Windows' settings overrides Clatch.</summary>
    public static bool ChoiceOverridesClatch() => UserChoice() is { } choice && !choice.Equals(ProgId, StringComparison.OrdinalIgnoreCase);

    public void Enable()
    {
        using (var command = Registry.CurrentUser.OpenSubKey(CommandKey))
        {
            var current = command?.GetValue(null) as string;
            if (current is not null && !current.Equals(OurCommand, StringComparison.OrdinalIgnoreCase))
            {
                settings.ClaudeLinkCommandBackup = current;
                settings.Save();
            }
        }
        Apply();
        StartWatching();
        Log.Write("claude:// links now go to Clatch (routing on)");
    }

    public void Disable()
    {
        StopWatching();
        if (settings.ClaudeLinkCommandBackup is { } backup)
        {
            using var command = Registry.CurrentUser.CreateSubKey(CommandKey);
            command.SetValue(null, backup);
        }
        else if (IsHandler())
        {
            Registry.CurrentUser.DeleteSubKeyTree(ClassesKey, throwOnMissingSubKey: false);
        }
        Registry.CurrentUser.DeleteSubKeyTree(@"Software\Classes\" + ProgId, throwOnMissingSubKey: false);
        Registry.CurrentUser.DeleteSubKeyTree(@"Software\Clatch\Capabilities", throwOnMissingSubKey: false);
        using (var registered = Registry.CurrentUser.OpenSubKey(@"Software\RegisteredApplications", writable: true))
            registered?.DeleteValue("Clatch", throwOnMissingValue: false);
        Log.Write("claude:// links go to Claude again");
    }

    private void Apply()
    {
        using (var key = Registry.CurrentUser.CreateSubKey(ClassesKey))
        {
            key.SetValue(null, "URL:Claude");
            key.SetValue("URL Protocol", "");
        }
        using (var command = Registry.CurrentUser.CreateSubKey(CommandKey)) command.SetValue(null, OurCommand);
        // Also register Clatch as an app that can be picked for claude:// in Default apps.
        using (var progId = Registry.CurrentUser.CreateSubKey(@"Software\Classes\" + ProgId))
        {
            progId.SetValue(null, "Claude link (Clatch)");
            using var command = progId.CreateSubKey(@"shell\open\command");
            command.SetValue(null, OurCommand);
        }
        using (var capabilities = Registry.CurrentUser.CreateSubKey(@"Software\Clatch\Capabilities"))
        {
            capabilities.SetValue("ApplicationName", "Clatch");
            capabilities.SetValue("ApplicationDescription", "Sends Claude sign-ins to the profile that asked for them.");
            using var urls = capabilities.CreateSubKey("URLAssociations");
            urls.SetValue("claude", ProgId);
        }
        using (var registered = Registry.CurrentUser.CreateSubKey(@"Software\RegisteredApplications"))
            registered.SetValue("Clatch", @"Software\Clatch\Capabilities");
    }

    // ---- Watching the key (Claude re-registers itself on start) ------------------------

    private void StartWatching()
    {
        if (watching) return;
        watching = true;
        stopWatching = new AutoResetEvent(false);
        watcher = new Thread(WatchLoop) { IsBackground = true, Name = "claude:// handler watch" };
        watcher.Start();
    }

    private void StopWatching()
    {
        watching = false;
        stopWatching?.Set();
        watcher?.Join(2000);
        watcher = null;
    }

    private void WatchLoop()
    {
        using var changed = new AutoResetEvent(false);
        while (watching)
        {
            using var key = Registry.CurrentUser.CreateSubKey(ClassesKey);
            if (RegNotifyChangeKeyValue(key.Handle.DangerousGetHandle(), true, REG_NOTIFY_CHANGE_LAST_SET | REG_NOTIFY_CHANGE_NAME,
                                        changed.SafeWaitHandle.DangerousGetHandle(), true) != 0) return;
            var which = WaitHandle.WaitAny([changed, stopWatching!]);
            if (which != 0 || !watching) return;
            Thread.Sleep(300); // let the writer finish
            using var command = Registry.CurrentUser.OpenSubKey(CommandKey);
            var current = command?.GetValue(null) as string;
            if (current is not null && !current.Equals(OurCommand, StringComparison.OrdinalIgnoreCase))
            {
                settings.ClaudeLinkCommandBackup = current;
                settings.Save();
                Apply();
                Log.Write("Claude registered itself for claude:// again; routing restored (its handler is kept for later)");
            }
        }
    }

    public void Dispose() => StopWatching();

    private const uint REG_NOTIFY_CHANGE_NAME = 0x1, REG_NOTIFY_CHANGE_LAST_SET = 0x4;

    [LibraryImport("advapi32.dll")]
    private static partial int RegNotifyChangeKeyValue(nint key, [MarshalAs(UnmanagedType.Bool)] bool watchSubtree, uint filter,
                                                       nint eventHandle, [MarshalAs(UnmanagedType.Bool)] bool asynchronous);
}
