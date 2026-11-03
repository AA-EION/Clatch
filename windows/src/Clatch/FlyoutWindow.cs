// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using Clatch.Core;
using Clatch.Interop;
using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.System;
using Windows.UI;
using Windows.UI.Core;

namespace Clatch;

/// <summary>
/// The panel that opens from the notification area icon.
/// </summary>
/// <remarks>
/// Created when the icon is clicked and closed (released) as soon as it loses
/// focus, so nothing is rendered while it is not open. Uses Acrylic, the
/// Windows material for transient surfaces (Windows' counterpart of macOS
/// Liquid Glass), with card surfaces on top; falls back to a solid background
/// when the system has transparency effects off or does not support Acrylic.
/// </remarks>
internal sealed class FlyoutWindow : Window
{
    private const double PanelWidth = 340;
    private readonly AppModel model;
    private readonly Native.POINT? anchor;
    private readonly StackPanel root = new() { Spacing = 10, Padding = new Thickness(14) };
    private bool recording;
    private string? recorderMessage;
    private bool closed;
    private bool hasBeenActive;

    public FlyoutWindow(AppModel model, Native.POINT? anchor)
    {
        this.model = model;
        this.anchor = anchor;
        Title = "Clatch";

        if (DesktopAcrylicController.IsSupported())
            SystemBackdrop = new DesktopAcrylicBackdrop();

        var presenter = OverlappedPresenter.Create();
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.IsAlwaysOnTop = true;
        presenter.SetBorderAndTitleBar(true, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false; // no taskbar button, not in Alt+Tab

        var scroller = new ScrollViewer { Content = root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var host = new Grid { Children = { scroller } };
        if (!DesktopAcrylicController.IsSupported())
            host.Background = ThemeBrush("SolidBackgroundFillColorBaseBrush");
        host.PreviewKeyDown += OnKeyDown; // tunnelling: seen before any button reacts
        Content = host;
        root.SizeChanged += (_, e) => FitToContent(e.NewSize.Height);

        model.Changed += Render;
        Activated += (_, e) =>
        {
            if (e.WindowActivationState != WindowActivationState.Deactivated)
            {
                hasBeenActive = true;
                return;
            }
            // Close when the user clicks elsewhere, but only once the panel has
            // really had focus: if Windows did not give it the foreground when
            // it opened, it stays visible (topmost) until the user clicks it.
            if (hasBeenActive && !recording) Close();
        };
        Closed += (_, _) =>
        {
            closed = true;
            model.Changed -= Render;
            if (recording) { recording = false; model.ResumeHotKey(); }
            model.PanelDidClose();
        };
        Render();
    }

    public bool IsClosed => closed;

    public void ShowNearAnchor()
    {
        PlaceWindow();
        AppWindow.Show(true);
        Activate();
        Native.SetForegroundWindow(WinRT.Interop.WindowNative.GetWindowHandle(this));
    }

    // ---- Layout -----------------------------------------------------------------

    private double Scale => Native.GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;

    private void PlaceWindow()
    {
        root.Measure(new Windows.Foundation.Size(PanelWidth, double.PositiveInfinity));
        var scale = Scale;
        Native.GetCursorPos(out var cursor);
        var point = anchor ?? cursor;
        var area = DisplayArea.GetFromPoint(new PointInt32(point.X, point.Y), DisplayAreaFallback.Nearest).WorkArea;
        var width = (int)Math.Ceiling(PanelWidth * scale);
        var height = (int)Math.Min(Math.Ceiling((root.DesiredSize.Height + 4) * scale), area.Height - 24);
        const int margin = 12;
        var x = Math.Clamp(point.X - width / 2, area.X + margin, area.X + area.Width - width - margin);
        // Above the anchor when the taskbar is at the bottom, below it otherwise.
        var y = point.Y > area.Y + area.Height / 2 ? point.Y - height - margin : point.Y + margin;
        y = Math.Clamp(y, area.Y + margin, area.Y + area.Height - height - margin);
        AppWindow.MoveAndResize(new RectInt32(x, y, width, height));
    }

    /// <summary>
    /// Fits the window to the content's real laid-out height. Called whenever
    /// the content's size changes: the measurement taken before the window is
    /// shown is only an estimate (fonts and theme resources are not applied
    /// yet), so relying on it alone cut the bottom of the panel off.
    /// </summary>
    private void FitToContent(double contentHeight)
    {
        if (closed || contentHeight <= 0) return;
        var scale = Scale;
        var position = AppWindow.Position;
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
        // + a few pixels for the window border.
        var height = (int)Math.Min(Math.Ceiling((contentHeight + 6) * scale), area.Height - 24);
        if (Math.Abs(height - AppWindow.Size.Height) <= 1) return;
        var bottom = position.Y + AppWindow.Size.Height;
        // Keep the edge nearest the taskbar in place.
        var anchoredToBottom = bottom > area.Y + area.Height / 2;
        var y = anchoredToBottom ? bottom - height : position.Y;
        y = Math.Clamp(y, area.Y + 12, Math.Max(area.Y + 12, area.Y + area.Height - height - 12));
        AppWindow.MoveAndResize(new RectInt32(position.X, y, AppWindow.Size.Width, height));
    }

    // ---- Rendering --------------------------------------------------------------

    private void Render()
    {
        if (closed) return;
        root.Children.Clear();
        switch (model.Page)
        {
            case Page.AddAccount: RenderAddAccount(); break;
            case Page.Rename: RenderRename(); break;
            case Page.ConfirmRemove: RenderRemove(); break;
            case Page.Settings: RenderSettings(); break;
            default: RenderAccounts(); break;
        }
    }

    private void RenderAccounts()
    {
        // Header
        var header = new Grid { ColumnSpacing = 10 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var logo = new Image
        {
            Width = 28, Height = 28,
            Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "Clatch.png"))),
        };
        header.Children.Add(logo);
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        titles.Children.Add(new TextBlock { Text = "Clatch", FontWeight = FontWeights.SemiBold, FontSize = 15 });
        titles.Children.Add(Caption("Claude accounts"));
        Grid.SetColumn(titles, 1);
        header.Children.Add(titles);
        if (model.Settings.EffectiveHotKey is { } hotKey && model.State.Accounts.Count > 1)
        {
            var chip = Card(new TextBlock { Text = hotKey.DisplayString, FontSize = 11 }, new Thickness(8, 3, 8, 3), 10);
            chip.VerticalAlignment = VerticalAlignment.Center;
            ToolTipService.SetToolTip(chip, $"Press {hotKey.DisplayString} anywhere to switch to the next account");
            Grid.SetColumn(chip, 2);
            header.Children.Add(chip);
        }
        root.Children.Add(header);

        if (model.Phase == Phase.ConfirmLayout) root.Children.Add(LayoutWarning());
        else if (model.IsBusy) root.Children.Add(Progress());

        if (model.ErrorMessage is { } error)
        {
            var bar = new InfoBar { Severity = InfoBarSeverity.Error, IsOpen = true, Message = error, IsClosable = true };
            bar.CloseButtonClick += (_, _) => { model.ErrorMessage = null; Render(); };
            root.Children.Add(bar);
        }
        if (!model.Claude.IsInstalled)
        {
            root.Children.Add(new InfoBar
            {
                Severity = InfoBarSeverity.Informational, IsOpen = true, IsClosable = false,
                Message = "Claude Desktop was not found. Clatch switches the accounts of the Claude Desktop app.",
            });
        }

        var list = new StackPanel { Spacing = 6 };
        foreach (var account in model.State.Accounts) list.Children.Add(AccountRow(account));
        root.Children.Add(list);

        if (model.State.Accounts.Count == 1) root.Children.Add(SingleAccountCallout());

        var actions = new StackPanel();
        actions.Children.Add(ActionRow("Add Account…", "", () => model.ShowPage(Page.AddAccount), !model.IsBusy));
        actions.Children.Add(ActionRow("Settings…", "", () => model.ShowPage(Page.Settings)));
        actions.Children.Add(ActionRow("Quit Clatch", "", App.Quit));
        actions.Children.Add(ActionRow("Donate", "", () => AppModel.OpenUri(AppModel.DonateUri), tint: Color.FromArgb(255, 232, 72, 125)));
        root.Children.Add(actions);
    }

