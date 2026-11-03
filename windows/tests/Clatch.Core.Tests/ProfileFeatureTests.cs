// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

using System.Text.Json;
using Clatch.Core;

namespace Clatch.Core.Tests;

public sealed class ProfileFeatureTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "ClatchProfiles-" + Guid.NewGuid().ToString("N"));

    public ProfileFeatureTests() => Directory.CreateDirectory(root);

    public void Dispose()
    {
        try { Directory.Delete(root, recursive: true); } catch (IOException) { }
    }

    private ClatchPaths Paths(bool profileRoot = true) =>
        new(Path.Combine(root, "Claude-Data", "claude_x"), Path.Combine(root, "Clatch"), null,
            profileRoot ? root : null);

    [Fact]
    public void OldAccountsFilesStillLoad()
    {
        var paths = Paths();
        Directory.CreateDirectory(paths.ClatchRoot);
        File.WriteAllText(paths.StateFile, """{"version":1,"accounts":[{"id":"6e1b3c2a-9f4d-4a51-8c0b-3d2e7a9f1c55","name":"Work"}],"activeId":"6e1b3c2a-9f4d-4a51-8c0b-3d2e7a9f1c55"}""");
        var store = new AccountStore(paths, []);
        Assert.Equal("Work", store.State.Active?.Name);
        Assert.Empty(store.State.Active!.Environment);
        Assert.Empty(store.State.Active!.Arguments);
    }

    [Fact]
    public void BadgeAndColour()
    {
        var account = new Account { Name = "personal" };
        Assert.Equal("P", account.BadgeText);
        account.Badge = "🚀";
        Assert.Equal("🚀", account.BadgeText);
        Assert.Contains(account.ResolvedColorHex, Account.Palette);
        account.ColorHex = "#123abc";
        Assert.Equal("#123ABC", account.ResolvedColorHex);
    }

    [Fact]
    public void ProfilesLiveDirectlyUnderTheProfileRoot()
    {
        var paths = Paths();
        var id = Guid.NewGuid();
        Assert.Equal(root, Path.GetDirectoryName(paths.Stash(id)));
        Assert.StartsWith("Clatch-", Path.GetFileName(paths.Stash(id)));
        Assert.Equal(paths.Stash(id) + "-Claude-AppData", paths.Stash(id, "Claude-AppData"));
    }

    [Fact]
    public void LegacyProfilesAreMigrated()
    {
        var legacyPaths = Paths(profileRoot: false);
        Directory.CreateDirectory(legacyPaths.ClaudeData);
        var legacy = new AccountStore(legacyPaths, []);
        var main = legacy.State.ActiveId!.Value;
        var work = legacy.CreateProfile("Work");
        File.WriteAllText(Path.Combine(legacyPaths.Stash(work.Id), "Cookies"), "work");

        var store = new AccountStore(Paths(), []);
        var moved = store.MigrateLegacyProfiles();
        Assert.Single(moved);
        Assert.Equal("work", File.ReadAllText(Path.Combine(Paths().Stash(work.Id), "Cookies")));
        Assert.False(Directory.Exists(legacyPaths.Stash(work.Id)));
        Assert.Equal(main, store.State.ActiveId);
        Assert.Empty(store.MigrateLegacyProfiles());
    }

    [Fact]
    public void SideBySideProfilesNeedNoMoves()
    {
        var paths = Paths();
        var store = new AccountStore(paths, []);
        var main = store.State.ActiveId!.Value;
        var work = store.CreateProfile("Work");
        Assert.Equal(main, store.State.ActiveId);
        Assert.Equal(paths.ClaudeData, store.DataFolder(main));
        Assert.Equal(paths.Stash(work.Id), store.DataFolder(work.Id));
        Assert.True(Directory.Exists(paths.Stash(work.Id)));
        Directory.CreateDirectory(paths.ClaudeData);
        store.SwitchTo(work.Id); // the same profile also works one at a time
        Assert.Equal(work.Id, store.State.ActiveId);
        Assert.True(Directory.Exists(paths.ClaudeData));
    }

    [Fact]
    public void EditingAProfile()
    {
        var paths = Paths();
        var store = new AccountStore(paths, []);
        var account = store.State.Active! with { Name = "  Work  ", Environment = new() { ["HTTPS_PROXY"] = "http://p:1" }, Arguments = ["--lang=es"] };
        store.Update(account);
        var reloaded = new AccountStore(paths, []);
        Assert.Equal("Work", reloaded.State.Active?.Name);
        Assert.Equal("http://p:1", reloaded.State.Active?.Environment["HTTPS_PROXY"]);
        Assert.Equal(["--lang=es"], reloaded.State.Active!.Arguments);
    }

    [Fact]
    public void ArgumentsAndEnvironment()
    {
        var parsed = LaunchOptions.ParseArguments("""--lang=es --proxy-server="http://a b:80" -v""");
        Assert.Equal(["--lang=es", "--proxy-server=http://a b:80", "-v"], parsed);
        Assert.Equal(parsed, LaunchOptions.ParseArguments(LaunchOptions.FormatArguments(parsed)));
        Assert.NotEmpty(LaunchOptions.Problems(["--user-data-dir=C:\\x"]));
        var env = LaunchOptions.ParseEnvironment("# proxy\r\nHTTPS_PROXY=http://p:1\r\nBAD-NAME=x\r\nNOEQUALS\r\nEMPTY=");
        Assert.Equal(2, env.Values.Count);
        Assert.Equal(2, env.Problems.Count);
        Assert.Equal("\"C:\\Program Files\\x\\\\\"", LaunchOptions.QuoteForCommandLine("C:\\Program Files\\x\\"));
        Assert.Equal("plain", LaunchOptions.QuoteForCommandLine("plain"));
    }

    [Fact]
    public void LinksAndVersions()
    {
        Assert.True(ClaudeLink.IsSignIn("claude://login/abc"));
        Assert.True(ClaudeLink.IsSignIn("claude://claude.ai/sso-callback?code=1"));
        Assert.False(ClaudeLink.IsSignIn("claude://claude.ai/sso-callbackX"));
        Assert.DoesNotContain("SECRET", ClaudeLink.Describe("claude://claude.ai/sso-callback?code=SECRET"));
        Assert.False(ClaudeLink.IsClaudeLink("https://claude.ai"));

        AppVersion V(string s) => AppVersion.Parse(s)!;
        Assert.True(V("0.1.0-beta.1").CompareTo(V("0.1.0-beta.2")) < 0);
        Assert.True(V("0.1.0-beta.2").CompareTo(V("0.1.0")) < 0);
        Assert.True(V("0.9").CompareTo(V("v0.10.0")) < 0);
        Assert.Equal(0, V("1.0").CompareTo(V("1.0.0")));
        Assert.Null(AppVersion.Parse("latest"));
    }

    private static void WriteSession(string profile, string account, string org, string id, string json)
    {
        var folder = Path.Combine(profile, "claude-code-sessions", account, org);
        Directory.CreateDirectory(folder);
        File.WriteAllText(Path.Combine(folder, $"local_{id}.json"), json);
    }

    [Fact]
    public void DiscoversAndCopiesCodeChats()
    {
        string source = Path.Combine(root, "A"), target = Path.Combine(root, "B");
        WriteSession(source, "acct-a", "org-a", "1111", """{"title":"Fix the build","cwd":"C:\\Users\\me\\clatch"}""");
        WriteSession(source, "acct-a", "org-a", "2222", """{"cwd":"C:\\x\\scratch-workspaces\\y"}""");
        var roots = new[] { Path.Combine(source, CodeSessions.FolderName) };
        var sessions = CodeSessions.Discover(roots);
        Assert.Equal(2, sessions.Count);
        var fix = sessions.Single(s => s.Title == "Fix the build");
        Assert.Equal("clatch", fix.Folder);
        Assert.Contains(sessions, s => s.Title == "Chat 2222" && s.Folder == "(no folder)");

        var targetRoots = new[] { Path.Combine(target, CodeSessions.FolderName) };
        var refused = Assert.Throws<CodeSessionException>(() => CodeSessions.Copy(fix, targetRoots, "B"));
        Assert.Contains("Open the Code tab once", refused.Message);
        Directory.CreateDirectory(Path.Combine(target, "claude-code-sessions", "acct-b", "org-b"));
        var copied = CodeSessions.Copy(fix, targetRoots, "B");
        Assert.Equal("org-b", Path.GetFileName(Path.GetDirectoryName(copied)));
        Assert.Equal(["Fix the build"], CodeSessions.Discover(targetRoots).Select(s => s.Title));
        Assert.Throws<CodeSessionException>(() => CodeSessions.Copy(fix, targetRoots, "B"));
    }
}

