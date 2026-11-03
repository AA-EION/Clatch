// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using System.Runtime.InteropServices;
using System.Runtime.InteropServices.Marshalling;

namespace Clatch.Interop;

// Source-generated COM (works with NativeAOT): shortcuts (.lnk) and the
// AppUserModelID properties that give each profile its own taskbar button.

[GeneratedComInterface(StringMarshalling = StringMarshalling.Utf16)]
[Guid("000214F9-0000-0000-C000-000000000046")]
internal partial interface IShellLinkW
{
    void GetPath(nint file, int max, nint findData, uint flags);
    void GetIDList(out nint idList);
    void SetIDList(nint idList);
    void GetDescription(nint name, int max);
    void SetDescription(string name);
    void GetWorkingDirectory(nint dir, int max);
    void SetWorkingDirectory(string dir);
    void GetArguments(nint args, int max);
    void SetArguments(string args);
    void GetHotkey(out ushort hotkey);
    void SetHotkey(ushort hotkey);
    void GetShowCmd(out int showCmd);
    void SetShowCmd(int showCmd);
    void GetIconLocation(nint iconPath, int max, out int icon);
    void SetIconLocation(string iconPath, int icon);
    void SetRelativePath(string path, uint reserved);
    void Resolve(nint hwnd, uint flags);
    void SetPath(string file);
}

[GeneratedComInterface(StringMarshalling = StringMarshalling.Utf16)]
[Guid("0000010b-0000-0000-C000-000000000046")]
internal partial interface IPersistFile
{
    void GetClassID(out Guid classId);
    [PreserveSig] int IsDirty();
    void Load(string fileName, uint mode);
    void Save(string fileName, [MarshalAs(UnmanagedType.Bool)] bool remember);
    void SaveCompleted(string fileName);
    void GetCurFile(out nint fileName);
}

[StructLayout(LayoutKind.Sequential)]
internal struct PROPERTYKEY
{
    public Guid fmtid;
    public uint pid;
    public PROPERTYKEY(Guid f, uint p) { fmtid = f; pid = p; }
}

/// <summary>A PROPVARIANT holding a string (VT_LPWSTR) or nothing (VT_EMPTY).</summary>
[StructLayout(LayoutKind.Explicit, Size = 24)]
internal struct PROPVARIANT
{
    [FieldOffset(0)] public ushort vt;
    [FieldOffset(8)] public nint pointer;
}

