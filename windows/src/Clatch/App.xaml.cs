// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using Clatch.Interop;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Clatch;

/// <summary>
/// Notification-area-only app: no main window, no taskbar button.
/// Left click opens the panel (which exists only while open); right click
/// opens the classic Windows context menu, which is also the fallback if the
/// panel cannot be shown for any reason.
/// </summary>
public partial class App : Application
{
    private static App? instance;
    private AppModel? model;
    private TrayIcon? tray;
    private FlyoutWindow? flyout;
    private DateTimeOffset flyoutClosedAt = DateTimeOffset.MinValue;

    public App()
    {
        instance = this;
        InitializeComponent();
        // Keep running with no window open (WinUI would exit when the last window closes).
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        UnhandledException += (_, e) =>
        {
            Log.Error("unhandled", e.Exception);
            e.Handled = true; // a broken panel must not take the icon and shortcut down with it
        };
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            if (e.ExceptionObject is Exception ex) Log.Error("unhandled (domain)", ex);
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Log.Write($"Clatch {AppModel.Version} starting ({System.Runtime.InteropServices.RuntimeInformation.OSDescription}, " +
                  $"{System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture})");
        var dispatcher = DispatcherQueue.GetForCurrentThread();
        model = new AppModel(dispatcher);
        Log.Write($"Claude installed={model.Claude.IsInstalled} packaged={model.Claude.IsPackaged} data={model.Claude.DataFolder}");
        tray = new TrayIcon(dispatcher, Path.Combine(AppContext.BaseDirectory, "Assets", "Clatch.ico"), "Clatch: switch Claude accounts");
        tray.LeftClicked += TogglePanel;
        tray.RightClicked += ShowMenu;
        tray.HotKeyPressed += () => model.HotKeyPressed();
        model.RegisterHotKey = combo => tray.RegisterHotKey(combo);
        model.PanelRequested += () => ShowPanel(null);
        model.Changed += UpdateTooltip;
        model.Start();
    }

    private void UpdateTooltip()
    {
        if (tray is null || model is null) return;
        var text = model.IsBusy ? "Clatch: switching accounts…"
                 : model.State.Active is { } active ? $"Clatch: {active.Name}" : "Clatch";
        if (text != tray.Tooltip) tray.SetTooltip(text);
    }

    private void TogglePanel(Native.POINT? anchor)
    {
        if (flyout is { IsClosed: false })
        {
            flyout.Close();
            return;
        }
        // Clicking the icon while the panel is open first closes the panel (it
        // loses focus to the taskbar); that click must not open it again.
        if (anchor is not null && DateTimeOffset.Now - flyoutClosedAt < TimeSpan.FromMilliseconds(400)) return;
        ShowPanel(anchor);
    }

    private void ShowPanel(Native.POINT? anchor)
    {
        if (model is null) return;
        if (flyout is { IsClosed: false })
        {
            flyout.Activate();
            return;
        }
        try
        {
            model.PanelWillOpen();
            var window = new FlyoutWindow(model, anchor);
            window.Closed += (_, _) =>
            {
                flyoutClosedAt = DateTimeOffset.Now;
                if (ReferenceEquals(flyout, window)) flyout = null;
            };
            flyout = window;
            window.ShowNearAnchor();
            Log.Write("Panel shown");
        }
        catch (Exception e)
        {
            Log.Error("opening the panel", e);
            flyout = null;
            // Never leave the user without a menu.
            Native.GetCursorPos(out var cursor);
            ShowMenu(anchor ?? cursor);
        }
    }

    /// <summary>The classic right-click menu: accounts, then actions, Donate last.</summary>
    private void ShowMenu(Native.POINT point)
    {
        if (model is null || tray is null) return;
        model.PanelWillOpen();
        var items = new List<TrayMenuItem>();
        foreach (var account in model.State.Accounts)
        {
            var isActive = account.Id == model.State.ActiveId;
            var id = account.Id;
            items.Add(new TrayMenuItem(account.Name, () => model.SwitchTo(id), Checked: isActive, Enabled: !isActive && !model.IsBusy));
        }
        if (model.IsBusy)
        {
            items.Add(TrayMenuItem.Separator);
            items.Add(new TrayMenuItem(model.Phase == Phase.ConfirmLayout ? "Claude's data looks different… (open panel)" : "Switching… (open panel)",
                                       () => ShowPanel(point)));
            items.Add(new TrayMenuItem("Cancel Switch", model.CancelSwitch));
        }
        items.Add(TrayMenuItem.Separator);
        items.Add(new TrayMenuItem("Open Clatch", () => ShowPanel(point), IsDefault: true));
        items.Add(new TrayMenuItem("Add Account…", () => { model.Page = Page.AddAccount; ShowPanel(point); }, Enabled: !model.IsBusy));
        items.Add(new TrayMenuItem("Settings…", () => { model.Page = Page.Settings; ShowPanel(point); }));
        items.Add(TrayMenuItem.Separator);
        items.Add(new TrayMenuItem("Quit Clatch", Quit));
        items.Add(new TrayMenuItem("Donate ♥", () => AppModel.OpenUri(AppModel.DonateUri)));
        tray.ShowMenu(point, items);
    }

    /// <summary>Removes the notification area icon, then exits.</summary>
    public static void Quit()
    {
        Log.Write("Quit");
        instance?.flyout?.Close();
        instance?.tray?.Dispose();
        Current.Exit();
    }
}
