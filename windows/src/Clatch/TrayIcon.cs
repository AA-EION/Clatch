// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Clatch.Core;
using Clatch.Interop;

namespace Clatch;

/// <summary>
/// The notification area icon and the global shortcut, both owned by one
/// invisible message-only window on the UI thread. Neither costs anything
/// until clicked or pressed: Windows delivers one message, nothing polls.
/// </summary>
internal sealed unsafe class TrayIcon : IDisposable
{
    public const string WindowClass = "ClatchTrayWindow";
    /// <summary>Posted by a second Clatch instance: "show your panel".</summary>
    public const uint ShowPanelMessage = Native.WM_APP + 2;
    private const uint CallbackMessage = Native.WM_APP + 1;
    private const int HotKeyId = 1;

    private static TrayIcon? current;
    private static readonly uint TaskbarCreated = Native.RegisterWindowMessageW("TaskbarCreated");

    private readonly nint hwnd;
    private readonly nint icon;
    private nint classNamePointer;

    /// <summary>Clicked (with the point to anchor the panel to), or asked to show the panel.</summary>
    public event Action<Native.POINT?>? Activated;
    public event Action? HotKeyPressed;

    public TrayIcon(string iconPath, string tooltip)
    {
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
        Native.RegisterClassExW(&wc);
        hwnd = Native.CreateWindowExW(0, WindowClass, "Clatch", 0, 0, 0, 0, 0, Native.HWND_MESSAGE, 0, instance, 0);
        icon = Native.LoadImageW(0, iconPath, Native.IMAGE_ICON,
                                 Native.GetSystemMetrics(Native.SM_CXSMICON), Native.GetSystemMetrics(Native.SM_CYSMICON),
                                 Native.LR_LOADFROMFILE);
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
        Native.Shell_NotifyIconW(Native.NIM_ADD, &data);
        data.uVersion = Native.NOTIFYICON_VERSION_4;
        Native.Shell_NotifyIconW(Native.NIM_SETVERSION, &data);
    }

    // ---- Global shortcut ------------------------------------------------------

    /// <returns>false when another app already owns the combination.</returns>
    public bool RegisterHotKey(KeyCombo? combo)
    {
        Native.UnregisterHotKey(hwnd, HotKeyId);
        if (combo is null) return true;
        return Native.RegisterHotKey(hwnd, HotKeyId, combo.Modifiers | Native.MOD_NOREPEAT, combo.VirtualKey);
    }

    public void UnregisterHotKey() => Native.UnregisterHotKey(hwnd, HotKeyId);

    // ---- Messages -------------------------------------------------------------

    [UnmanagedCallersOnly]
    private static nint WndProc(nint hwnd, uint msg, nint wParam, nint lParam)
    {
        var tray = current;
        if (tray is not null && hwnd == tray.hwnd)
        {
            try
            {
                if (msg == CallbackMessage)
                {
                    // NOTIFYICON_VERSION_4: event in LOWORD(lParam), anchor point in wParam.
                    var evt = (uint)(lParam & 0xFFFF);
                    if (evt is Native.NIN_SELECT or Native.NIN_KEYSELECT or Native.WM_CONTEXTMENU)
                    {
                        var point = new Native.POINT { X = (short)(wParam & 0xFFFF), Y = (short)((wParam >> 16) & 0xFFFF) };
                        tray.Activated?.Invoke(point);
                    }
                    return 0;
                }
                if (msg == Native.WM_HOTKEY && (int)wParam == HotKeyId)
                {
                    tray.HotKeyPressed?.Invoke();
                    return 0;
                }
                if (msg == ShowPanelMessage)
                {
                    tray.Activated?.Invoke(null);
                    return 0;
                }
                if (msg == TaskbarCreated)
                {
                    // Explorer restarted: the icon has to be added again.
                    tray.AddIcon();
                    return 0;
                }
            }
            catch (Exception e)
            {
                System.Diagnostics.Debug.WriteLine(e);
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
