// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using System.Text.Json;
using System.Text.Json.Serialization;
using Clatch.Core;
using Microsoft.Win32;

namespace Clatch;

/// <summary>The user's settings, in %LOCALAPPDATA%\Clatch\settings.json.</summary>
internal sealed class Settings
{
    public KeyCombo? HotKey { get; set; } = KeyCombo.Default;
    public bool HotKeyDisabled { get; set; }
    public bool ReopenClaude { get; set; } = true;
    public bool ShareToolSettings { get; set; } = true;
    /// <summary>Where Claude Desktop was last seen running, to find it again when it is closed.</summary>
    public string? LastClaudeExecutable { get; set; }
    /// <summary>Claude's data folder as last read from its --user-data-dir.</summary>
    public string? LastClaudeDataFolder { get; set; }

    [JsonIgnore]
    public KeyCombo? EffectiveHotKey => HotKeyDisabled ? null : HotKey ?? KeyCombo.Default;

    public static string Folder { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Clatch");

    private static string FilePath => Path.Combine(Folder, "settings.json");

    public static Settings Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return JsonSerializer.Deserialize(File.ReadAllText(FilePath), AppJsonContext.Default.Settings) ?? new Settings();
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException) { }
        return new Settings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Folder);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, AppJsonContext.Default.Settings));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}

/// <summary>"Open Clatch when I sign in", through the per-user Run key (no admin rights).</summary>
internal static class StartAtLogin
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "Clatch";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string;
        }
    }

    public static void Set(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled) key.SetValue(ValueName, $"\"{Environment.ProcessPath}\"");
        else key.DeleteValue(ValueName, throwOnMissingValue: false);
    }
}

[JsonSourceGenerationOptions(WriteIndented = true, PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(Settings))]
internal sealed partial class AppJsonContext : JsonSerializerContext;
