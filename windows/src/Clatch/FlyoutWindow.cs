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
using Microsoft.UI.Xaml.Media.Imaging;
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

    // Controls whose text the user is editing survive re-renders (the model
    // changes whenever a profile's Claude starts or stops).
    private readonly Dictionary<string, Control> drafts = [];
    private (Page, Guid?) draftsFor;
    private string? draftColor;
    private string? pageMessage;
    private Guid? chatsFrom, chatsTo;

    private T Draft<T>(string key, Func<T> make) where T : Control
    {
        if (drafts.TryGetValue(key, out var existing) && existing is T control) return control;
        var created = make();
        drafts[key] = created;
        return created;
    }

    private void Render()
    {
        if (closed) return;
        if (draftsFor != (model.Page, model.PageAccount))
        {
            drafts.Clear();
            draftColor = null;
            pageMessage = null;
            draftsFor = (model.Page, model.PageAccount);
        }
        // Keep the caret where it was when a re-render rebuilds the page around a kept text box.
        var focused = Content?.XamlRoot is { } xamlRoot ? FocusManager.GetFocusedElement(xamlRoot) as Control : null;
        root.Children.Clear();
        switch (model.Page)
        {
            case Page.AddAccount: RenderAddAccount(); break;
            case Page.EditProfile: RenderEditProfile(); break;
            case Page.ConfirmRemove: RenderRemove(); break;
            case Page.Settings: RenderSettings(); break;
            case Page.ConfirmSideBySide: RenderConfirmSideBySide(); break;
            case Page.MoveChats: RenderMoveChats(); break;
            case Page.RestoreBackups: RenderRestoreBackups(); break;
            default: RenderAccounts(); break;
        }
        if (focused is not null && drafts.ContainsValue(focused))
            focused.Loaded += RefocusOnce;
    }

    private void RefocusOnce(object sender, RoutedEventArgs e)
    {
        if (sender is Control control)
        {
            control.Loaded -= RefocusOnce;
            control.Focus(FocusState.Programmatic);
        }
    }

    private void AddMessages()
    {
        if (model.ErrorMessage is { } error)
        {
            var bar = new InfoBar { Severity = InfoBarSeverity.Error, IsOpen = true, Message = error, IsClosable = true };
            bar.CloseButtonClick += (_, _) => { model.ErrorMessage = null; Render(); };
            root.Children.Add(bar);
        }
        if (model.Notice is { } notice)
        {
            var bar = new InfoBar { Severity = InfoBarSeverity.Success, IsOpen = true, Message = notice, IsClosable = true };
            bar.CloseButtonClick += (_, _) => { model.Notice = null; Render(); };
            root.Children.Add(bar);
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
            Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "Clatch.png"))),
        };
        header.Children.Add(logo);
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        titles.Children.Add(new TextBlock { Text = "Clatch", FontWeight = FontWeights.SemiBold, FontSize = 15 });
        titles.Children.Add(Caption(model.SideBySide ? "Claude profiles · side by side" : "Claude profiles · one at a time"));
        Grid.SetColumn(titles, 1);
        header.Children.Add(titles);
        if (model.Settings.EffectiveHotKey is { } hotKey && model.State.Accounts.Count > 1)
        {
            var chip = Card(new TextBlock { Text = hotKey.DisplayString, FontSize = 11 }, new Thickness(8, 3, 8, 3), 10);
            chip.VerticalAlignment = VerticalAlignment.Center;
            ToolTipService.SetToolTip(chip, $"Hold {hotKey.DisplayString} to pick a profile; let go to open it");
            Grid.SetColumn(chip, 2);
            header.Children.Add(chip);
        }
        root.Children.Add(header);

        if (model.Phase == Phase.ConfirmLayout) root.Children.Add(LayoutWarning());
        else if (model.IsBusy) root.Children.Add(Progress());

        if (model.AvailableUpdate is { } update)
        {
            var bar = new InfoBar
            {
                Severity = InfoBarSeverity.Informational, IsOpen = true, IsClosable = false,
                Title = $"Clatch {update.Version} is available", Message = "",
            };
            var get = new Button { Content = "Download" };
            get.Click += (_, _) => AppModel.OpenUri(update.Page);
            bar.ActionButton = get;
            root.Children.Add(bar);
        }
        AddMessages();
        if (!model.Claude.IsInstalled)
        {
            root.Children.Add(new InfoBar
            {
                Severity = InfoBarSeverity.Informational, IsOpen = true, IsClosable = false,
                Message = "Claude Desktop was not found. Clatch switches the accounts of the Claude Desktop app.",
            });
        }

        var list = new StackPanel { Spacing = 6 };
        var index = 0;
        foreach (var account in model.State.Accounts) list.Children.Add(AccountRow(account, index++));
        root.Children.Add(list);

        if (model.State.Accounts.Count == 1) root.Children.Add(SingleAccountCallout());

        var actions = new StackPanel();
        actions.Children.Add(ActionRow("Add Account…", "", () => model.ShowPage(Page.AddAccount), !model.IsBusy));
        if (model.State.Accounts.Count > 1)
            actions.Children.Add(ActionRow("Move Code Chats…", "", () => model.ShowPage(Page.MoveChats), !model.IsBusy));
        actions.Children.Add(ActionRow("Settings…", "", () => model.ShowPage(Page.Settings)));
        actions.Children.Add(ActionRow("Quit Clatch", "", App.Quit));
        actions.Children.Add(ActionRow("Donate", "", () => AppModel.OpenUri(AppModel.DonateUri), tint: Color.FromArgb(255, 232, 72, 125)));
        root.Children.Add(actions);
    }

    /// <summary>Is this the profile the row should mark as current?</summary>
    private bool IsCurrent(Account account) =>
        model.SideBySide ? model.IsRunning(account.Id) : account.Id == model.State.ActiveId;

    private UIElement AccountRow(Account account, int index)
    {
        var id = account.Id;
        var isActive = id == model.State.ActiveId;
        var running = model.IsRunning(id);
        var current = IsCurrent(account);
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(ProfileIcon(account, running));
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock
        {
            Text = account.Name, TextTrimming = TextTrimming.CharacterEllipsis,
            FontWeight = current ? FontWeights.SemiBold : FontWeights.Normal,
        });
        text.Children.Add(Caption(Subtitle(account, isActive, running)));
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        var trailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        if (index < 9)
            trailing.Children.Add(new TextBlock { Text = $"Ctrl+{index + 1}", FontSize = 11, Foreground = ThemeBrush("TextFillColorTertiaryBrush"), VerticalAlignment = VerticalAlignment.Center });
        if (current && !model.SideBySide)
            trailing.Children.Add(new FontIcon { Glyph = "", FontSize = 14, Foreground = ThemeBrush("AccentTextFillColorPrimaryBrush") });
        Grid.SetColumn(trailing, 2);
        grid.Children.Add(trailing);

        var select = new Button
        {
            Content = grid, HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0),
            Padding = new Thickness(10, 8, 6, 8), IsEnabled = !model.IsBusy,
        };
        ToolTipService.SetToolTip(select, model.SideBySide
            ? (running ? $"Bring {account.Name}'s Claude to the front" : $"Open Claude as {account.Name}")
            : (isActive ? (model.Claude.IsRunning ? "Signed in to Claude now" : "Open Claude") : $"Switch Claude to {account.Name}"));
        select.Click += (_, _) => model.Open(id);

        var menu = new MenuFlyout();
        menu.Items.Add(MenuItem(model.SideBySide && running ? "Bring to Front" : model.SideBySide || isActive ? "Open Claude" : "Switch to This Account",
                                () => model.Open(id), !model.IsBusy));
        if (running || (!model.SideBySide && isActive && model.Claude.IsRunning))
        {
            if (model.SideBySide)
            {
                menu.Items.Add(MenuItem("Close Claude", () => model.CloseProfile(id)));
                menu.Items.Add(MenuItem("Restart Claude", () => model.RestartProfile(id)));
            }
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(MenuItem("Edit…", () => model.ShowPage(Page.EditProfile, id)));
        menu.Items.Add(MenuItem("Move Up", () => model.Move(id, -1), id != model.State.Accounts[0].Id));
        menu.Items.Add(MenuItem("Move Down", () => model.Move(id, 1), id != model.State.Accounts[^1].Id));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(MenuItem("Remove…", () => model.ShowPage(Page.ConfirmRemove, id), !isActive && !running && !model.IsBusy));
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
        return Card(row, new Thickness(0), 8, current ? ProfileColor(account) : null);
    }

    private string Subtitle(Account account, bool isActive, bool running)
    {
        if (model.SideBySide)
        {
            if (running) return "Open";
        }
        else if (isActive)
        {
            return model.Claude.IsRunning ? "Active" : "Active · Claude is closed";
        }
        if (!model.HasStoredData(account.Id) && !isActive) return "Not signed in yet";
        if (account.LastUsedAt is not { } used) return model.SideBySide ? "Click to open" : "Click to switch";
        var ago = DateTimeOffset.Now - used;
        return "Used " + (ago.TotalMinutes < 1 ? "just now"
            : ago.TotalHours < 1 ? $"{(int)ago.TotalMinutes} min ago"
            : ago.TotalDays < 1 ? $"{(int)ago.TotalHours} h ago"
            : $"{(int)ago.TotalDays} days ago");
    }

    /// <summary>The profile's badged Claude icon, with a green dot while its Claude runs.</summary>
    private UIElement ProfileIcon(Account account, bool running, double size = 32)
    {
        var host = new Grid { Width = size, Height = size, VerticalAlignment = VerticalAlignment.Center };
        UIElement picture;
        try
        {
            picture = new Image { Width = size, Height = size, Source = new BitmapImage(new Uri(model.IconPath(account))) };
        }
        catch (Exception e)
        {
            Log.Error("drawing a profile icon", e);
            picture = Avatar(account, size);
        }
        host.Children.Add(picture);
        if (running)
        {
            host.Children.Add(new Border
            {
                Width = 10, Height = 10, CornerRadius = new CornerRadius(5),
                HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom,
                Background = new SolidColorBrush(Color.FromArgb(255, 48, 209, 88)),
                BorderBrush = ThemeBrush("SolidBackgroundFillColorBaseBrush"), BorderThickness = new Thickness(1.5),
            });
        }
        return host;
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
                Phase.ClosingProfiles => "Closing the other profiles…",
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
            Phase.ClosingProfiles =>
                "Going back to one at a time: Clatch asks every other profile's Claude to close. If one asks you first, confirm there. Their sign-ins are kept and backed up.",
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
        if (model.SideBySide)
        {
            steps.Children.Add(Step(1, "Clatch makes a new profile with its own Claude data folder."));
            steps.Children.Add(Step(2, "A second Claude window opens for it, next to the ones already open."));
            steps.Children.Add(Step(3, "Sign in there with the other account."));
        }
        else
        {
            steps.Children.Add(Step(1, "Clatch asks Claude to close. If a session is running, Claude asks you first."));
            steps.Children.Add(Step(2, "Your current account is set aside in Clatch's accounts folder. Nothing is deleted."));
            steps.Children.Add(Step(3, "Claude opens fresh. Sign in with the other account."));
        }
        root.Children.Add(Card(steps, new Thickness(12), 8));

        var current = Draft("current", () => new TextBox { Header = "Name for the account signed in now", Text = model.State.Active?.Name ?? "" });
        var added = Draft("added", () => new TextBox { Header = "Name for the new account", PlaceholderText = model.SuggestedNewName() });
        if (model.State.Active is not null) root.Children.Add(current);
        root.Children.Add(added);
        void Submit()
        {
            var name = current.Text.Trim();
            model.AddAccount(added.Text, name.Length == 0 || name == model.State.Active?.Name ? null : name);
        }
        saveAction = Submit;
        added.KeyDown -= SaveOnEnter;
        added.KeyDown += SaveOnEnter;
        var primary = model.SideBySide ? "Add & Open"
                    : model.Claude.IsRunning ? "Close Claude & Add" : "Add & Open Claude";
        root.Children.Add(Buttons(("Cancel", () => model.ShowPage(Page.Accounts), false), (primary, Submit, true)));
        if (model.Settings.ProfileShortcuts)
            root.Children.Add(Caption("A shortcut for the new profile appears on the Desktop and in the Start menu."));
    }

    private void RenderEditProfile()
    {
        if (model.PageAccount is not { } id || model.Account(id) is not { } account)
        {
            model.ShowPage(Page.Accounts);
            return;
        }
        root.Children.Add(PageHeader("Edit Profile"));
        var name = Draft("name", () => new TextBox { Header = "Name", Text = account.Name, PlaceholderText = "you@example.com" });
        var badge = Draft("badge", () => new TextBox
        {
            Header = "Badge (a letter or an emoji)", Text = account.Badge ?? "", MaxLength = 8,
            PlaceholderText = account.BadgeText,
        });
        var environment = Draft("env", () => new TextBox
        {
            Header = "Environment variables (NAME=value, one per line)", AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap,
            Text = LaunchOptions.FormatEnvironment(account.Environment), MinHeight = 64, MaxHeight = 140,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12,
        });
        var flags = Draft("flags", () => new TextBox
        {
            Header = "Extra flags for Claude", Text = LaunchOptions.FormatArguments(account.Arguments),
            PlaceholderText = "--example-flag", FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12,
        });
        draftColor ??= account.ColorHex ?? account.ResolvedColorHex;

        // A live preview of the icon: Claude's icon with the badge.
        var preview = new Grid { ColumnSpacing = 12 };
        preview.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        preview.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        previewIcon = new Grid { VerticalAlignment = VerticalAlignment.Center };
        previewOf = () => account with { Name = name.Text.Trim().Length > 0 ? name.Text.Trim() : account.Name, Badge = badge.Text, ColorHex = draftColor };
        UpdatePreview(null, null!);
        preview.Children.Add(previewIcon);
        var swatches = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        foreach (var hex in Account.Palette)
        {
            var chosen = string.Equals(hex, draftColor, StringComparison.OrdinalIgnoreCase);
            var swatch = new Button
            {
                Width = 24, Height = 24, MinWidth = 0, Padding = new Thickness(0), CornerRadius = new CornerRadius(12),
                Background = new SolidColorBrush(ParseColor(hex)),
                BorderBrush = chosen ? ThemeBrush("TextFillColorPrimaryBrush") : new SolidColorBrush(Colors.Transparent),
                BorderThickness = new Thickness(chosen ? 2 : 0),
            };
            ToolTipService.SetToolTip(swatch, hex);
            swatch.Click += (_, _) => { draftColor = hex; Render(); };
            swatches.Children.Add(swatch);
        }
        Grid.SetColumn(swatches, 1);
        preview.Children.Add(swatches);
        root.Children.Add(Card(preview, new Thickness(12), 8));

        root.Children.Add(name);
        root.Children.Add(badge);
        // The preview follows the badge and the name as they are typed.
        badge.TextChanged -= UpdatePreview;
        badge.TextChanged += UpdatePreview;
        name.TextChanged -= UpdatePreview;
        name.TextChanged += UpdatePreview;
        root.Children.Add(environment);
        root.Children.Add(flags);
        root.Children.Add(Caption("Applied whenever Clatch starts this profile's Claude. --user-data-dir is set by Clatch."));
        if (pageMessage is { } message)
            root.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, FontSize = 12, Foreground = new SolidColorBrush(Color.FromArgb(255, 220, 120, 30)) });

        void Save()
        {
            var (values, problems) = LaunchOptions.ParseEnvironment(environment.Text);
            var arguments = LaunchOptions.ParseArguments(flags.Text);
            problems.AddRange(LaunchOptions.Problems(arguments));
            if (name.Text.Trim().Length == 0) problems.Insert(0, "Give the profile a name.");
            if (problems.Count > 0)
            {
                pageMessage = string.Join("\n", problems);
                Render();
                return;
            }
            var badgeText = badge.Text.Trim();
            model.Update(account with
            {
                Name = name.Text.Trim(),
                Badge = badgeText.Length == 0 ? null : badgeText,
                ColorHex = string.Equals(draftColor, account.ResolvedColorHex, StringComparison.OrdinalIgnoreCase) && account.ColorHex is null ? null : draftColor,
                Environment = values,
                Arguments = arguments,
            });
        }
        name.KeyDown -= SaveOnEnter;
        name.KeyDown += SaveOnEnter;
        saveAction = Save;
        root.Children.Add(Buttons(("Cancel", () => model.ShowPage(Page.Accounts), false), ("Save", Save, true)));
    }

    private Action? saveAction;
    private void SaveOnEnter(object sender, KeyRoutedEventArgs e) { if (e.Key == VirtualKey.Enter) saveAction?.Invoke(); }
    private Grid? previewIcon;
    private Func<Account>? previewOf;

    private void UpdatePreview(object? sender, TextChangedEventArgs e)
    {
        if (previewIcon is null || previewOf is null) return;
        previewIcon.Children.Clear();
        previewIcon.Children.Add(ProfileIcon(previewOf(), false, 48));
    }

    private void RenderRemove()
    {
        var id = model.PageAccount ?? Guid.Empty;
        var name = model.Account(id)?.Name ?? "this account";
        root.Children.Add(PageHeader("Remove Account"));
        root.Children.Add(new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Text = $"Remove “{name}” from Clatch? Its saved Claude sign-in and local data go to the Recycle Bin, so you can still restore them from there."
                   + (model.Settings.ProfileShortcuts ? " Its shortcuts are removed too." : ""),
        });
        root.Children.Add(Buttons(("Cancel", () => model.ShowPage(Page.Accounts), false), ("Move to Recycle Bin", () => model.Remove(id), true)));
    }

    private void RenderConfirmSideBySide()
    {
        root.Children.Add(PageHeader("Run Profiles Side by Side?", Page.Settings));
        var points = new StackPanel { Spacing = 10 };
        points.Children.Add(Point("", "Each profile gets its own Claude window, and several can be open at once. Switching is instant."));
        points.Children.Add(Point("", "Several accounts are then signed in and active at the same time from this PC. One at a time is the more conservative choice: like signing out and in, only one account is ever active."));
        points.Children.Add(Point("", "Review Anthropic's terms for how your accounts may be used. Clatch does not change what each account is allowed to do."));
        root.Children.Add(Card(points, new Thickness(12), 8, Color.FromArgb(255, 247, 150, 70)));
        root.Children.Add(Caption("Every profile keeps its sign-in in both modes, and Clatch backs them up whenever the mode changes. You can go back at any time."));
        var terms = new HyperlinkButton { Content = "Anthropic's Terms", NavigateUri = AppModel.TermsUri, Padding = new Thickness(0) };
        root.Children.Add(terms);
        root.Children.Add(Buttons(("Cancel", () => model.ShowPage(Page.Settings), false), ("Use Side by Side", model.ConfirmSideBySide, true)));
    }

    private static UIElement Point(string glyph, string text)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new FontIcon { Glyph = glyph, FontSize = 16, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) });
        var label = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap };
        Grid.SetColumn(label, 1);
        grid.Children.Add(label);
        return grid;
    }

    private void RenderMoveChats()
    {
        root.Children.Add(PageHeader("Move Code Chats"));
        root.Children.Add(Caption("Copies a chat from Claude's Code tab to another profile, so you can carry on there. (claude.ai chats are stored by Anthropic per account and cannot be moved.)"));
        var accounts = model.State.Accounts;
        if (chatsFrom is not { } from || model.Account(from) is null) chatsFrom = from = model.State.ActiveId ?? accounts.FirstOrDefault()?.Id ?? Guid.Empty;
        if (chatsTo is not { } to || model.Account(to) is null) chatsTo = to = accounts.FirstOrDefault(a => a.Id != from)?.Id ?? Guid.Empty;

        ComboBox Picker(string header, Guid selected, Action<Guid> set)
        {
            var box = new ComboBox { Header = header, HorizontalAlignment = HorizontalAlignment.Stretch };
            foreach (var account in accounts) box.Items.Add(account.Name);
            box.SelectedIndex = accounts.FindIndex(a => a.Id == selected);
            box.SelectionChanged += (_, _) =>
            {
                if (box.SelectedIndex >= 0 && box.SelectedIndex < accounts.Count) { set(accounts[box.SelectedIndex].Id); DispatcherQueue.TryEnqueue(Render); }
            };
            return box;
        }
        var pickers = new Grid { ColumnSpacing = 8 };
        pickers.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        pickers.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        pickers.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        pickers.Children.Add(Picker("From", from, v => chatsFrom = v));
        var arrow = new FontIcon { Glyph = "", FontSize = 14, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 8) };
        Grid.SetColumn(arrow, 1);
        pickers.Children.Add(arrow);
        var toPicker = Picker("To", to, v => chatsTo = v);
        Grid.SetColumn(toPicker, 2);
        pickers.Children.Add(toPicker);
        root.Children.Add(pickers);
        AddMessages();

        List<CodeSession> sessions;
        try { sessions = model.CodeSessionsOf(from); }
        catch (Exception e) { sessions = []; Log.Error("listing Code chats", e); }
        if (sessions.Count == 0)
        {
            root.Children.Add(Card(Caption("No Code-tab chats in this profile yet."), new Thickness(12), 8));
            return;
        }
        var targetName = model.Account(to)?.Name ?? "the other profile";
        var list = new StackPanel();
        foreach (var session in sessions)
        {
            var text = new StackPanel();
            text.Children.Add(new TextBlock { Text = session.Title, TextTrimming = TextTrimming.CharacterEllipsis, FontWeight = FontWeights.SemiBold, FontSize = 13 });
            var detail = string.Join(" · ", new[] { session.Folder, Ago(session.Updated) }.Where(s => s.Length > 0));
            var caption = Caption(detail);
            caption.TextWrapping = TextWrapping.NoWrap;
            caption.TextTrimming = TextTrimming.CharacterEllipsis;
            text.Children.Add(caption);
            var button = new Button
            {
                Content = text, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left,
                Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0),
                Padding = new Thickness(10, 6, 10, 6), IsEnabled = to != from && to != Guid.Empty,
            };
            ToolTipService.SetToolTip(button, $"Copy to {targetName}");
            var target = to;
            button.Click += (_, _) => model.CopySession(session, target);
            list.Children.Add(button);
        }
        root.Children.Add(Card(new ScrollViewer { Content = list, MaxHeight = 260 }, new Thickness(2), 8));
    }

    private static string Ago(DateTime when)
    {
        var ago = DateTime.Now - when.ToLocalTime();
        return ago.TotalMinutes < 1 ? "just now"
            : ago.TotalHours < 1 ? $"{(int)ago.TotalMinutes} min ago"
            : ago.TotalDays < 1 ? $"{(int)ago.TotalHours} h ago"
            : $"{(int)ago.TotalDays} days ago";
    }

    private void RenderRestoreBackups()
    {
        root.Children.Add(PageHeader("Restore Sign-ins", Page.Settings));
        root.Children.Add(Caption("Clatch backs up every profile's sign-in when the mode changes (the newest three are kept). Restoring puts a profile's sign-in back as it was then; close that profile's Claude first."));
        AddMessages();
        var backups = model.Backups();
        if (backups.Count == 0)
        {
            root.Children.Add(Card(Caption("No backups yet."), new Thickness(12), 8));
            return;
        }
        var list = new StackPanel();
        foreach (var snapshot in backups)
        {
            var grid = new Grid { ColumnSpacing = 10 };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.Children.Add(new FontIcon { Glyph = "", FontSize = 16, VerticalAlignment = VerticalAlignment.Center });
            var text = new StackPanel();
            text.Children.Add(new TextBlock { Text = snapshot.Date.ToLocalTime().ToString("g"), FontWeight = FontWeights.SemiBold, FontSize = 13 });
            var names = Caption(string.Join(", ", snapshot.Profiles.Select(id => model.Account(id)?.Name).OfType<string>()));
            names.TextWrapping = TextWrapping.NoWrap;
            names.TextTrimming = TextTrimming.CharacterEllipsis;
            text.Children.Add(names);
            Grid.SetColumn(text, 1);
            grid.Children.Add(text);
            var restore = new TextBlock { Text = "Restore", FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = ThemeBrush("AccentTextFillColorPrimaryBrush"), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(restore, 2);
            grid.Children.Add(restore);
            var button = new Button
            {
                Content = grid, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(10, 6, 10, 6),
            };
            var chosen = snapshot;
            button.Click += (_, _) => model.Restore(chosen);
            list.Children.Add(button);
        }
        root.Children.Add(Card(list, new Thickness(2), 8));
    }

    private void RenderSettings()
    {
        root.Children.Add(PageHeader("Settings"));
        AddMessages();

        // How profiles run.
        var mode = new StackPanel { Spacing = 6 };
        mode.Children.Add(new TextBlock { Text = "Profiles", FontWeight = FontWeights.SemiBold });
        var choice = new RadioButtons { MaxColumns = 2, IsEnabled = !model.IsBusy };
        choice.Items.Add("One at a time");
        choice.Items.Add("Side by side");
        choice.SelectedIndex = model.SideBySide ? 1 : 0;
        choice.SelectionChanged += (_, _) =>
        {
            var wanted = choice.SelectedIndex == 1;
            if (wanted != model.SideBySide) DispatcherQueue.TryEnqueue(() => model.RequestSideBySide(wanted));
        };
        mode.Children.Add(choice);
        mode.Children.Add(Caption(model.SideBySide
            ? "Each profile runs its own Claude; the switcher brings it to the front or opens it."
            : "One Claude, one account active at a time; the switcher closes Claude, swaps the account and reopens it."));
        if (model.SideBySide)
        {
            mode.Children.Add(Toggle("Send sign-ins to the profile that asked", model.Settings.RouteSignIns, model.SetRouting,
                                     "Makes Clatch the handler for claude:// links and passes each one to the right profile's Claude."));
            if (model.Settings.RouteSignIns && LinkRouter.ChoiceOverridesClatch())
            {
                mode.Children.Add(Caption("Windows uses an app you chose earlier for claude:// links. Pick Clatch for “claude” in Default apps."));
                mode.Children.Add(SmallButton("Open Default Apps", AppModel.OpenDefaultAppsSettings));
            }
            mode.Children.Add(Toggle("Reopen profiles after Claude updates", model.Settings.Watchdog, model.SetWatchdog));
            mode.Children.Add(Toggle("Own taskbar button for each profile", model.Settings.SeparateTaskbarButtons, model.SetSeparateTaskbarButtons,
                                     "Each profile's Claude gets its own taskbar group and icon (applies to windows opened from now on)."));
        }
        root.Children.Add(Card(mode, new Thickness(12), 8));

        var shortcut = new StackPanel { Spacing = 8 };
        shortcut.Children.Add(new TextBlock { Text = "Profile switcher", FontWeight = FontWeights.SemiBold });
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
        shortcut.Children.Add(Caption("Hold the keys and tap the letter to move between profiles; let go to open the highlighted one."));
        var message = recorderMessage
            ?? (!model.HotKeyRegistered && model.Settings.EffectiveHotKey is not null
                ? "Another app already uses this shortcut. Choose a different one." : null);
        if (message is not null)
            shortcut.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, FontSize = 12, Foreground = new SolidColorBrush(Color.FromArgb(255, 220, 120, 30)) });
        root.Children.Add(Card(shortcut, new Thickness(12), 8));

        var toggles = new StackPanel { Spacing = 2 };
        toggles.Children.Add(Toggle("Profile shortcuts on the Desktop & Start menu", model.Settings.ProfileShortcuts, model.SetProfileShortcuts,
                                    "One shortcut per profile, kept in step as you add, rename or remove profiles."));
        if (!model.SideBySide)
            toggles.Children.Add(Toggle("Reopen Claude after switching", model.Settings.ReopenClaude, model.SetReopenClaude));
        toggles.Children.Add(Toggle("Same MCP & tool settings for every account", model.Settings.ShareToolSettings, model.SetShareToolSettings));
        toggles.Children.Add(Toggle("Check for updates daily", model.Settings.CheckForUpdates, model.SetCheckForUpdates));
        toggles.Children.Add(Toggle("Open Clatch when I sign in to Windows", StartAtLogin.IsEnabled, model.SetStartAtLogin));
        root.Children.Add(Card(toggles, new Thickness(12, 4, 12, 4), 8));

        var actions = new StackPanel();
        actions.Children.Add(ActionRow("Check for Updates", "", () => model.CheckForUpdates(force: true)));
        actions.Children.Add(ActionRow("Restore Sign-ins…", "", () => model.ShowPage(Page.RestoreBackups), !model.IsBusy));
        actions.Children.Add(ActionRow("Show Accounts Folder", "", model.RevealAccountsFolder));
        actions.Children.Add(ActionRow("Open Claude", "", () => { if (model.State.ActiveId is { } active) model.Open(active); else _ = model.Claude.OpenAsync(); },
                                       model.Claude.IsInstalled && !model.IsBusy));
        actions.Children.Add(ActionRow("Open Log", "", model.OpenLog));
        actions.Children.Add(ActionRow("Clatch on GitHub", "", () => AppModel.OpenUri(AppModel.ProjectUri)));
        root.Children.Add(actions);

        // What Clatch detected, so a wrong guess is visible at a glance.
        root.Children.Add(Caption(model.Claude.IsInstalled
            ? $"Claude Desktop ({(model.Claude.IsPackaged ? "Microsoft Store / MSIX" : "installer")}). Data: {model.Claude.DataFolder}"
            : "Claude Desktop not found."));

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
        if (!recording)
        {
            // Ctrl+1…9 opens the nth profile (as on the Mac).
            if (model.Page == Page.Accounts && !model.IsBusy && e.Key is >= VirtualKey.Number1 and <= VirtualKey.Number9
                && InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(CoreVirtualKeyStates.Down))
            {
                var n = e.Key - VirtualKey.Number1;
                if (n < model.State.Accounts.Count)
                {
                    e.Handled = true;
                    model.Open(model.State.Accounts[n].Id);
                    Close();
                }
            }
            return;
        }
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

    private static Color ParseColor(string hex)
    {
        var body = hex.TrimStart('#');
        if (body.Length != 6 || !body.All(Uri.IsHexDigit)) return Color.FromArgb(255, 217, 119, 87);
        var value = Convert.ToInt32(body, 16);
        return Color.FromArgb(255, (byte)(value >> 16), (byte)(value >> 8), (byte)value);
    }

    private static Color ProfileColor(Account account) => ParseColor(account.ResolvedColorHex);

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

    /// <summary>The badge alone (used if Claude's icon cannot be drawn).</summary>
    private static UIElement Avatar(Account account, double size) => new Border
    {
        Width = size, Height = size, CornerRadius = new CornerRadius(size / 2),
        Background = new SolidColorBrush(ProfileColor(account)),
        Child = new TextBlock
        {
            Text = account.BadgeText, Foreground = new SolidColorBrush(Colors.White), FontSize = size * 0.4,
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

    private static UIElement Toggle(string title, bool value, Action<bool> set, string? help = null)
    {
        var toggle = new ToggleSwitch { Header = null, OnContent = title, OffContent = title, IsOn = value };
        toggle.Toggled += (_, _) => { if (toggle.IsOn != value) set(toggle.IsOn); };
        if (help is not null) ToolTipService.SetToolTip(toggle, help);
        return toggle;
    }

    private UIElement PageHeader(string title, Page backTo = Page.Accounts)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        var back = new Button
        {
            Content = new FontIcon { Glyph = "", FontSize = 12 },
            Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0),
        };
        ToolTipService.SetToolTip(back, "Back");
        back.Click += (_, _) => model.ShowPage(backTo);
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
