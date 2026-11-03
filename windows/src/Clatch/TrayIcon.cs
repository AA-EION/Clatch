// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using System.Runtime.InteropServices;
using Clatch.Core;
using Clatch.Interop;
using Microsoft.UI.Dispatching;

namespace Clatch;

/// <summary>An item of the right-click menu.</summary>
internal sealed record TrayMenuItem(string Text, Action? Action, bool Checked = false, bool Enabled = true, bool IsDefault = false)
{
    public static readonly TrayMenuItem Separator = new("-", null);
}

/// <summary>
/// The notification area icon and the global shortcut, owned by one hidden
/// window on the UI thread. Neither costs anything until clicked or pressed:
/// Windows delivers one message, nothing polls.
/// </summary>
/// <remarks>
/// The window is an ordinary top-level window that is never shown (not a
/// message-only window): only top-level windows receive the "TaskbarCreated"
/// broadcast after Explorer restarts, and can take the foreground, which the
/// right-click menu needs. Events are handed to the UI queue instead of being
/// handled inside the window procedure, so creating the panel never happens
/// re-entrantly inside a Win32 callback.
/// </remarks>
internal sealed unsafe class TrayIcon : IDisposable
{
    public const string WindowClass = "ClatchTrayWindow";
    /// <summary>Posted by a second Clatch instance: "show your panel".</summary>
    public const uint ShowPanelMessage = Native.WM_APP + 2;
    /// <summary>Posted by "Clatch.exe --switch-next": same as the keyboard shortcut.</summary>
    public const uint SwitchNextMessage = Native.WM_APP + 3;
    private const uint CallbackMessage = Native.WM_APP + 1;
    private const int HotKeyId = 1;

    private static TrayIcon? current;
    private static readonly uint TaskbarCreated = Native.RegisterWindowMessageW("TaskbarCreated");

    private readonly DispatcherQueue dispatcher;
    private readonly nint hwnd;
    private readonly nint icon;
    private nint classNamePointer;

    /// <summary>Left click (with the point to anchor the panel to), or a second instance asking.</summary>
    public event Action<Native.POINT?>? LeftClicked;
    /// <summary>Right click: show the context menu at this point.</summary>
    public event Action<Native.POINT>? RightClicked;
    public event Action? HotKeyPressed;

    public TrayIcon(DispatcherQueue dispatcher, string iconPath, string tooltip)
    {
        this.dispatcher = dispatcher;
        current = this;
        var instance = Native.GetModuleHandleW(null);
        classNamePointer = Marshal.StringToHGlobalUni(WindowClass);
        var wc = new Native.WNDCLASSEXW
        {
            cbSize = (uint)sizeof(Native.WNDCLASSEXW),
            lpfnWndProc = (nint)(delegate* unmanaged<nint, uint, nint, nint, nint>)&WndProc,
            hInstance = instance,
            lpszClassName = classNamePointer,
        };
        if (Native.RegisterClassExW(&wc) == 0) Log.Write($"RegisterClassEx failed ({Marshal.GetLastPInvokeError()})");
        hwnd = Native.CreateWindowExW(Native.WS_EX_TOOLWINDOW, WindowClass, "Clatch", Native.WS_POPUP,
                                      0, 0, 0, 0, 0, 0, instance, 0);
        if (hwnd == 0) Log.Write($"CreateWindowEx failed ({Marshal.GetLastPInvokeError()})");
        icon = Native.LoadImageW(0, iconPath, Native.IMAGE_ICON,
                                 Native.GetSystemMetrics(Native.SM_CXSMICON), Native.GetSystemMetrics(Native.SM_CYSMICON),
                                 Native.LR_LOADFROMFILE);
        if (icon == 0) Log.Write($"Could not load the icon from {iconPath}");
        Tooltip = tooltip;
        AddIcon();
    }

    public string Tooltip { get; private set; }

    public void SetTooltip(string text)
    {
        Tooltip = text;
        var data = BaseData(Native.NIF_TIP | Native.NIF_SHOWTIP);
        Native.CopyTo(data.szTip, 128, text);
        Native.Shell_NotifyIconW(Native.NIM_MODIFY, &data);
    }

    private Native.NOTIFYICONDATAW BaseData(uint flags) => new()
    {
        cbSize = (uint)sizeof(Native.NOTIFYICONDATAW),
        hWnd = hwnd,
        uID = 1,
        uFlags = flags,
    };

    private void AddIcon()
    {
        var data = BaseData(Native.NIF_MESSAGE | Native.NIF_ICON | Native.NIF_TIP | Native.NIF_SHOWTIP);
        data.uCallbackMessage = CallbackMessage;
        data.hIcon = icon;
        Native.CopyTo(data.szTip, 128, Tooltip);
        var added = Native.Shell_NotifyIconW(Native.NIM_ADD, &data);
        data.uVersion = Native.NOTIFYICON_VERSION_4;
        var versioned = Native.Shell_NotifyIconW(Native.NIM_SETVERSION, &data);
        Log.Write($"Notification area icon added={added} version4={versioned}");
    }

