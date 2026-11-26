// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace Clatch.Interop;

/// <summary>
/// Shows a window only once it is drawn. A new window's Acrylic backdrop and
/// first frame take a moment; shown straight away, it would flash opaque. The
/// window is cloaked (DWM keeps it fully alive, so it can be activated and
/// laid out, but does not display it) until XAML has rendered two frames and
/// the backdrop has had one more to compose, then uncloaked. A fallback timer
/// uncloaks it in any case.
/// </summary>
internal static partial class Reveal
{
    private const int DWMWA_CLOAK = 13;

    [LibraryImport("dwmapi.dll")]
    private static partial int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);

    public static void Cloak(nint hwnd, bool cloaked)
    {
        var value = cloaked ? 1 : 0;
        _ = DwmSetWindowAttribute(hwnd, DWMWA_CLOAK, ref value, sizeof(int));
    }

    /// <summary>Cloaks the window, runs <paramref name="show"/>, and uncloaks it once drawn.</summary>
    public static void WhenDrawn(Window window, Action show)
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
        Cloak(hwnd, true);
        show();
        var dispatcher = window.DispatcherQueue;
        var frames = 0;
        var done = false;
        void Uncloak()
        {
            if (done) return;
            done = true;
            CompositionTarget.Rendering -= OnRendering;
            Cloak(hwnd, false);
        }
        void OnRendering(object? sender, object e)
        {
            if (++frames < 2) return;
            CompositionTarget.Rendering -= OnRendering;
            // One more beat for the system backdrop, which DWM composes on its own.
            var settle = dispatcher.CreateTimer();
            settle.Interval = TimeSpan.FromMilliseconds(34);
            settle.IsRepeating = false;
            settle.Tick += (_, _) => Uncloak();
            settle.Start();
        }
        CompositionTarget.Rendering += OnRendering;
        var fallback = dispatcher.CreateTimer();
        fallback.Interval = TimeSpan.FromMilliseconds(400);
        fallback.IsRepeating = false;
        fallback.Tick += (_, _) => Uncloak();
        fallback.Start();
        window.Closed += (_, _) => { done = true; CompositionTarget.Rendering -= OnRendering; };
    }
}
