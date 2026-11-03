// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

namespace Clatch;

/// <summary>
/// A small diagnostic log at %LOCALAPPDATA%\Clatch\clatch.log (kept under
/// 256 KB). Records what Clatch did and any error, never account data.
/// </summary>
internal static class Log
{
    private static readonly object Gate = new();
    public static string FilePath { get; } = Path.Combine(Settings.Folder, "clatch.log");

    public static void Write(string message)
    {
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(Settings.Folder);
                var info = new FileInfo(FilePath);
                if (info.Exists && info.Length > 256 * 1024)
                    File.Move(FilePath, FilePath + ".old", overwrite: true);
                File.AppendAllText(FilePath, $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss.fff} {message}{Environment.NewLine}");
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Logging must never break the app.
        }
    }

    public static void Error(string what, Exception e) => Write($"ERROR {what}: {e.GetType().Name}: {e.Message}{Environment.NewLine}{e.StackTrace}");
}
