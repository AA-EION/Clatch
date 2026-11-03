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
