// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using System.Text.Json;

namespace Clatch.Core;

public sealed class AccountStoreException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>
/// Keeps the account list and moves Claude's data folder between accounts.
/// Only call the switching methods while Claude Desktop is not running.
/// </summary>
/// <remarks>
/// Switching is two directory renames on the same drive: instant and
/// all-or-nothing whatever the size. On Windows a rename fails while any file
/// inside is open, which is the safe outcome: nothing moves and the switch
/// can be retried. Every switch is journaled first; an interrupted one is
/// finished by <see cref="RecoverInterruptedSwitch"/>.
/// </remarks>
public sealed class AccountStore
{
    public static readonly IReadOnlyList<string> DefaultSharedItems = ["claude_desktop_config.json"];

    public ClatchPaths Paths { get; }
    /// <summary>Files that follow the user to every account (MCP and tool settings).</summary>
    public IReadOnlyList<string> SharedItems { get; set; }
    public AccountsState State { get; private set; } = new();

    public AccountStore(ClatchPaths paths, IReadOnlyList<string>? sharedItems = null)
    {
        Paths = paths;
        SharedItems = sharedItems ?? DefaultSharedItems;
        Load();
    }

    // ---- Persistence --------------------------------------------------------

    /// <summary>Reads accounts.json; the first time, the signed-in account becomes "Account 1".</summary>
    public void Load()
    {
        try
        {
            if (File.Exists(Paths.StateFile))
            {
                var state = JsonSerializer.Deserialize(File.ReadAllText(Paths.StateFile), CoreJsonContext.Default.AccountsState);
                if (state is { Accounts.Count: > 0 })
                {
                    State = state;
                    if (State.Active is null) State.ActiveId = State.Accounts[0].Id;
                    return;
                }
            }
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException)
        {
            // Unreadable state: start over below, data folders are untouched.
        }
        var first = new Account { Name = "Account 1", LastUsedAt = DateTimeOffset.Now };
        State = new AccountsState { Accounts = [first], ActiveId = first.Id };
        try { Save(); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    public void Save()
    {
        Directory.CreateDirectory(Paths.ClatchRoot);
        var temp = Paths.StateFile + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(State, CoreJsonContext.Default.AccountsState));
        File.Move(temp, Paths.StateFile, overwrite: true);
    }

    // ---- Editing ------------------------------------------------------------

    public void Rename(Guid id, string name)
    {
        var trimmed = name.Trim();
        var account = State.Accounts.FirstOrDefault(a => a.Id == id);
        if (trimmed.Length == 0 || account is null) return;
        account.Name = trimmed;
        Save();
    }

    public void Move(Guid id, int offset)
    {
        var index = State.Accounts.FindIndex(a => a.Id == id);
        var target = index + offset;
        if (index < 0 || target < 0 || target >= State.Accounts.Count) return;
        (State.Accounts[index], State.Accounts[target]) = (State.Accounts[target], State.Accounts[index]);
        Save();
    }

    /// <summary>Removes an inactive account. Its folder goes to <paramref name="deleteFolder"/>
    /// (the app sends it to the Recycle Bin).</summary>
    public void Remove(Guid id, Action<string>? deleteFolder = null)
    {
        if (id == State.ActiveId) throw new AccountStoreException("Switch to another account before removing this one.");
        var account = State.Accounts.FirstOrDefault(a => a.Id == id)
            ?? throw new AccountStoreException("That account no longer exists.");
        var folders = Paths.Folders.Select(f => Paths.Stash(id, f.Key))
            .Append(Path.Combine(Paths.AccountsFolder, id.ToString("D")))
            .Where(Directory.Exists).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        foreach (var folder in folders)
        {
            if (deleteFolder is not null) deleteFolder(folder); else Directory.Delete(folder, recursive: true);
        }
        State.Accounts.Remove(account);
        Save();
    }

    /// <summary>Saves edits to a profile (name, badge, colour, environment, flags).</summary>
    public void Update(Account account)
    {
        var index = State.Accounts.FindIndex(a => a.Id == account.Id);
        if (index < 0) throw new AccountStoreException("That account no longer exists.");
        var name = account.Name.Trim();
        account.Name = name.Length == 0 ? State.Accounts[index].Name : name;
        State.Accounts[index] = account;
        Save();
    }

    /// <summary>Where a profile's Claude data lives now: Claude's own folder for the
    /// active profile, its own folder for every other one (what it runs from side by side).</summary>
    public string DataFolder(Guid id) => id == State.ActiveId ? Paths.ClaudeData : Paths.Stash(id);

    /// <summary>Side by side: a new profile is a new, empty folder Claude fills when it starts there.</summary>
    public Account CreateProfile(string name)
    {
        var trimmed = name.Trim();
        var account = new Account { Name = trimmed.Length == 0 ? SuggestedNewName() : trimmed, LastUsedAt = DateTimeOffset.Now };
        Directory.CreateDirectory(Paths.Stash(account.Id));
        State.Accounts.Add(account);
        Save();
        return account;
    }

    public void MarkUsed(Guid id)
    {
        if (State.Accounts.FirstOrDefault(a => a.Id == id) is not { } account) return;
        account.LastUsedAt = DateTimeOffset.Now;
        try { Save(); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    /// <summary>
    /// Moves profiles saved in the older layout (Accounts\&lt;id&gt;\Claude) to where
    /// <see cref="ClatchPaths.Stash(Guid, string)"/> now puts them. Same drive, so
    /// each move is a rename that happens whole or not at all; a folder that is
    /// in use stays put and is moved on a later start. Returns what moved.
    /// </summary>
    public List<string> MigrateLegacyProfiles()
    {
        var moved = new List<string>();
        if (Paths.ProfileRoot is null) return moved;
        foreach (var account in State.Accounts.Where(a => a.Id != State.ActiveId))
        {
            foreach (var folder in Paths.Folders)
            {
                var legacy = Paths.LegacyStash(account.Id, folder.Key);
                var target = Paths.Stash(account.Id, folder.Key);
                if (!Directory.Exists(legacy) || Exists(target)) continue;
                try
                {
                    Directory.Move(legacy, target);
                    moved.Add($"{account.Name}: {folder.Key}");
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
            TryDeleteDirectory(Path.Combine(Paths.AccountsFolder, account.Id.ToString("D")));
        }
        return moved;
    }

    public string SuggestedNewName()
    {
        var names = State.Accounts.Select(a => a.Name).ToHashSet();
        var n = State.Accounts.Count + 1;
        while (names.Contains($"Account {n}")) n++;
        return $"Account {n}";
    }

    public bool HasStoredData(Guid id) =>
        id == State.ActiveId
            ? Paths.Folders.Any(f => Directory.Exists(f.Live))
            : Paths.Folders.Any(f => Directory.Exists(Paths.Stash(id, f.Key)));

    // ---- Switching ----------------------------------------------------------

    public void SwitchTo(Guid id)
    {
        if (State.Accounts.All(a => a.Id != id)) throw new AccountStoreException("That account no longer exists.");
        if (id == State.ActiveId) throw new AccountStoreException("That account is already active.");
        Perform(new SwitchJournal(ActiveIdOrAdopt(), id, null));
    }

    /// <summary>Parks the active account's data and leaves Claude's folder empty,
    /// so Claude starts fresh and asks for a sign-in.</summary>
    public Account AddAccount(string name)
    {
        var trimmed = name.Trim();
        var account = new Account { Name = trimmed.Length == 0 ? SuggestedNewName() : trimmed };
        Perform(new SwitchJournal(ActiveIdOrAdopt(), account.Id, account));
        return account;
    }

    public bool HasInterruptedSwitch => File.Exists(Paths.JournalFile);

    public void RecoverInterruptedSwitch()
    {
        if (!File.Exists(Paths.JournalFile)) return;
        SwitchJournal? journal = null;
        try { journal = JsonSerializer.Deserialize(File.ReadAllText(Paths.JournalFile), CoreJsonContext.Default.SwitchJournal); }
        catch (JsonException) { }
        if (journal is null) { File.Delete(Paths.JournalFile); return; }
        Advance(journal);
    }

    private Guid ActiveIdOrAdopt()
    {
        if (State.ActiveId is { } id) return id;
        var adopted = new Account { Name = SuggestedNewName(), LastUsedAt = DateTimeOffset.Now };
        State.Accounts.Add(adopted);
        State.ActiveId = adopted.Id;
        Save();
        return adopted.Id;
    }

    private void Perform(SwitchJournal journal)
    {
        foreach (var folder in Paths.Folders)
        {
            var parked = Paths.Stash(journal.From, folder.Key);
            if (Exists(parked) && Exists(folder.Live))
                throw new AccountStoreException($"Clatch found unexpected data at {parked}. Move it away and try again.");
        }
        Directory.CreateDirectory(Paths.ClatchRoot);
        File.WriteAllText(Paths.JournalFile, JsonSerializer.Serialize(journal, CoreJsonContext.Default.SwitchJournal));
        string Snapshot() => string.Join("|", Paths.Folders.Select(f =>
            $"{Exists(f.Live)}{Exists(Paths.Stash(journal.From, f.Key))}{Exists(Paths.Stash(journal.To, f.Key))}"));
        var before = Snapshot();
        try
        {
            Advance(journal);
        }
        catch (Exception e)
        {
            // Nothing moved yet (typically: a file is still open): forget this switch.
            if (Snapshot() == before)
                TryDelete(Paths.JournalFile);
            if (e is IOException or UnauthorizedAccessException)
                throw new AccountStoreException(
                    "Claude's files are still in use, so nothing was moved. Make sure Claude is fully closed and try again.", e);
            throw;
        }
    }

    /// <summary>Idempotent: each step only does what is still missing.</summary>
    private void Advance(SwitchJournal journal)
    {
        // Every folder of the account, one after the other; each step only
        // does what is still missing, so a re-run after a crash is safe.
        foreach (var folder in Paths.Folders)
        {
            var live = folder.Live;
            var outgoing = Paths.Stash(journal.From, folder.Key);
            var incoming = Paths.Stash(journal.To, folder.Key);

            // 1. Park the outgoing account's folder.
            if (Exists(live) && !Exists(outgoing))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(outgoing)!);
                Directory.Move(live, outgoing);
            }

            // 2. Bring in the incoming account's folder (a new account has nothing to bring).
            if (!Exists(live) && Exists(incoming))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(live)!);
                Directory.Move(incoming, live);
            }

            // 3. Carry machine-wide settings over (MCP servers and other tools).
            if (Exists(outgoing))
            {
                foreach (var item in SharedItems)
                {
                    if (item.Length == 0 || item.Contains('/') || item.Contains('\\')) continue;
                    var source = Path.Combine(outgoing, item);
                    if (!File.Exists(source)) continue;
                    Directory.CreateDirectory(live);
                    File.Copy(source, Path.Combine(live, item), overwrite: true);
                }
            }
        }
        if (Paths.ProfileRoot is null) TryDeleteDirectory(Path.GetDirectoryName(Paths.Stash(journal.To))!);

        // 4. Record the result, then drop the journal.
        if (journal.NewAccount is { } added && State.Accounts.All(a => a.Id != added.Id))
            State.Accounts.Add(added);
        if (State.Accounts.FirstOrDefault(a => a.Id == journal.To) is { } target)
        {
            State.ActiveId = target.Id;
            target.LastUsedAt = DateTimeOffset.Now;
        }
        Save();
        TryDelete(Paths.JournalFile);
    }

    private static bool Exists(string path) => Directory.Exists(path) || File.Exists(path);

    private static void TryDelete(string file)
    {
        try { File.Delete(file); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private static void TryDeleteDirectory(string folder)
    {
        try { if (Directory.Exists(folder) && !Directory.EnumerateFileSystemEntries(folder).Any()) Directory.Delete(folder); }
        catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}