[GeneratedComInterface]
[Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
internal partial interface IPropertyStore
{
    void GetCount(out uint count);
    void GetAt(uint index, out PROPERTYKEY key);
    void GetValue(in PROPERTYKEY key, out PROPVARIANT value);
    void SetValue(in PROPERTYKEY key, in PROPVARIANT value);
    void Commit();
}

internal static unsafe partial class Shell
{
    private static readonly Guid CLSID_ShellLink = new("00021401-0000-0000-C000-000000000046");
    private static readonly Guid IID_IUnknown = new("00000000-0000-0000-C000-000000000046");
    private static readonly Guid IID_IPropertyStore = new("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    private static readonly Guid AppUserModel = new("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    private static readonly StrategyBasedComWrappers Wrappers = new();

    public static PROPERTYKEY AppUserModelId => new(AppUserModel, 5);
    public static PROPERTYKEY RelaunchCommand => new(AppUserModel, 2);
    public static PROPERTYKEY RelaunchIconResource => new(AppUserModel, 3);
    public static PROPERTYKEY RelaunchDisplayNameResource => new(AppUserModel, 4);

    [LibraryImport("ole32.dll")]
    private static partial int CoCreateInstance(in Guid clsid, nint outer, uint context, in Guid iid, out nint instance);

    [LibraryImport("shell32.dll")]
    private static partial int SHGetPropertyStoreForWindow(nint hwnd, in Guid iid, out nint store);

    private const uint CLSCTX_INPROC_SERVER = 1;
    private const ushort VT_EMPTY = 0, VT_LPWSTR = 31;

    /// <summary>Writes a shortcut. The AppUserModelID ties windows carrying the same id to it on the taskbar.</summary>
    public static void CreateShortcut(string path, string target, string arguments, string iconPath, string description,
                                      string? appUserModelId)
    {
        Marshal.ThrowExceptionForHR(CoCreateInstance(CLSID_ShellLink, 0, CLSCTX_INPROC_SERVER, IID_IUnknown, out var unknown));
        try
        {
            var link = (IShellLinkW)Wrappers.GetOrCreateObjectForComInstance(unknown, CreateObjectFlags.None);
            link.SetPath(target);
            link.SetArguments(arguments);
            link.SetIconLocation(iconPath, 0);
            link.SetDescription(description);
            link.SetWorkingDirectory(Path.GetDirectoryName(target)!);
            if (appUserModelId is not null)
            {
                var store = (IPropertyStore)link;
                SetString(store, AppUserModelId, appUserModelId);
                store.Commit();
            }
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            ((IPersistFile)link).Save(path, true);
        }
        finally
        {
            Marshal.Release(unknown);
        }
    }

    /// <summary>
    /// Gives another process's window its own taskbar identity: windows with the
    /// same AppUserModelID share a taskbar button, and the relaunch properties
    /// say what a pinned button runs and shows.
    /// </summary>
    public static bool SetWindowIdentity(nint hwnd, string appUserModelId, string relaunchCommand, string displayName, string iconResource)
    {
        if (SHGetPropertyStoreForWindow(hwnd, IID_IPropertyStore, out var pointer) != 0 || pointer == 0) return false;
        try
        {
            var store = (IPropertyStore)Wrappers.GetOrCreateObjectForComInstance(pointer, CreateObjectFlags.None);
            // The relaunch properties must be set before the id for the taskbar to pick them up.
            SetString(store, RelaunchCommand, relaunchCommand);
            SetString(store, RelaunchDisplayNameResource, displayName);
            SetString(store, RelaunchIconResource, iconResource);
            SetString(store, AppUserModelId, appUserModelId);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
        finally
        {
            Marshal.Release(pointer);
        }
    }

    private static void SetString(IPropertyStore store, PROPERTYKEY key, string? value)
    {
        var variant = new PROPVARIANT { vt = VT_EMPTY };
        nint text = 0;
        if (value is not null)
        {
            text = Marshal.StringToCoTaskMemUni(value);
            variant = new PROPVARIANT { vt = VT_LPWSTR, pointer = text };
        }
        try { store.SetValue(key, variant); }
        finally { if (text != 0) Marshal.FreeCoTaskMem(text); }
    }

    // ---- Window events (no polling: Windows calls back on Clatch's UI thread) ----

    public const uint EVENT_SYSTEM_FOREGROUND = 0x0003, EVENT_OBJECT_SHOW = 0x8002;
    public const uint WINEVENT_OUTOFCONTEXT = 0x0000, WINEVENT_SKIPOWNPROCESS = 0x0002;
    public const int OBJID_WINDOW = 0;

    [LibraryImport("user32.dll")]
    public static partial nint SetWinEventHook(uint eventMin, uint eventMax, nint module,
        delegate* unmanaged<nint, uint, nint, int, int, uint, uint, void> callback, uint processId, uint threadId, uint flags);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool UnhookWinEvent(nint hook);

    [LibraryImport("user32.dll")]
    public static partial nint GetAncestor(nint hwnd, uint flags);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool IsWindowVisible(nint hwnd);

    [LibraryImport("user32.dll")]
    public static partial nint GetForegroundWindow();

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool ShowWindow(nint hwnd, int command);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool IsIconic(nint hwnd);

    [LibraryImport("user32.dll")]
    public static partial nint GetWindow(nint hwnd, uint command);

    [LibraryImport("user32.dll")]
    public static partial int GetWindowTextLengthW(nint hwnd);

    public const uint GA_ROOT = 2, GW_OWNER = 4;
    public const int SW_RESTORE = 9;
}
