// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using System.Text.Json.Serialization;

namespace Clatch.Core;

/// <summary>
/// One Claude Desktop sign-in that Clatch keeps. Only a name for a copy of
/// Claude's own data folder: Clatch never reads or stores credentials.
/// </summary>
public sealed record Account
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.Now;
    public DateTimeOffset? LastUsedAt { get; set; }
    /// <summary>Text on the profile's badge (a letter or an emoji); null = first letter of the name.</summary>
    public string? Badge { get; set; }
    /// <summary>Badge colour "#RRGGBB"; null = picked from the id.</summary>
    public string? ColorHex { get; set; }
    /// <summary>Environment variables for this profile's Claude (applied when it starts).</summary>
    public Dictionary<string, string> Environment { get; set; } = [];
    /// <summary>Extra command-line flags for this profile's Claude (applied when it starts).</summary>
    public List<string> Arguments { get; set; } = [];

    /// <summary>What the badge shows: the custom badge, else the name's first letter.</summary>
    [JsonIgnore]
    public string BadgeText
    {
        get
        {
            var custom = Badge?.Trim();
            if (!string.IsNullOrEmpty(custom))
            {
                var e = System.Globalization.StringInfo.GetTextElementEnumerator(custom);
                var text = "";
                for (var i = 0; i < 2 && e.MoveNext(); i++) text += e.GetTextElement();
                return text;
            }
            var name = Name.Trim();
            return name.Length > 0 ? name[..1].ToUpperInvariant() : "?";
        }
    }

    public static readonly string[] Palette = ["#D97757", "#0A84FF", "#AF52DE", "#30A14E", "#E5487D", "#0FA3B1", "#5E5CE6", "#B07D48"];

    /// <summary>The badge colour: the chosen one, else a stable pick from the palette.</summary>
    [JsonIgnore]
    public string ResolvedColorHex
    {
        get
        {
            if (ColorHex is { } hex && IsValidColor(hex)) return (hex.StartsWith('#') ? hex : "#" + hex).ToUpperInvariant();
            var hash = Id.ToString("D").ToUpperInvariant().Aggregate(0, (h, c) => (h * 31 + c) & 0xFFFF);
            return Palette[hash % Palette.Length];
        }
    }

    public static bool IsValidColor(string hex)
    {
        var body = hex.StartsWith('#') ? hex[1..] : hex;
        return body.Length == 6 && body.All(Uri.IsHexDigit);
    }

    /// <summary>Up to two letters for the avatar: "Work Account" → "WA".</summary>
    [JsonIgnore]
    public string Initials
    {
        get
        {
            var words = Name.Split([' ', '-', '_', '.', '@'], StringSplitOptions.RemoveEmptyEntries);
            if (words.Length >= 2) return $"{words[0][0]}{words[1][0]}".ToUpperInvariant();
            var trimmed = Name.Trim();
            return (trimmed.Length > 2 ? trimmed[..2] : trimmed).ToUpperInvariant();
        }
    }
}

/// <summary>What Clatch persists in accounts.json.</summary>
public sealed class AccountsState
{
    public int Version { get; set; } = 1;
    public List<Account> Accounts { get; set; } = [];
    /// <summary>The account whose data is in Claude's live folder right now.</summary>
    public Guid? ActiveId { get; set; }

    [JsonIgnore]
    public Account? Active => Accounts.FirstOrDefault(a => a.Id == ActiveId);

    /// <summary>The account after the active one, wrapping around (the shortcut's target).</summary>
    [JsonIgnore]
    public Account? Next
    {
        get
        {
            if (Accounts.Count < 2) return null;
            var index = Accounts.FindIndex(a => a.Id == ActiveId);
            return index < 0 ? Accounts[0] : Accounts[(index + 1) % Accounts.Count];
        }
    }
}

internal sealed record SwitchJournal(Guid From, Guid To, Account? NewAccount);

[JsonSourceGenerationOptions(WriteIndented = true, PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(AccountsState))]
[JsonSerializable(typeof(SwitchJournal))]
internal sealed partial class CoreJsonContext : JsonSerializerContext;
