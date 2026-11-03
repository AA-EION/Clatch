// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using Clatch.Interop;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Clatch;

/// <summary>
/// Notification-area-only app: no main window, no taskbar button. The panel
/// window exists only while it is open.
/// </summary>
public partial class App : Application
{
    private static App? instance;
    private AppModel? model;
    private TrayIcon? tray;
    private FlyoutWindow? flyout;

    public App()
    {
        instance = this;
        InitializeComponent();
        // Keep running with no window open (WinUI would exit when the last window closes).
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var dispatcher = DispatcherQueue.GetForCurrentThread();
        model = new AppModel(dispatcher);
        tray = new TrayIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Clatch.ico"), "Clatch: switch Claude accounts");
        tray.Activated += point => TogglePanel(point);
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
            // A click on the icon while the panel is open closes it (the click
            // itself already deactivated and closed it in most cases).
            flyout.Close();
            flyout = null;
            return;
        }
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
        model.PanelWillOpen();
        flyout = new FlyoutWindow(model, anchor);
        flyout.Closed += (_, _) => flyout = null;
        flyout.ShowNearAnchor();
    }

    /// <summary>Removes the notification area icon, then exits.</summary>
    public static void Quit()
    {
        instance?.flyout?.Close();
        instance?.tray?.Dispose();
        Current.Exit();
    }
}
