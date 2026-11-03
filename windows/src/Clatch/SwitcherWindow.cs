// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using System.Numerics;
using System.Runtime.InteropServices;
using Clatch.Core;
using Clatch.Interop;
using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics;
using Windows.UI;
using WinRT;

namespace Clatch;

/// <summary>
/// The Alt-Tab-style profile switcher.
/// </summary>
/// <remarks>
/// The global shortcut opens it with the next profile highlighted; pressing
/// the shortcut again moves the highlight (with Shift, or ←/→ while holding
/// the modifiers, it moves back/forward). Letting go of the modifiers opens
/// the highlighted profile; Esc cancels; Enter opens it at once; a click works
/// too. While it is open Clatch reads the modifier keys' state
/// (GetAsyncKeyState, no keyboard hook) and registers those few extra
/// shortcuts; all of it stops when the switcher closes, and the window is
/// released so nothing renders while it is not shown.
/// </remarks>
internal sealed partial class SwitcherWindow : Window
{
    public sealed record Tile(Account Account, string IconPath, bool IsCurrent, bool IsRunning);

    private const double TileWidth = 124, TileHeight = 132;
    private readonly List<Tile> tiles;
    private readonly bool sideBySide;
    private readonly KeyCombo combo;
    private readonly Border highlight = new() { Width = TileWidth - 6, Height = TileHeight, CornerRadius = new CornerRadius(16) };
    private readonly List<Image> icons = [];
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer timer;
    private readonly DateTimeOffset shownAt = DateTimeOffset.Now;
    private DesktopAcrylicController? acrylic;
    private SystemBackdropConfiguration? backdropConfiguration;
    private int selection;
    private bool done;

    public event Action<Guid>? Chosen;
    public event Action? Dismissed;
    public bool IsDone => done;

