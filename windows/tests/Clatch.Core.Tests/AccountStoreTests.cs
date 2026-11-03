// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using System.Text.Json;
using Clatch.Core;

namespace Clatch.Core.Tests;

public sealed class AccountStoreTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "ClatchTests-" + Guid.NewGuid().ToString("N"));
    private readonly ClatchPaths paths;

    public AccountStoreTests()
    {
        Directory.CreateDirectory(root);
        paths = new ClatchPaths(Path.Combine(root, "Claude"), Path.Combine(root, "Clatch"));
    }

    public void Dispose()
    {
        try { Directory.Delete(root, recursive: true); } catch (IOException) { }
    }

    private void WriteLive(string marker, string? config = null)
    {
        Directory.CreateDirectory(paths.ClaudeData);
        File.WriteAllText(Path.Combine(paths.ClaudeData, "Cookies"), marker);
        if (config is not null) File.WriteAllText(Path.Combine(paths.ClaudeData, "claude_desktop_config.json"), config);
    }

    private string? LiveMarker()
    {
        var file = Path.Combine(paths.ClaudeData, "Cookies");
        return File.Exists(file) ? File.ReadAllText(file) : null;
    }

    private string? LiveConfig()
    {
        var file = Path.Combine(paths.ClaudeData, "claude_desktop_config.json");
        return File.Exists(file) ? File.ReadAllText(file) : null;
    }

    [Fact]
    public void FirstRunAdoptsCurrentSignIn()
    {
        WriteLive("alice");
        var store = new AccountStore(paths);
        Assert.Single(store.State.Accounts);
        Assert.Equal("Account 1", store.State.Active?.Name);
        Assert.Equal("alice", LiveMarker());
    }

    [Fact]
    public void AddAccountParksDataAndLeavesClaudeEmpty()
    {
        WriteLive("alice");
        var store = new AccountStore(paths, []);
        var alice = store.State.ActiveId!.Value;
        var bob = store.AddAccount("Bob");
        Assert.Equal(bob.Id, store.State.ActiveId);
        Assert.False(Directory.Exists(paths.ClaudeData));
        Assert.Equal("alice", File.ReadAllText(Path.Combine(paths.Stash(alice), "Cookies")));
        Assert.False(store.HasInterruptedSwitch);
    }

    [Fact]
    public void SwitchBackAndForthKeepsData()
    {
        WriteLive("alice");
        var store = new AccountStore(paths, []);
        var alice = store.State.ActiveId!.Value;
        var bob = store.AddAccount("Bob");
        WriteLive("bob");
        store.SwitchTo(alice);
        Assert.Equal("alice", LiveMarker());
        store.SwitchTo(bob.Id);
        Assert.Equal("bob", LiveMarker());
        var reloaded = new AccountStore(paths, []);
        Assert.Equal(bob.Id, reloaded.State.ActiveId);
        Assert.Equal(["Account 1", "Bob"], reloaded.State.Accounts.Select(a => a.Name));
    }

    [Fact]
    public void SharedSettingsFollowTheUser()
    {
        WriteLive("alice", "{\"a\":1}");
        var store = new AccountStore(paths);
        var alice = store.State.ActiveId!.Value;
        store.AddAccount("Bob");
        Assert.Equal("{\"a\":1}", LiveConfig());
        WriteLive("bob", "{\"b\":2}");
        store.SwitchTo(alice);
        Assert.Equal("alice", LiveMarker());
        Assert.Equal("{\"b\":2}", LiveConfig());
    }

    [Fact]
    public void RecoveryFinishesInterruptedSwitch()
    {
        WriteLive("alice");
        var store = new AccountStore(paths, []);
        var alice = store.State.ActiveId!.Value;
        var bob = store.AddAccount("Bob");
        WriteLive("bob");
        // Crash after the journal was written and Bob was parked.
        File.WriteAllText(paths.JournalFile, JsonSerializer.Serialize(new SwitchJournal(bob.Id, alice, null), CoreJsonContext.Default.SwitchJournal));
        Directory.CreateDirectory(Path.GetDirectoryName(paths.Stash(bob.Id))!);
        Directory.Move(paths.ClaudeData, paths.Stash(bob.Id));

        var restarted = new AccountStore(paths, []);
        Assert.True(restarted.HasInterruptedSwitch);
        restarted.RecoverInterruptedSwitch();
        Assert.False(restarted.HasInterruptedSwitch);
        Assert.Equal("alice", LiveMarker());
        Assert.Equal(alice, restarted.State.ActiveId);
    }

    [Fact]
    public void RefusesToOverwriteUnexpectedData()
    {
        WriteLive("alice");
        var store = new AccountStore(paths, []);
        Directory.CreateDirectory(paths.Stash(store.State.ActiveId!.Value));
        Assert.Throws<AccountStoreException>(() => store.AddAccount("Bob"));
        Assert.Equal("alice", LiveMarker());
        Assert.Single(store.State.Accounts);
    }

    [Fact]
    public void FailedFirstMoveLeavesNoJournal()
    {
        WriteLive("alice");
        var store = new AccountStore(paths, []);
        Directory.CreateDirectory(paths.ClatchRoot);
        File.WriteAllText(paths.AccountsFolder, "a file where the Accounts folder should be");
        Assert.ThrowsAny<Exception>(() => store.AddAccount("Bob"));
        Assert.False(store.HasInterruptedSwitch);
        Assert.Equal("alice", LiveMarker());
    }

    [Fact]
    public void CannotRemoveActiveAccount()
    {
        var store = new AccountStore(paths, []);
        Assert.Throws<AccountStoreException>(() => store.Remove(store.State.ActiveId!.Value));
    }

    [Fact]
    public void NextWrapsAround()
    {
        Account a = new() { Name = "A" }, b = new() { Name = "B" }, c = new() { Name = "C" };
        var state = new AccountsState { Accounts = [a, b, c], ActiveId = c.Id };
        Assert.Equal(a.Id, state.Next?.Id);
        state.ActiveId = a.Id;
        Assert.Equal(b.Id, state.Next?.Id);
        Assert.Null(new AccountsState { Accounts = [a], ActiveId = a.Id }.Next);
    }

    [Fact]
    public void Initials()
    {
        Assert.Equal("WA", new Account { Name = "Work Account" }.Initials);
        Assert.Equal("JE", new Account { Name = "jane@example.com" }.Initials);
        Assert.Equal("PE", new Account { Name = "personal" }.Initials);
    }

    [Fact]
    public void DefaultShortcut()
    {
        Assert.Equal("Ctrl+Alt+Win+C", KeyCombo.Default.DisplayString);
        Assert.True(KeyCombo.Default.IsAcceptable);
        Assert.False(new KeyCombo(KeyCombo.Shift, 0x43, "C").IsAcceptable);
        Assert.True(new KeyCombo(0, 0x74, "F5").IsAcceptable);
    }

    // ---- Fail-safe -----------------------------------------------------------

    [Fact]
    public void LayoutCheckAcceptsNormalFolder()
    {
        WriteLive("alice");
        File.WriteAllText(Path.Combine(paths.ClaudeData, "Local State"), "{}");
        File.WriteAllText(Path.Combine(paths.ClaudeData, "config.json"), "{}");
        Assert.True(DataLayoutCheck.Inspect(paths.ClaudeData, true).IsRecognized);
    }

    [Fact]
    public void LayoutCheckFlagsMissingFolderOnlyAfterClaudeRan()
    {
        Assert.False(DataLayoutCheck.Inspect(paths.ClaudeData, true).IsRecognized);
        Assert.True(DataLayoutCheck.Inspect(paths.ClaudeData, false).IsRecognized);
    }

    [Fact]
    public void LayoutCheckFlagsUnknownContentsAndPointsToAlternatives()
    {
        Directory.CreateDirectory(paths.ClaudeData);
        File.WriteAllText(Path.Combine(paths.ClaudeData, "something-new.db"), "x");
        var elsewhere = Path.Combine(root, "Claude-3p");
        Directory.CreateDirectory(elsewhere);
        var check = DataLayoutCheck.Inspect(paths.ClaudeData, true, [elsewhere, Path.Combine(root, "Nope")]);
        Assert.Equal(3, check.Problems.Count);
        Assert.Contains("Claude-3p", check.Problems[^1]);
    }

    [Fact]
    public void LayoutCheckAcceptsFolderWithOnlySharedSettings()
    {
        Directory.CreateDirectory(paths.ClaudeData);
        File.WriteAllText(Path.Combine(paths.ClaudeData, "claude_desktop_config.json"), "{}");
        Assert.True(DataLayoutCheck.Inspect(paths.ClaudeData, false).IsRecognized);
    }
}