public sealed class SignInBackupTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "ClatchBackup-" + Guid.NewGuid().ToString("N"));

    public SignInBackupTests() => Directory.CreateDirectory(root);

    public void Dispose()
    {
        try { Directory.Delete(root, recursive: true); } catch (IOException) { }
    }

    [Fact]
    public void BacksUpOnlyTheSignInAndRestoresIt()
    {
        var profile = Path.Combine(root, "Profile");
        Directory.CreateDirectory(Path.Combine(profile, "Network"));
        Directory.CreateDirectory(Path.Combine(profile, "Cache"));
        Directory.CreateDirectory(Path.Combine(profile, "Local Storage", "leveldb"));
        File.WriteAllText(Path.Combine(profile, "Network", "Cookies"), "cookies");
        File.WriteAllText(Path.Combine(profile, "Local Storage", "leveldb", "000003.log"), "ls");
        File.WriteAllText(Path.Combine(profile, "Cache", "data"), "big");
        var id = Guid.NewGuid();
        var backups = Path.Combine(root, "Backups");

        var snapshot = SignInBackup.BackUp(new Dictionary<Guid, string> { [id] = profile, [Guid.NewGuid()] = Path.Combine(root, "never") }, backups, "test");
        Assert.NotNull(snapshot);
        Assert.Equal([id], snapshot!.Profiles);
        Assert.False(Directory.Exists(Path.Combine(snapshot.Folder, id.ToString("D"), "Cache")));

        File.WriteAllText(Path.Combine(profile, "Network", "Cookies"), "lost");
        SignInBackup.Restore(id, snapshot, profile);
        Assert.Equal("cookies", File.ReadAllText(Path.Combine(profile, "Network", "Cookies")));
        Assert.Equal("ls", File.ReadAllText(Path.Combine(profile, "Local Storage", "leveldb", "000003.log")));
        Assert.Single(SignInBackup.List(backups));
    }

    [Fact]
    public void KeepsTheNewestThree()
    {
        var profile = Path.Combine(root, "P");
        Directory.CreateDirectory(profile);
        File.WriteAllText(Path.Combine(profile, "config.json"), "{}");
        var backups = Path.Combine(root, "Backups");
        for (var i = 0; i < 5; i++)
        {
            SignInBackup.BackUp(new Dictionary<Guid, string> { [Guid.NewGuid()] = profile }, backups, $"n{i}");
            Thread.Sleep(20);
        }
        Assert.Equal(SignInBackup.Kept, SignInBackup.List(backups).Count);
    }
}
