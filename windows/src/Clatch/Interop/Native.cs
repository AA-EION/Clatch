// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using System.Runtime.InteropServices;

namespace Clatch.Interop;

/// <summary>The few Win32 calls Clatch needs (source-generated, NativeAOT-friendly).</summary>
internal static unsafe partial class Native
{
    // ---- Windows and messages ----------------------------------------------

    public const uint WM_DESTROY = 0x0002, WM_HOTKEY = 0x0312, WM_CONTEXTMENU = 0x007B, WM_APP = 0x8000, WM_USER = 0x0400;
    public const uint NIN_SELECT = WM_USER, NIN_KEYSELECT = WM_USER + 1;
    public static readonly nint HWND_MESSAGE = -3;

    [StructLayout(LayoutKind.Sequential)]
    public struct WNDCLASSEXW
    {
        public uint cbSize, style;
        public nint lpfnWndProc;
        public int cbClsExtra, cbWndExtra;
        public nint hInstance, hIcon, hCursor, hbrBackground, lpszMenuName, lpszClassName, hIconSm;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [LibraryImport("user32.dll", SetLastError = true)]
    public static partial ushort RegisterClassExW(WNDCLASSEXW* wc);

    [LibraryImport("user32.dll", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    public static partial nint CreateWindowExW(uint exStyle, string className, string windowName, uint style,
        int x, int y, int w, int h, nint parent, nint menu, nint instance, nint param);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool DestroyWindow(nint hwnd);

    [LibraryImport("user32.dll")]
    public static partial nint DefWindowProcW(nint hwnd, uint msg, nint wParam, nint lParam);

    [LibraryImport("user32.dll", StringMarshalling = StringMarshalling.Utf16)]
    public static partial uint RegisterWindowMessageW(string name);

    [LibraryImport("user32.dll", StringMarshalling = StringMarshalling.Utf16)]
    public static partial nint FindWindowExW(nint parent, nint childAfter, string? className, string? windowName);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool PostMessageW(nint hwnd, uint msg, nint wParam, nint lParam);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetCursorPos(out POINT point);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetForegroundWindow(nint hwnd);

    [LibraryImport("user32.dll")]
    public static partial uint GetDpiForWindow(nint hwnd);

    [LibraryImport("kernel32.dll", StringMarshalling = StringMarshalling.Utf16)]
    public static partial nint GetModuleHandleW(string? name);

    public const uint WS_POPUP = 0x80000000, WS_EX_TOOLWINDOW = 0x00000080, WM_NULL = 0x0000;

    // ---- Context menu (the classic right-click menu of a notification area icon) ----

    public const uint MF_STRING = 0x0, MF_GRAYED = 0x1, MF_CHECKED = 0x8, MF_SEPARATOR = 0x800, MF_DEFAULT = 0x1000;
    public const uint TPM_RIGHTBUTTON = 0x2, TPM_RETURNCMD = 0x100, TPM_NONOTIFY = 0x80, TPM_BOTTOMALIGN = 0x20;

    [LibraryImport("user32.dll")]
    public static partial nint CreatePopupMenu();

    [LibraryImport("user32.dll", StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool AppendMenuW(nint menu, uint flags, nuint id, string? text);

    [LibraryImport("user32.dll")]
    public static partial int TrackPopupMenuEx(nint menu, uint flags, int x, int y, nint hwnd, nint parameters);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool DestroyMenu(nint menu);

    // ---- Hot key ------------------------------------------------------------

    public const uint MOD_NOREPEAT = 0x4000;

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool RegisterHotKey(nint hwnd, int id, uint modifiers, uint vk);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool UnregisterHotKey(nint hwnd, int id);

    // ---- Notification area icon ---------------------------------------------

    public const uint NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2, NIM_SETVERSION = 4;
    public const uint NIF_MESSAGE = 0x1, NIF_ICON = 0x2, NIF_TIP = 0x4, NIF_SHOWTIP = 0x80;
    public const uint NOTIFYICON_VERSION_4 = 4;

    [StructLayout(LayoutKind.Sequential)]
    public struct NOTIFYICONDATAW
    {
        public uint cbSize;
        public nint hWnd;
        public uint uID, uFlags, uCallbackMessage;
        public nint hIcon;
        public fixed ushort szTip[128];
        public uint dwState, dwStateMask;
        public fixed ushort szInfo[256];
        public uint uVersion;
        public fixed ushort szInfoTitle[64];
        public uint dwInfoFlags;
        public Guid guidItem;
        public nint hBalloonIcon;
    }

    [LibraryImport("shell32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool Shell_NotifyIconW(uint message, NOTIFYICONDATAW* data);

    public const uint IMAGE_ICON = 1, LR_LOADFROMFILE = 0x10;
    public const int SM_CXSMICON = 49, SM_CYSMICON = 50;

    [LibraryImport("user32.dll", StringMarshalling = StringMarshalling.Utf16)]
    public static partial nint LoadImageW(nint instance, string name, uint type, int cx, int cy, uint flags);

    [LibraryImport("user32.dll")]
    public static partial int GetSystemMetrics(int index);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool DestroyIcon(nint icon);

    // ---- Single instance ------------------------------------------------------

    public const int ERROR_ALREADY_EXISTS = 183;

    [LibraryImport("kernel32.dll", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    public static partial nint CreateMutexW(nint attributes, [MarshalAs(UnmanagedType.Bool)] bool initialOwner, string name);

    // ---- Processes ------------------------------------------------------------

    public const uint TH32CS_SNAPPROCESS = 0x2;
    public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESSENTRY32W
    {
        public uint dwSize, cntUsage, th32ProcessID;
        public nuint th32DefaultHeapID;
        public uint th32ModuleID, cntThreads, th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        public fixed ushort szExeFile[260];
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct FILETIME { public uint Low, High; }

    [LibraryImport("kernel32.dll", SetLastError = true)]
    public static partial nint CreateToolhelp32Snapshot(uint flags, uint processId);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool Process32FirstW(nint snapshot, PROCESSENTRY32W* entry);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool Process32NextW(nint snapshot, PROCESSENTRY32W* entry);

    [LibraryImport("kernel32.dll")]
    public static partial nint OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint processId);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool CloseHandle(nint handle);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool QueryFullProcessImageNameW(nint process, uint flags, char* buffer, ref uint size);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetProcessTimes(nint process, out FILETIME creation, out FILETIME exit, out FILETIME kernel, out FILETIME user);

    // ---- Restart Manager: the Windows way to ask an app to close ---------------

    [StructLayout(LayoutKind.Sequential)]
    public struct RM_UNIQUE_PROCESS
    {
        public uint dwProcessId;
        public FILETIME ProcessStartTime;
    }

    [LibraryImport("rstrtmgr.dll")]
    public static partial int RmStartSession(out uint session, uint flags, char* sessionKey);

    [LibraryImport("rstrtmgr.dll")]
    public static partial int RmRegisterResources(uint session, uint nFiles, nint files, uint nApplications,
        RM_UNIQUE_PROCESS* applications, uint nServices, nint services);

    [LibraryImport("rstrtmgr.dll")]
    public static partial int RmShutdown(uint session, uint flags, nint statusCallback);

    [LibraryImport("rstrtmgr.dll")]
    public static partial int RmEndSession(uint session);

    // ---- Recycle Bin ----------------------------------------------------------

    public const uint FO_DELETE = 3;
    public const ushort FOF_ALLOWUNDO = 0x40, FOF_NOCONFIRMATION = 0x10, FOF_SILENT = 0x4, FOF_NOERRORUI = 0x400;

    [StructLayout(LayoutKind.Sequential)]
    public struct SHFILEOPSTRUCTW
    {
        public nint hwnd;
        public uint wFunc;
        public nint pFrom, pTo;
        public ushort fFlags;
        public int fAnyOperationsAborted;
        public nint hNameMappings, lpszProgressTitle;
    }

    [LibraryImport("shell32.dll")]
    public static partial int SHFileOperationW(SHFILEOPSTRUCTW* operation);

    public static void SendToRecycleBin(string path)
    {
        // pFrom is a list of NUL-terminated strings ending with an extra NUL.
        var from = Marshal.StringToHGlobalUni(path + "\0");
        try
        {
            var op = new SHFILEOPSTRUCTW
            {
                wFunc = FO_DELETE,
                pFrom = from,
                fFlags = (ushort)(FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI),
            };
            var result = SHFileOperationW(&op);
            if (result != 0) throw new IOException($"Could not move {path} to the Recycle Bin (error {result}).");
        }
        finally
        {
            Marshal.FreeHGlobal(from);
        }
    }

    public static void CopyTo(ushort* destination, int capacity, string text)
    {
        var length = Math.Min(text.Length, capacity - 1);
        for (var i = 0; i < length; i++) destination[i] = text[i];
        destination[length] = 0;
    }
}
