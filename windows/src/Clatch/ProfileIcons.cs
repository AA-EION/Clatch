// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using System.Runtime.InteropServices;
using Clatch.Core;

namespace Clatch;

/// <summary>
/// Profile icons: the installed Claude's own icon with a coloured badge
/// holding the profile's letter (or emoji). Drawn on this PC from the app
/// that is installed, so Clatch never ships Anthropic's artwork. Rendered with
/// GDI+ (its flat API: no System.Drawing, works with NativeAOT) into PNG files
/// for the UI and multi-size .ico files for shortcuts and taskbar buttons,
/// cached in %LOCALAPPDATA%\Clatch\Icons.
/// </summary>
internal static unsafe partial class ProfileIcons
{
    public static string Folder { get; } = Path.Combine(Settings.Folder, "Icons");
    private static readonly int[] IcoSizes = [16, 20, 24, 32, 40, 48, 64, 256];

    /// <summary>A file name that changes whenever the icon's look does.</summary>
    private static string Key(Account account, string? baseExe)
    {
        var look = $"{account.BadgeText}|{account.ResolvedColorHex}|{baseExe}";
        var hash = (uint)look.Aggregate(17, (h, c) => unchecked(h * 31 + c));
        return $"{account.Id:N}-{hash:x8}";
    }

    /// <summary>The 256 px PNG of a profile's icon (made if missing).</summary>
    public static string Png(Account account, string? claudeExe)
    {
        var path = Path.Combine(Folder, Key(account, claudeExe) + ".png");
        if (!File.Exists(path)) Render(account, claudeExe, 256, path);
        return path;
    }

    /// <summary>The .ico of a profile's icon, every size Windows uses (made if missing).</summary>
    public static string Ico(Account account, string? claudeExe)
    {
        var path = Path.Combine(Folder, Key(account, claudeExe) + ".ico");
        if (File.Exists(path)) return path;
        Directory.CreateDirectory(Folder);
        var frames = new List<(int Size, byte[] Png)>();
        foreach (var size in IcoSizes)
        {
            var temp = Path.Combine(Folder, $"{Guid.NewGuid():N}.png");
            try
            {
                if (Render(account, claudeExe, size, temp)) frames.Add((size, File.ReadAllBytes(temp)));
            }
            finally
            {
                try { File.Delete(temp); } catch (IOException) { }
            }
        }
        WriteIco(path, frames);
        return path;
    }

