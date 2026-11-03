// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

namespace Clatch.Core;

/// <summary>A global shortcut in the form <c>RegisterHotKey</c> takes.</summary>
public sealed record KeyCombo(uint Modifiers, uint VirtualKey, string KeyLabel)
{
    public const uint Alt = 0x1, Control = 0x2, Shift = 0x4, Win = 0x8;

    /// <summary>
    /// Ctrl+Alt+Win+C. Ctrl+Alt alone is AltGr on many keyboard layouts
    /// (AltGr+C types "ć" on Polish keyboards), and most Win+letter
    /// combinations are reserved by Windows; the three together are free.
    /// </summary>
    public static KeyCombo Default { get; } = new(Control | Alt | Win, 0x43, "C");

    public string DisplayString
    {
        get
        {
            var parts = new List<string>();
            if ((Modifiers & Control) != 0) parts.Add("Ctrl");
            if ((Modifiers & Alt) != 0) parts.Add("Alt");
            if ((Modifiers & Shift) != 0) parts.Add("Shift");
            if ((Modifiers & Win) != 0) parts.Add("Win");
            parts.Add(KeyLabel);
            return string.Join("+", parts);
        }
    }

    /// <summary>Needs Ctrl, Alt or Win (function keys F1–F24 are fine alone).</summary>
    public bool IsAcceptable =>
        (Modifiers & (Control | Alt | Win)) != 0 || (VirtualKey >= 0x70 && VirtualKey <= 0x87);
}