    private UIElement AccountRow(Account account)
    {
        var isActive = account.Id == model.State.ActiveId;
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(Avatar(account));
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock
        {
            Text = account.Name, TextTrimming = TextTrimming.CharacterEllipsis,
            FontWeight = isActive ? FontWeights.SemiBold : FontWeights.Normal,
        });
        text.Children.Add(Caption(Subtitle(account, isActive)));
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        if (isActive)
        {
            var check = new FontIcon { Glyph = "", FontSize = 14, Foreground = ThemeBrush("AccentTextFillColorPrimaryBrush"), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(check, 2);
            grid.Children.Add(check);
        }

        var select = new Button
        {
            Content = grid, HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0),
            Padding = new Thickness(10, 8, 6, 8), IsEnabled = !model.IsBusy, // the active row stays readable; clicking it does nothing
        };
        ToolTipService.SetToolTip(select, isActive ? "Signed in to Claude now" : $"Switch Claude to {account.Name}");
        select.Click += (_, _) => model.SwitchTo(account.Id);

        var menu = new MenuFlyout();
        menu.Items.Add(MenuItem("Rename…", () => model.ShowPage(Page.Rename, account.Id)));
        menu.Items.Add(MenuItem("Move Up", () => model.Move(account.Id, -1), account.Id != model.State.Accounts[0].Id));
        menu.Items.Add(MenuItem("Move Down", () => model.Move(account.Id, 1), account.Id != model.State.Accounts[^1].Id));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(MenuItem("Remove…", () => model.ShowPage(Page.ConfirmRemove, account.Id), !isActive && !model.IsBusy));
        var more = new Button
        {
            Content = new FontIcon { Glyph = "", FontSize = 14 }, Flyout = menu,
            Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 4, 0),
        };
        ToolTipService.SetToolTip(more, "More");

        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(select);
        Grid.SetColumn(more, 1);
        row.Children.Add(more);
        return Card(row, new Thickness(0), 8, isActive ? AccountColor(account.Id) : null);
    }

    private string Subtitle(Account account, bool isActive)
    {
        if (isActive) return "Active";
        if (!model.HasStoredData(account.Id)) return "Not signed in yet";
        if (account.LastUsedAt is not { } used) return "Click to switch";
        var ago = DateTimeOffset.Now - used;
        return "Used " + (ago.TotalMinutes < 1 ? "just now"
            : ago.TotalHours < 1 ? $"{(int)ago.TotalMinutes} min ago"
            : ago.TotalDays < 1 ? $"{(int)ago.TotalHours} h ago"
            : $"{(int)ago.TotalDays} days ago");
    }

    private UIElement SingleAccountCallout()
    {
        var panel = new StackPanel { Spacing = 8 };
        var hotKey = model.Settings.EffectiveHotKey?.DisplayString ?? "a shortcut";
        panel.Children.Add(new TextBlock
        {
            Text = $"Use more than one Claude account? Add another and switch between them with one click or {hotKey}.",
            TextWrapping = TextWrapping.Wrap,
        });
        var add = new Button
        {
            Content = "Add Another Account…", HorizontalAlignment = HorizontalAlignment.Stretch,
            IsEnabled = !model.IsBusy,
        };
        MakeAccent(add);
        add.Click += (_, _) => model.ShowPage(Page.AddAccount);
        panel.Children.Add(add);
        return Card(panel, new Thickness(12), 8, AccentColor());
    }

    private UIElement Progress()
    {
        var panel = new StackPanel { Spacing = 8 };
        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        title.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        title.Children.Add(new TextBlock
        {
            FontWeight = FontWeights.SemiBold,
            Text = model.Phase switch
            {
                Phase.WaitingForClaude => "Waiting for Claude to close…",
                Phase.WaitingForHelpers => "Waiting for Claude to finish…",
                _ => "Switching…",
            },
        });
        panel.Children.Add(title);
        panel.Children.Add(Caption(model.Phase switch
        {
            Phase.WaitingForClaude when model.QuitDeclined =>
                "Claude didn't close. If it asked you to confirm, choose to quit there, or quit Claude from its icon in the notification area (right-click › Quit). Clatch continues by itself.",
            Phase.WaitingForClaude =>
                "If Claude asks whether to close (for example while a session is running), confirm there. If you say no, nothing changes.",
            Phase.WaitingForHelpers =>
                "Claude is closed; its background processes are still exiting. Windows can only switch once they are done.",
            _ => "Claude will reopen with the other account.",
        }));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        if (model.Phase == Phase.WaitingForClaude && model.QuitDeclined)
            buttons.Children.Add(SmallButton("Ask Claude Again", model.AskClaudeToQuit));
        if (model.Phase != Phase.Switching)
            buttons.Children.Add(SmallButton("Cancel", model.CancelSwitch));
        panel.Children.Add(buttons);
        return Card(panel, new Thickness(12), 8, Color.FromArgb(255, 247, 150, 70));
    }

    /// <summary>The fail-safe: Claude's data folder is not what Clatch expects.</summary>
    private UIElement LayoutWarning()
    {
        var panel = new StackPanel { Spacing = 6 };
        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        title.Children.Add(new FontIcon { Glyph = "", FontSize = 16, Foreground = new SolidColorBrush(Color.FromArgb(255, 247, 150, 70)) });
        title.Children.Add(new TextBlock { Text = "Claude's data looks different", FontWeight = FontWeights.SemiBold });
        panel.Children.Add(title);
        panel.Children.Add(Caption("Claude Desktop may have changed how it stores its data. Nothing has been moved yet."));
        foreach (var problem in model.LayoutProblems) panel.Children.Add(Caption("• " + problem));
        panel.Children.Add(Caption("Continuing may not switch the account, or may start Claude signed out. Your data stays in place either way."));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(SmallButton("Cancel", model.CancelSwitch));
        buttons.Children.Add(SmallButton("Continue Anyway", model.ContinueDespiteLayout));
        panel.Children.Add(buttons);
        return Card(panel, new Thickness(12), 8, Color.FromArgb(255, 247, 150, 70));
    }

    private void RenderAddAccount()
    {
        root.Children.Add(PageHeader("Add Account"));
        var steps = new StackPanel { Spacing = 6 };
        steps.Children.Add(Step(1, "Clatch asks Claude to close. If a session is running, Claude asks you first."));
        steps.Children.Add(Step(2, "Your current account is set aside in Clatch's accounts folder. Nothing is deleted."));
        steps.Children.Add(Step(3, "Claude opens fresh. Sign in with the other account."));
        root.Children.Add(Card(steps, new Thickness(12), 8));

        var current = new TextBox { Header = "Name for the account signed in now", Text = model.State.Active?.Name ?? "" };
        var added = new TextBox { Header = "Name for the new account", PlaceholderText = model.SuggestedNewName() };
        root.Children.Add(current);
        root.Children.Add(added);
        void Submit()
        {
            var name = current.Text.Trim();
            model.AddAccount(added.Text, name.Length == 0 || name == model.State.Active?.Name ? null : name);
        }
        added.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) Submit(); };
        root.Children.Add(Buttons(("Cancel", () => model.ShowPage(Page.Accounts), false),
                                  (model.Claude.IsRunning ? "Close Claude & Add" : "Add & Open Claude", Submit, true)));
    }

    private void RenderRename()
    {
        var id = model.PageAccount ?? Guid.Empty;
        root.Children.Add(PageHeader("Rename Account"));
        var box = new TextBox { Text = model.State.Accounts.FirstOrDefault(a => a.Id == id)?.Name ?? "" };
        box.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) model.Rename(id, box.Text); };
        root.Children.Add(box);
        root.Children.Add(Caption("Tip: use the email address you sign in with, so you can tell accounts apart."));
        root.Children.Add(Buttons(("Cancel", () => model.ShowPage(Page.Accounts), false), ("Save", () => model.Rename(id, box.Text), true)));
    }

    private void RenderRemove()
    {
        var id = model.PageAccount ?? Guid.Empty;
        var name = model.State.Accounts.FirstOrDefault(a => a.Id == id)?.Name ?? "this account";
        root.Children.Add(PageHeader("Remove Account"));
        root.Children.Add(new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Text = $"Remove “{name}” from Clatch? Its saved Claude sign-in and local data go to the Recycle Bin, so you can still restore them from there.",
        });
        root.Children.Add(Buttons(("Cancel", () => model.ShowPage(Page.Accounts), false), ("Move to Recycle Bin", () => model.Remove(id), true)));
    }

    private void RenderSettings()
    {
        root.Children.Add(PageHeader("Settings"));

        var shortcut = new StackPanel { Spacing = 8 };
        shortcut.Children.Add(new TextBlock { Text = "Switch to next account", FontWeight = FontWeights.SemiBold });
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(Card(new TextBlock
        {
            Text = recording ? "Type a shortcut…" : model.Settings.EffectiveHotKey?.DisplayString ?? "Off",
            MinWidth = 110,
        }, new Thickness(10, 5, 10, 5), 6, recording ? AccentColor() : null));
        if (recording)
        {
            var cancel = SmallButton("Cancel", StopRecording);
            row.Children.Add(cancel);
            // Keep keyboard focus inside the panel so the keys reach the recorder.
            cancel.Loaded += (_, _) => cancel.Focus(FocusState.Programmatic);
        }
        else
        {
            row.Children.Add(SmallButton("Change", StartRecording));
            var reset = SmallButton("Default", () => model.SetHotKey(KeyCombo.Default));
            reset.IsEnabled = model.Settings.EffectiveHotKey != KeyCombo.Default;
            row.Children.Add(reset);
            var off = SmallButton("Off", () => model.SetHotKey(null));
            off.IsEnabled = model.Settings.EffectiveHotKey is not null;
            row.Children.Add(off);
        }
        shortcut.Children.Add(row);
        var message = recorderMessage
            ?? (!model.HotKeyRegistered && model.Settings.EffectiveHotKey is not null
                ? "Another app already uses this shortcut. Choose a different one." : null);
        if (message is not null)
            shortcut.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, FontSize = 12, Foreground = new SolidColorBrush(Color.FromArgb(255, 220, 120, 30)) });
        root.Children.Add(Card(shortcut, new Thickness(12), 8));

        var toggles = new StackPanel { Spacing = 2 };
        toggles.Children.Add(Toggle("Reopen Claude after switching", model.Settings.ReopenClaude, model.SetReopenClaude));
        toggles.Children.Add(Toggle("Same MCP & tool settings for every account", model.Settings.ShareToolSettings, model.SetShareToolSettings));
        toggles.Children.Add(Toggle("Open Clatch when I sign in to Windows", StartAtLogin.IsEnabled, model.SetStartAtLogin));
        root.Children.Add(Card(toggles, new Thickness(12, 4, 12, 4), 8));

        var actions = new StackPanel();
        actions.Children.Add(ActionRow("Show Accounts Folder", "", model.RevealAccountsFolder));
        actions.Children.Add(ActionRow("Open Claude", "", () => _ = model.Claude.OpenAsync(), model.Claude.IsInstalled));
        actions.Children.Add(ActionRow("Clatch on GitHub", "", () => AppModel.OpenUri(AppModel.ProjectUri)));
        root.Children.Add(actions);

        root.Children.Add(new TextBlock
        {
            Text = $"Clatch {AppModel.Version} · GPL-3.0-or-later · Issen Software Group",
            FontSize = 11, HorizontalAlignment = HorizontalAlignment.Center,
            Foreground = ThemeBrush("TextFillColorTertiaryBrush"),
        });
    }

    // ---- Shortcut recorder ------------------------------------------------------

    private void StartRecording()
    {
        recording = true;
        recorderMessage = null;
        model.SuspendHotKey();
        Render();
    }

    private void StopRecording()
    {
        recording = false;
        model.ResumeHotKey();
        Render();
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (!recording) return;
        e.Handled = true;
        var key = e.Key;
        if (key is VirtualKey.Control or VirtualKey.Shift or VirtualKey.Menu or VirtualKey.LeftWindows or VirtualKey.RightWindows
            or VirtualKey.LeftControl or VirtualKey.RightControl or VirtualKey.LeftShift or VirtualKey.RightShift
            or VirtualKey.LeftMenu or VirtualKey.RightMenu) return;
        static bool Down(VirtualKey k) =>
            InputKeyboardSource.GetKeyStateForCurrentThread(k).HasFlag(CoreVirtualKeyStates.Down);
        uint modifiers = 0;
        if (Down(VirtualKey.Control)) modifiers |= KeyCombo.Control;
        if (Down(VirtualKey.Menu)) modifiers |= KeyCombo.Alt;
        if (Down(VirtualKey.Shift)) modifiers |= KeyCombo.Shift;
        if (Down(VirtualKey.LeftWindows) || Down(VirtualKey.RightWindows)) modifiers |= KeyCombo.Win;
        if (key == VirtualKey.Escape && modifiers == 0) { StopRecording(); return; }

        var vk = (uint)key;
        var label = vk is >= 0x41 and <= 0x5A or >= 0x30 and <= 0x39 ? ((char)vk).ToString()
                  : vk is >= 0x70 and <= 0x87 ? $"F{vk - 0x6F}"
                  : key.ToString();
        var combo = new KeyCombo(modifiers, vk, label);
        if (!combo.IsAcceptable)
        {
            recorderMessage = "Include Ctrl, Alt or Win (function keys work alone).";
            Render();
            return;
        }
        recording = false;
        recorderMessage = null;
        model.SetHotKey(combo);
    }

    // ---- Building blocks ----------------------------------------------------------

    /// <summary>A theme brush; never throws (falls back to a neutral translucent brush).</summary>
    private static Brush ThemeBrush(string key) =>
        Application.Current.Resources.TryGetValue(key, out var value) && value is Brush brush
            ? brush
            : new SolidColorBrush(Color.FromArgb(24, 128, 128, 128));

    /// <summary>Gives a button the accent look, with or without the theme style.</summary>
    private static void MakeAccent(Button button)
    {
        if (ThemeStyle("AccentButtonStyle") is { } style)
        {
            button.Style = style;
            return;
        }
        button.Background = new SolidColorBrush(AccentColor());
        button.Foreground = new SolidColorBrush(Colors.White);
    }

    /// <summary>A theme style, or null to keep the control's default look.</summary>
    private static Style? ThemeStyle(string key) =>
        Application.Current.Resources.TryGetValue(key, out var value) ? value as Style : null;

    /// <summary>The user's Windows accent colour, straight from the system settings
    /// (unboxing the theme resource fails in the NativeAOT build).</summary>
    private static Color AccentColor()
    {
        try { return new Windows.UI.ViewManagement.UISettings().GetColorValue(Windows.UI.ViewManagement.UIColorType.Accent); }
        catch (Exception) { return Color.FromArgb(255, 0, 120, 212); }
    }

    private static Color AccountColor(Guid id)
    {
        Color[] palette =
        [
            Color.FromArgb(255, 217, 119, 87), Color.FromArgb(255, 0, 120, 212), Color.FromArgb(255, 136, 23, 152),
            Color.FromArgb(255, 16, 124, 16), Color.FromArgb(255, 227, 0, 140), Color.FromArgb(255, 0, 153, 188),
            Color.FromArgb(255, 92, 45, 145), Color.FromArgb(255, 142, 86, 46),
        ];
        var hash = id.ToString("N").Aggregate(0, (h, c) => (h * 31 + c) & 0xFFFF);
        return palette[hash % palette.Length];
    }

    /// <summary>A card surface: translucent fill over the Acrylic, optionally tinted.</summary>
    private static Border Card(UIElement child, Thickness padding, double radius, Color? tint = null)
    {
        var border = new Border
        {
            Child = child, Padding = padding, CornerRadius = new CornerRadius(radius),
            BorderThickness = new Thickness(1), BorderBrush = ThemeBrush("CardStrokeColorDefaultBrush"),
        };
        border.Background = tint is { } color
            ? new SolidColorBrush(Color.FromArgb(46, color.R, color.G, color.B))
            : ThemeBrush("CardBackgroundFillColorDefaultBrush");
        return border;
    }

    private static UIElement Avatar(Account account) => new Border
    {
        Width = 32, Height = 32, CornerRadius = new CornerRadius(16),
        Background = new SolidColorBrush(AccountColor(account.Id)),
        Child = new TextBlock
        {
            Text = account.Initials, Foreground = new SolidColorBrush(Colors.White), FontSize = 12,
            FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        },
    };

    private static TextBlock Caption(string text) => new()
    {
        Text = text, FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = ThemeBrush("TextFillColorSecondaryBrush"),
    };

    private static Button ActionRow(string title, string glyph, Action action, bool enabled = true, Color? tint = null)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        var icon = new FontIcon { Glyph = glyph, FontSize = 14 };
        if (tint is { } color) icon.Foreground = new SolidColorBrush(color);
        content.Children.Add(icon);
        content.Children.Add(new TextBlock { Text = title });
        var button = new Button
        {
            Content = content, HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left,
            Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0),
            Padding = new Thickness(10, 7, 10, 7), IsEnabled = enabled,
        };
        button.Click += (_, _) => action();
        return button;
    }

    private static Button SmallButton(string title, Action action)
    {
        var button = new Button { Content = title, Padding = new Thickness(10, 4, 10, 5) };
        button.Click += (_, _) => action();
        return button;
    }

    private static MenuFlyoutItem MenuItem(string text, Action action, bool enabled = true)
    {
        var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
        item.Click += (_, _) => action();
        return item;
    }

    private static UIElement Toggle(string title, bool value, Action<bool> set)
    {
        var toggle = new ToggleSwitch { Header = null, OnContent = title, OffContent = title, IsOn = value };
        toggle.Toggled += (_, _) => set(toggle.IsOn);
        return toggle;
    }

    private UIElement PageHeader(string title)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        var back = new Button
        {
            Content = new FontIcon { Glyph = "", FontSize = 12 },
            Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0),
        };
        ToolTipService.SetToolTip(back, "Back");
        back.Click += (_, _) => model.ShowPage(Page.Accounts);
        panel.Children.Add(back);
        panel.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, FontSize = 15, VerticalAlignment = VerticalAlignment.Center });
        return panel;
    }

    private static UIElement Step(int number, string text)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new Border
        {
            Width = 20, Height = 20, CornerRadius = new CornerRadius(10), VerticalAlignment = VerticalAlignment.Top,
            Background = new SolidColorBrush(AccentColor()),
            Child = new TextBlock
            {
                Text = number.ToString(), FontSize = 11, FontWeight = FontWeights.Bold, Foreground = new SolidColorBrush(Colors.White),
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            },
        });
        var label = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap };
        Grid.SetColumn(label, 1);
        grid.Children.Add(label);
        return grid;
    }

    private static UIElement Buttons((string Title, Action Action, bool Primary) secondary, (string Title, Action Action, bool Primary) primary)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var left = new Button { Content = secondary.Title, HorizontalAlignment = HorizontalAlignment.Stretch };
        left.Click += (_, _) => secondary.Action();
        var right = new Button
        {
            Content = primary.Title, HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        MakeAccent(right);
        right.Click += (_, _) => primary.Action();
        Grid.SetColumn(right, 1);
        grid.Children.Add(left);
        grid.Children.Add(right);
        return grid;
    }
}
