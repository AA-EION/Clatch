// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group
//
// Clatch is free software: you can redistribute it and/or modify it under the
// terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later
// version. See LICENSE.

using System.Runtime.InteropServices;
using Clatch.Interop;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Clatch;

public static class Program
{
    [STAThread]
    public static unsafe int Main()
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();

        // One Clatch per user session. A second launch asks the first to open its panel.
        Native.CreateMutexW(0, false, @"Local\Clatch-6E1B3C2A-9F4D-4A51-8C0B-3D2E7A9F1C55");
        if (Marshal.GetLastPInvokeError() == Native.ERROR_ALREADY_EXISTS)
        {
            var existing = Native.FindWindowExW(0, 0, TrayIcon.WindowClass, null);
            // Hand the arguments (a profile shortcut, a claude:// link, a script) to the running Clatch.
            var args = Environment.GetCommandLineArgs().Skip(1).ToArray();
            if (existing != 0)
            {
                if (args.Length == 0)
                {
                    Native.PostMessageW(existing, TrayIcon.ShowPanelMessage, 0, 0);
                }
                else
                {
                    var text = string.Join('\0', args);
                    fixed (char* chars = text)
                    {
                        var data = new TrayIcon.COPYDATASTRUCT { dwData = TrayIcon.CommandMagic, cbData = (uint)(text.Length * 2), lpData = (nint)chars };
                        Native.SendMessageTimeoutW(existing, TrayIcon.WM_COPYDATA, 0, (nint)(&data), Native.SMTO_ABORTIFHUNG, 5000, out _);
                    }
                }
            }
            return 0;
        }

        Application.Start(_ =>
        {
            SynchronizationContext.SetSynchronizationContext(
                new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            new App();
        });
        return 0;
    }
}