    public SwitcherWindow(List<Tile> tiles, int selection, bool sideBySide, KeyCombo combo)
    {
        this.tiles = tiles;
        this.selection = selection;
        this.sideBySide = sideBySide;
        this.combo = combo;
        Title = "Clatch profile switcher";

        var presenter = OverlappedPresenter.Create();
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.IsAlwaysOnTop = true;
        presenter.SetBorderAndTitleBar(true, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;

        Content = Build();
        ApplyAcrylic();
        Place();
        Select(selection, animate: false);

        timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(16);
        timer.Tick += (_, _) => CheckModifiers();
        timer.Start();
        Closed += (_, _) => Finish();
    }

    /// <summary>Shown without taking the keyboard focus: the keys stay with the shortcut.</summary>
    public void ShowWithoutActivating() => AppWindow.Show(false);

    // ---- Content ---------------------------------------------------------------------

    private UIElement Build()
    {
        var accent = Color.FromArgb(255, 0, 120, 212);
        try { accent = new Windows.UI.ViewManagement.UISettings().GetColorValue(Windows.UI.ViewManagement.UIColorType.Accent); } catch (Exception) { }

        highlight.Background = new SolidColorBrush(Color.FromArgb(56, accent.R, accent.G, accent.B));
        highlight.BorderBrush = new SolidColorBrush(Color.FromArgb(110, accent.R, accent.G, accent.B));
        highlight.BorderThickness = new Thickness(1);
        // The highlight glides between tiles (an implicit animation of its translation).
        highlight.TranslationTransition = new Vector3Transition { Duration = TimeSpan.FromMilliseconds(180) };

        var row = new StackPanel { Orientation = Orientation.Horizontal };
        for (var i = 0; i < tiles.Count; i++) row.Children.Add(TileView(tiles[i], i));

        var surface = new Grid { Padding = new Thickness(16, 18, 16, 10) };
        var layers = new Grid();
        var lane = new Canvas { Width = tiles.Count * TileWidth, Height = TileHeight };
        lane.Children.Add(highlight);
        layers.Children.Add(lane);
        layers.Children.Add(row);
        var stack = new StackPanel { Spacing = 8 };
        stack.Children.Add(layers);
        stack.Children.Add(new TextBlock
        {
            Text = sideBySide ? "Release to open · Esc to cancel" : "Release to switch · Esc to cancel",
            FontSize = 11, HorizontalAlignment = HorizontalAlignment.Center, Opacity = 0.7,
        });
        surface.Children.Add(stack);
        return surface;
    }

    private UIElement TileView(Tile tile, int index)
    {
        var icon = new Image
        {
            Width = 72, Height = 72, Source = new BitmapImage(new Uri(tile.IconPath)),
            CenterPoint = new Vector3(36, 36, 0),
            ScaleTransition = new Vector3Transition { Duration = TimeSpan.FromMilliseconds(180) },
        };
        icons.Add(icon);
        var iconHost = new Grid { Width = 72, Height = 72, HorizontalAlignment = HorizontalAlignment.Center };
        iconHost.Children.Add(icon);
        if (tile.IsRunning && sideBySide)
        {
            iconHost.Children.Add(new Border
            {
                Width = 12, Height = 12, CornerRadius = new CornerRadius(6), HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Top, Background = new SolidColorBrush(Color.FromArgb(255, 48, 209, 88)),
                BorderBrush = new SolidColorBrush(Colors.White), BorderThickness = new Thickness(2),
            });
        }
        var name = new TextBlock
        {
            Text = (tile.IsCurrent && !sideBySide ? "✓ " : "") + tile.Account.Name, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis,
            HorizontalAlignment = HorizontalAlignment.Center, MaxWidth = TileWidth - 16,
        };
        var stack = new StackPanel { Spacing = 10, Width = TileWidth, Height = TileHeight, Padding = new Thickness(0, 14, 0, 0) };
        stack.Children.Add(iconHost);
        stack.Children.Add(name);
        // A click (or tap) picks a profile too.
        var button = new Button
        {
            Content = stack, Padding = new Thickness(0), Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
        };
        button.Click += (_, _) => { Select(index, animate: true); Commit(); };
        return button;
    }

    private void Select(int index, bool animate)
    {
        selection = (index % tiles.Count + tiles.Count) % tiles.Count;
        if (!animate) highlight.TranslationTransition = null;
        highlight.Translation = new Vector3((float)(selection * TileWidth + 3), 0, 0);
        if (!animate) highlight.TranslationTransition = new Vector3Transition { Duration = TimeSpan.FromMilliseconds(180) };
        for (var i = 0; i < icons.Count; i++)
            icons[i].Scale = i == selection ? new Vector3(1.1f, 1.1f, 1) : new Vector3(0.94f, 0.94f, 1);
    }

    public void Step(int delta)
    {
        if (!done) Select(selection + delta, animate: true);
    }

    // ---- Window ------------------------------------------------------------------------

    private void Place()
    {
        Native.GetCursorPos(out var cursor);
        var area = DisplayArea.GetFromPoint(new PointInt32(cursor.X, cursor.Y), DisplayAreaFallback.Nearest).WorkArea;
        var scale = Native.GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        var width = (int)Math.Min((tiles.Count * TileWidth + 34) * scale, area.Width - 80);
        var height = (int)((TileHeight + 62) * scale);
        AppWindow.MoveAndResize(new RectInt32(area.X + (area.Width - width) / 2, area.Y + (area.Height - height) / 2 - area.Height / 12, width, height));
    }

    /// <summary>
    /// Acrylic that stays "active" although the window never takes focus
    /// (the stock backdrop would turn grey for an inactive window).
    /// </summary>
    private void ApplyAcrylic()
    {
        if (!DesktopAcrylicController.IsSupported())
        {
            if (Content is Panel panel)
                panel.Background = Application.Current.Resources.TryGetValue("SolidBackgroundFillColorBaseBrush", out var brush) && brush is Brush b
                    ? b : new SolidColorBrush(Color.FromArgb(255, 32, 32, 32));
            return;
        }
        backdropConfiguration = new SystemBackdropConfiguration { IsInputActive = true };
        if (Content is FrameworkElement element)
        {
            backdropConfiguration.Theme = element.ActualTheme == ElementTheme.Light ? SystemBackdropTheme.Light : SystemBackdropTheme.Dark;
        }
        acrylic = new DesktopAcrylicController { Kind = DesktopAcrylicKind.Thin };
        acrylic.AddSystemBackdropTarget(this.As<Microsoft.UI.Composition.ICompositionSupportsSystemBackdrop>());
        acrylic.SetSystemBackdropConfiguration(backdropConfiguration);
    }

    // ---- Keys --------------------------------------------------------------------------

    private void CheckModifiers()
    {
        if (done) return;
        static bool Down(int vk) => (GetAsyncKeyState(vk) & 0x8000) != 0;
        var held = false;
        if ((combo.Modifiers & KeyCombo.Control) != 0 && Down(0x11)) held = true;
        if ((combo.Modifiers & KeyCombo.Alt) != 0 && Down(0x12)) held = true;
        if ((combo.Modifiers & KeyCombo.Win) != 0 && (Down(0x5B) || Down(0x5C))) held = true;
        if ((combo.Modifiers & ~KeyCombo.Shift) == 0 && (combo.Modifiers & KeyCombo.Shift) != 0 && Down(0x10)) held = true;
        if (combo.Modifiers == 0) held = Down((int)combo.VirtualKey); // a function key alone
        if (!held && DateTimeOffset.Now - shownAt > TimeSpan.FromMilliseconds(80)) Commit();
    }

    public void Commit()
    {
        if (done) return;
        var chosen = tiles[selection].Account.Id;
        Finish();
        Chosen?.Invoke(chosen);
        Close();
    }

    public void Cancel()
    {
        if (done) return;
        Finish();
        Dismissed?.Invoke();
        Close();
    }

    private void Finish()
    {
        if (done) return;
        done = true;
        timer.Stop();
        acrylic?.Dispose();
        acrylic = null;
    }

    [LibraryImport("user32.dll")]
    private static partial short GetAsyncKeyState(int vk);
}