    /// <summary>Removes cached icons of a profile other than its current look.</summary>
    public static void Prune(Account account, string? claudeExe)
    {
        if (!Directory.Exists(Folder)) return;
        var keep = Key(account, claudeExe);
        foreach (var file in Directory.GetFiles(Folder, $"{account.Id:N}-*"))
        {
            if (!Path.GetFileNameWithoutExtension(file).Equals(keep, StringComparison.OrdinalIgnoreCase))
            {
                try { File.Delete(file); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
        }
    }

    private static void WriteIco(string path, List<(int Size, byte[] Png)> frames)
    {
        using var stream = File.Create(path);
        using var writer = new BinaryWriter(stream);
        writer.Write((ushort)0);
        writer.Write((ushort)1);
        writer.Write((ushort)frames.Count);
        var offset = 6 + 16 * frames.Count;
        foreach (var (size, png) in frames)
        {
            writer.Write((byte)(size >= 256 ? 0 : size));
            writer.Write((byte)(size >= 256 ? 0 : size));
            writer.Write((byte)0);
            writer.Write((byte)0);
            writer.Write((ushort)1);
            writer.Write((ushort)32);
            writer.Write(png.Length);
            writer.Write(offset);
            offset += png.Length;
        }
        foreach (var (_, png) in frames) writer.Write(png);
    }

    // ---- Drawing ------------------------------------------------------------------

    private static nint gdiplusToken;

    private static void EnsureStarted()
    {
        if (gdiplusToken != 0) return;
        var input = new GdiplusStartupInput { GdiplusVersion = 1 };
        if (GdiplusStartup(out gdiplusToken, input, 0) != 0) gdiplusToken = 0;
    }

    /// <summary>Draws the badged icon at a pixel size into a PNG file.</summary>
    private static bool Render(Account account, string? claudeExe, int size, string pngPath)
    {
        EnsureStarted();
        if (gdiplusToken == 0) return false;
        Directory.CreateDirectory(Path.GetDirectoryName(pngPath)!);
        var pixels = new uint[size * size];
        DrawBaseIcon(claudeExe, size, pixels);
        fixed (uint* scan0 = pixels)
        {
            if (GdipCreateBitmapFromScan0(size, size, size * 4, PixelFormat32bppPARGB, (nint)scan0, out var bitmap) != 0) return false;
            try
            {
                GdipGetImageGraphicsContext(bitmap, out var graphics);
                try
                {
                    GdipSetSmoothingMode(graphics, SmoothingModeAntiAlias);
                    GdipSetTextRenderingHint(graphics, TextRenderingHintAntiAliasGridFit);
                    DrawBadge(graphics, account, size);
                }
                finally
                {
                    GdipDeleteGraphics(graphics);
                }
                var png = PngEncoder;
                return GdipSaveImageToFile(bitmap, pngPath, png, 0) == 0;
            }
            finally
            {
                GdipDisposeImage(bitmap);
            }
        }
    }

    /// <summary>The base picture: Claude's own icon (from its executable), else Clatch's.</summary>
    private static void DrawBaseIcon(string? claudeExe, int size, uint[] pixels)
    {
        var source = claudeExe is not null && File.Exists(claudeExe) ? claudeExe : Environment.ProcessPath;
        nint large = 0, small = 0;
        if (source is not null) SHDefExtractIconW(source, 0, 0, out large, out small, (uint)(size | (16 << 16)));
        if (small != 0) DestroyIcon(small);
        if (large == 0) return;
        try
        {
            // Draw into a 32-bit premultiplied DIB so the icon's transparency survives.
            var info = new BITMAPINFOHEADER
            {
                biSize = (uint)sizeof(BITMAPINFOHEADER), biWidth = size, biHeight = -size,
                biPlanes = 1, biBitCount = 32, biCompression = 0,
            };
            var screen = GetDC(0);
            var dc = CreateCompatibleDC(screen);
            var dib = CreateDIBSection(dc, &info, 0, out var bits, 0, 0);
            var old = SelectObject(dc, dib);
            DrawIconEx(dc, 0, 0, large, size, size, 0, 0, 3 /* DI_NORMAL */);
            new Span<uint>((void*)bits, size * size).CopyTo(pixels);
            SelectObject(dc, old);
            DeleteObject(dib);
            DeleteDC(dc);
            ReleaseDC(0, screen);
        }
        finally
        {
            DestroyIcon(large);
        }
    }

    private static void DrawBadge(nint graphics, Account account, int size)
    {
        var color = ParseColor(account.ResolvedColorHex);
        var diameter = size * 0.5f;
        var x = size - diameter - size * 0.02f;
        var y = size - diameter - size * 0.02f;

        // Soft shadow, the coloured disc, a white ring.
        GdipCreateSolidFill(0x40000000, out var shadow);
        GdipFillEllipse(graphics, shadow, x, y + size * 0.015f, diameter, diameter);
        GdipDeleteBrush(shadow);
        GdipCreateSolidFill(color, out var fill);
        GdipFillEllipse(graphics, fill, x, y, diameter, diameter);
        GdipDeleteBrush(fill);
        if (size >= 24)
        {
            GdipCreatePen1(0xFFFFFFFF, Math.Max(1f, size * 0.024f), 2 /* UnitPixel */, out var pen);
            var inset = size * 0.012f;
            GdipDrawEllipse(graphics, pen, x + inset, y + inset, diameter - 2 * inset, diameter - 2 * inset);
            GdipDeletePen(pen);
        }

        // The letter (or emoji), centred.
        var text = account.BadgeText;
        var isEmoji = text.Any(c => char.IsSurrogate(c) || c > 0x2000);
        if (GdipCreateFontFamilyFromName(isEmoji ? "Segoe UI Emoji" : "Segoe UI", 0, out var family) != 0 &&
            GdipCreateFontFamilyFromName("Segoe UI", 0, out family) != 0) return;
        var emSize = diameter * (text.Length > 1 && !isEmoji ? 0.42f : 0.56f);
        GdipCreateFont(family, emSize, 1 /* bold */, 2 /* pixel */, out var font);
        GdipCreateStringFormat(0, 0, out var format);
        GdipSetStringFormatAlign(format, 1 /* center */);
        GdipSetStringFormatLineAlign(format, 1 /* center */);
        GdipCreateSolidFill(0xFFFFFFFF, out var white);
        var rect = new RectF { X = x, Y = y + diameter * 0.02f, Width = diameter, Height = diameter };
        GdipDrawString(graphics, text, text.Length, font, rect, format, white);
        GdipDeleteBrush(white);
        GdipDeleteStringFormat(format);
        GdipDeleteFont(font);
        GdipDeleteFontFamily(family);
    }

    private static uint ParseColor(string hex)
    {
        var body = hex.TrimStart('#');
        return body.Length == 6 && uint.TryParse(body, System.Globalization.NumberStyles.HexNumber, null, out var rgb)
            ? 0xFF000000 | rgb : 0xFFD97757;
    }

    private static Guid PngEncoder => new("557CF406-1A04-11D3-9A73-0000F81EF32E");

    // ---- GDI / GDI+ ------------------------------------------------------------------

    private const int PixelFormat32bppPARGB = 0xE200B;
    private const int SmoothingModeAntiAlias = 4;
    private const int TextRenderingHintAntiAliasGridFit = 3;

    [StructLayout(LayoutKind.Sequential)]
    private struct GdiplusStartupInput
    {
        public uint GdiplusVersion;
        public nint DebugEventCallback;
        public int SuppressBackgroundThread;
        public int SuppressExternalCodecs;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RectF { public float X, Y, Width, Height; }

    [StructLayout(LayoutKind.Sequential)]
    private struct BITMAPINFOHEADER
    {
        public uint biSize;
        public int biWidth, biHeight;
        public ushort biPlanes, biBitCount;
        public uint biCompression, biSizeImage;
        public int biXPelsPerMeter, biYPelsPerMeter;
        public uint biClrUsed, biClrImportant;
    }

    [LibraryImport("gdiplus.dll")] private static partial int GdiplusStartup(out nint token, in GdiplusStartupInput input, nint output);
    [LibraryImport("gdiplus.dll")] private static partial int GdipCreateBitmapFromScan0(int width, int height, int stride, int format, nint scan0, out nint bitmap);
    [LibraryImport("gdiplus.dll")] private static partial int GdipGetImageGraphicsContext(nint image, out nint graphics);
    [LibraryImport("gdiplus.dll")] private static partial int GdipDeleteGraphics(nint graphics);
    [LibraryImport("gdiplus.dll")] private static partial int GdipDisposeImage(nint image);
    [LibraryImport("gdiplus.dll")] private static partial int GdipSetSmoothingMode(nint graphics, int mode);
    [LibraryImport("gdiplus.dll")] private static partial int GdipSetTextRenderingHint(nint graphics, int hint);
    [LibraryImport("gdiplus.dll")] private static partial int GdipCreateSolidFill(uint argb, out nint brush);
    [LibraryImport("gdiplus.dll")] private static partial int GdipDeleteBrush(nint brush);
    [LibraryImport("gdiplus.dll")] private static partial int GdipFillEllipse(nint graphics, nint brush, float x, float y, float width, float height);
    [LibraryImport("gdiplus.dll")] private static partial int GdipCreatePen1(uint argb, float width, int unit, out nint pen);
    [LibraryImport("gdiplus.dll")] private static partial int GdipDeletePen(nint pen);
    [LibraryImport("gdiplus.dll")] private static partial int GdipDrawEllipse(nint graphics, nint pen, float x, float y, float width, float height);
    [LibraryImport("gdiplus.dll", StringMarshalling = StringMarshalling.Utf16)] private static partial int GdipCreateFontFamilyFromName(string name, nint collection, out nint family);
    [LibraryImport("gdiplus.dll")] private static partial int GdipDeleteFontFamily(nint family);
    [LibraryImport("gdiplus.dll")] private static partial int GdipCreateFont(nint family, float emSize, int style, int unit, out nint font);
    [LibraryImport("gdiplus.dll")] private static partial int GdipDeleteFont(nint font);
    [LibraryImport("gdiplus.dll")] private static partial int GdipCreateStringFormat(int flags, ushort language, out nint format);
    [LibraryImport("gdiplus.dll")] private static partial int GdipDeleteStringFormat(nint format);
    [LibraryImport("gdiplus.dll")] private static partial int GdipSetStringFormatAlign(nint format, int align);
    [LibraryImport("gdiplus.dll")] private static partial int GdipSetStringFormatLineAlign(nint format, int align);
    [LibraryImport("gdiplus.dll", StringMarshalling = StringMarshalling.Utf16)] private static partial int GdipDrawString(nint graphics, string text, int length, nint font, in RectF layout, nint format, nint brush);
    [LibraryImport("gdiplus.dll", StringMarshalling = StringMarshalling.Utf16)] private static partial int GdipSaveImageToFile(nint image, string file, in Guid encoder, nint parameters);

    [LibraryImport("shell32.dll", StringMarshalling = StringMarshalling.Utf16)] private static partial int SHDefExtractIconW(string iconFile, int index, uint flags, out nint large, out nint small, uint sizes);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static partial bool DestroyIcon(nint icon);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static partial bool DrawIconEx(nint dc, int x, int y, nint icon, int width, int height, uint step, nint brush, uint flags);
    [LibraryImport("user32.dll")] private static partial nint GetDC(nint hwnd);
    [LibraryImport("user32.dll")] private static partial int ReleaseDC(nint hwnd, nint dc);
    [LibraryImport("gdi32.dll")] private static partial nint CreateCompatibleDC(nint dc);
    [LibraryImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static partial bool DeleteDC(nint dc);
    [LibraryImport("gdi32.dll")] private static partial nint CreateDIBSection(nint dc, BITMAPINFOHEADER* info, uint usage, out nint bits, nint section, uint offset);
    [LibraryImport("gdi32.dll")] private static partial nint SelectObject(nint dc, nint obj);
    [LibraryImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static partial bool DeleteObject(nint obj);
}