    // ---- Right-click menu -------------------------------------------------------

    /// <summary>Shows the classic context menu and runs the chosen item.</summary>
    public void ShowMenu(Native.POINT point, IReadOnlyList<TrayMenuItem> items)
    {
        var menu = Native.CreatePopupMenu();
        try
        {
            for (var i = 0; i < items.Count; i++)
            {
                var item = items[i];
                if (ReferenceEquals(item, TrayMenuItem.Separator))
                {
                    Native.AppendMenuW(menu, Native.MF_SEPARATOR, 0, null);
                    continue;
                }
                var flags = Native.MF_STRING
                            | (item.Checked ? Native.MF_CHECKED : 0)
                            | (item.Enabled ? 0 : Native.MF_GRAYED)
                            | (item.IsDefault ? Native.MF_DEFAULT : 0);
                Native.AppendMenuW(menu, flags, (nuint)(i + 1), item.Text);
            }
            // Required so the menu closes when the user clicks elsewhere (KB135788).
            Native.SetForegroundWindow(hwnd);
            var chosen = Native.TrackPopupMenuEx(menu, Native.TPM_RETURNCMD | Native.TPM_NONOTIFY | Native.TPM_RIGHTBUTTON | Native.TPM_BOTTOMALIGN,
                                                 point.X, point.Y, hwnd, 0);
            Native.PostMessageW(hwnd, Native.WM_NULL, 0, 0);
            if (chosen > 0 && chosen <= items.Count) items[chosen - 1].Action?.Invoke();
        }
        finally
        {
            Native.DestroyMenu(menu);
        }
    }

    // ---- Global shortcut ------------------------------------------------------

    /// <returns>false when another app already owns the combination.</returns>
    public bool RegisterHotKey(KeyCombo? combo)
    {
        Native.UnregisterHotKey(hwnd, HotKeyId);
        if (combo is null) return true;
        var ok = Native.RegisterHotKey(hwnd, HotKeyId, combo.Modifiers | Native.MOD_NOREPEAT, combo.VirtualKey);
        Log.Write($"Shortcut {combo.DisplayString} registered={ok}");
        return ok;
    }

    // ---- Messages -------------------------------------------------------------

    private void Post(Action action) => dispatcher.TryEnqueue(() =>
    {
        try { action(); }
        catch (Exception e) { Log.Error("tray event", e); }
    });

    [UnmanagedCallersOnly]
    private static nint WndProc(nint hwnd, uint msg, nint wParam, nint lParam)
    {
        var tray = current;
        if (tray is not null && hwnd == tray.hwnd)
        {
            if (msg == CallbackMessage)
            {
                // NOTIFYICON_VERSION_4: event in LOWORD(lParam), anchor point in wParam.
                var evt = (uint)(lParam & 0xFFFF);
                var point = new Native.POINT { X = (short)(wParam & 0xFFFF), Y = (short)((wParam >> 16) & 0xFFFF) };
                if (evt is Native.NIN_SELECT or Native.NIN_KEYSELECT)
                {
                    tray.Post(() => tray.LeftClicked?.Invoke(point));
                }
                else if (evt == Native.WM_CONTEXTMENU)
                {
                    tray.Post(() => tray.RightClicked?.Invoke(point));
                }
                return 0;
            }
            if (msg == Native.WM_HOTKEY && (int)wParam == HotKeyId)
            {
                tray.Post(() => tray.HotKeyPressed?.Invoke());
                return 0;
            }
            if (msg == SwitchNextMessage)
            {
                tray.Post(() => tray.HotKeyPressed?.Invoke());
                return 0;
            }
            if (msg == ShowPanelMessage)
            {
                tray.Post(() => tray.LeftClicked?.Invoke(null));
                return 0;
            }
            if (msg == TaskbarCreated)
            {
                // Explorer restarted: the icon has to be added again.
                tray.Post(tray.AddIcon);
                return 0;
            }
        }
        return Native.DefWindowProcW(hwnd, msg, wParam, lParam);
    }

    public void Dispose()
    {
        var data = BaseData(0);
        Native.Shell_NotifyIconW(Native.NIM_DELETE, &data);
        Native.UnregisterHotKey(hwnd, HotKeyId);
        if (icon != 0) Native.DestroyIcon(icon);
        Native.DestroyWindow(hwnd);
        if (classNamePointer != 0) Marshal.FreeHGlobal(classNamePointer);
        classNamePointer = 0;
        current = null;
    }
}
