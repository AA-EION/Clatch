# How Clatch works

## Where Claude Desktop keeps a sign-in

Claude Desktop for macOS (`/Applications/Claude.app`, bundle ID `com.anthropic.claudefordesktop`)
is an Electron app. Electron keeps all of an app's browser-like state in one *user data* folder,
which for Claude is:

```
~/Library/Application Support/Claude/
```

What matters there for the account:

| Item | What it is |
|---|---|
| `Cookies` | The claude.ai session cookies (values encrypted, see below). |
| `Local Storage/`, `Session Storage/`, `IndexedDB/` | The web app's local state and cached conversations. |
| `config.json` | App state. Holds `oauth:tokenCache` (access and refresh tokens), encrypted. |
| `claude_desktop_config.json` | MCP servers and other tool settings. Machine setup, not tied to an account. |
| Other caches, logs, local session and VM data | Created by Claude as needed. |

Encrypted values use Electron's `safeStorage`. Its key is one Keychain item in the login
keychain, **"Claude Safe Storage"**, created once per app on a Mac. The key belongs to the app,
not to the sign-in, so any copy of the folder made on this Mac decrypts with the same key. That
is why swapping the folder is enough to swap the account. Clatch never touches the Keychain and
never decrypts anything.

Claude Desktop keeps its window positions in `~/Library/Preferences/com.anthropic.claudefordesktop.plist`
and HTTP caches in `~/Library/Caches/com.anthropic.claudefordesktop`. Neither holds the sign-in,
so Clatch leaves them alone. The Claude Code CLI keeps its own sign-in (`~/.claude`, Keychain item
"Claude Code-credentials") and is not affected.

## Switching

```
                    ┌───────────────────────────── Clatch ─────────────────────────────┐
 click / ⌃⌥⌘C  ──▶  │ 1. ask Claude to quit   (Apple Event "quit", same as ⌘Q)         │
                    │ 2. wait: main app gone? then every process from Claude.app or    │
                    │    from Claude's data folder gone? (+0.6 s for disk flushes)     │
                    │ 3. journal → rename live → Accounts/<old>/Claude                 │
                    │            → rename Accounts/<new>/Claude → live                 │
                    │            → copy claude_desktop_config.json old → new           │
                    │ 4. reopen Claude                                                 │
                    └──────────────────────────────────────────────────────────────────┘
```

**Quitting gracefully.** Clatch calls `NSRunningApplication.terminate()`, which sends the
standard *quit* Apple Event, exactly like ⌘Q or **Quit** in the Dock. Claude runs its normal
quit path, so if a local session is running it asks the user to confirm. If the user cancels,
Claude keeps running and Clatch keeps waiting, offering **Ask Claude Again** and **Cancel**.
Clatch never force-quits anything.

**Waiting for "really closed".** The main process going away is not enough: Electron helpers and
local sessions can take a moment longer. Clatch lists the user's processes with
`proc_listallpids`/`proc_pidpath` and waits until none runs from inside `Claude.app` or from the
data folder. This polling (4 times a second) only exists during a switch.

**Moving, not copying.** Both moves are `rename(2)` on the same volume: atomic and instant,
whatever the size of the folder. Even if some straggler process still had a file open, a rename
doesn't break it; the process keeps writing into the renamed folder, which is the outgoing
account's own folder. That is why **Switch Anyway** is safe.

**Crash safety.** Before moving anything, Clatch writes `switch-journal.json` (from, to). Each
step checks the disk and only does what is still missing, so the switch can be re-run from any
point. If Clatch, Claude or the Mac stops halfway, Clatch finishes the switch the next time it
starts or its panel opens, as long as Claude is closed. Clatch refuses to switch if it finds data
it didn't put there, rather than overwrite it.

## Adding an account

Adding an account is a switch to an account that has no data yet: the current account's folder
is moved aside, and the live folder is left absent. Claude then starts as if freshly installed
and shows its sign-in screen. Whatever the user signs in to becomes the new account. With **Same
MCP & tool settings for every account** on, `claude_desktop_config.json` is copied in first, so
the new account starts with the same tools.

## Staying light

- Pure AppKit entry point (`NSApplication` + `NSStatusItem`), `LSUIElement` set: no Dock icon,
  no windows, no SwiftUI scene graph at rest.
- The panel is an `NSPopover` whose SwiftUI content is created when it opens and released when it
  closes. While closed, nothing is rendered or observed.
- The global shortcut uses Carbon's `RegisterEventHotKey`: the system delivers one event when it
  is pressed. There is no event tap, so no permission prompt and no CPU use.
- No timers and no file watching at rest. Running Claudes are followed with the system's own
  notifications (`NSWorkspace` launch/terminate/activate on macOS, process exit handles and
  `SetWinEventHook` window events on Windows), not by polling.
- The only network request is the optional update check: GitHub's releases API, at most once a
  day, when Clatch starts or its panel opens.

## Liquid Glass

On macOS 26 and later the popover itself is glass (system), and Clatch's rows, cards and buttons
use `glassEffect`, `GlassEffectContainer` and the `.glass`/`.glassProminent` button styles. Each
use is gated with `#available(macOS 26, *)` (and `#if compiler(>=6.2)`); macOS 11–15 get a
translucent fill with a hairline stroke over the popover's vibrant material instead.

## The fail-safe

Clatch depends on facts Anthropic doesn't promise to keep: where Claude's data folder is and
what's in it. So before every switch, after Claude has closed and before anything moves, Clatch
checks that:

- the data folder exists if Claude was just running (Claude creates it on first launch), and is a folder;
- it contains Chromium/Electron's own files (`Local State`, `Cookies` or `Network/Cookies`, `Preferences`);
- it contains Claude's own files (`config.json` or `claude_desktop_config.json`).

A folder that only holds the shared settings file belongs to an account that hasn't signed in
yet, and is fine. If any check fails, the switch stops before anything is moved. Clatch lists what
it found, plus any other folder where Claude may now keep its data (for example `Claude-3p`), and
offers **Cancel** (Claude is reopened as it was) or **Continue Anyway**. The same check runs on
macOS (`DataLayoutCheck.swift`) and Windows (`DataLayoutCheck.cs`).

Separately, if the first move of a switch fails (on Windows typically because a file is still in
use), nothing has changed, so the switch journal is dropped and the switch can simply be tried again.

## Windows

The Windows app (`windows/`) follows the same design:

| macOS | Windows |
|---|---|
| `~/Library/Application Support/Claude` | `%APPDATA%\Claude` (classic installer) or, for current Microsoft Store/MSIX versions, `%LOCALAPPDATA%\Claude-Data\<package family>` passed to Claude with `--user-data-dir` (older MSIX versions used `%LOCALAPPDATA%\Packages\<Claude package>\LocalCache\Roaming\Claude`). Clatch reads the folder from the running Claude's own command line when it can |
| Encryption key in the Keychain ("Claude Safe Storage") | Key in `Local State` inside the data folder, protected with DPAPI for the Windows user, so each saved account is self-contained |
| Quit Apple Event (`NSRunningApplication.terminate`) | Restart Manager (`RmShutdown` without force): Claude gets the messages it gets when Windows shuts down and may refuse. If it doesn't close, the user quits it from its notification area icon and Clatch carries on |
| `proc_listallpids` / `proc_pidpath` | Toolhelp snapshot + `QueryFullProcessImageName`; Claude's main process is the `claude.exe` whose parent isn't `claude.exe` |
| `rename(2)` works with open files | Directory moves **fail** while any file is open, so Clatch always waits for every process; a failed move changes nothing |
| `NSStatusItem` + `NSPopover` | `Shell_NotifyIcon` on a hidden top-level window + a borderless WinUI 3 window with Acrylic, closed when it loses focus, hidden from the taskbar and Alt+Tab |
| Carbon `RegisterEventHotKey` | `RegisterHotKey` (same window, no permissions) |
| `SMAppService` login item | Per-user `Run` registry value |

Clatch for Windows is **unpackaged** on purpose: an MSIX-packaged Clatch would have its own AppData
writes redirected too, and could not move Claude's real data folder. It's self-contained and
compiled with NativeAOT, so it needs no .NET or Windows App SDK runtime on the PC.

## Side by side

Claude Desktop is an Electron app, and Electron's single-instance lock belongs to the data folder:
a Claude started with a different `--user-data-dir` is a separate instance with its own sign-in.
Side by side builds on that and on the folders Clatch already has:

- The active profile's Claude runs on Claude's own folder; every other profile's Claude is started
  with `--user-data-dir=<that profile's folder>`. One at a time uses exactly the same folders, so
  changing modes never moves data or signs anyone out. Every mode change first copies each closed
  profile's sign-in files (cookies, local storage, `Local State`, preferences) into
  `Backups/<date>` in Clatch's folder; the newest three are kept.
- macOS starts each instance with `NSWorkspace.openApplication` and
  `createsNewApplicationInstance`; Windows starts Claude's executable (or the Store app's alias)
  with the flag. The profile's environment variables and extra flags are added at that point.
- Clatch tells which Claude belongs to which profile from each process's own arguments
  (`KERN_PROCARGS2` on macOS; `NtQueryInformationProcess` command line on Windows) and keeps that
  map current from launch/exit notifications. A Claude without `--user-data-dir` is the active
  profile's.
- Closing a profile asks only that Claude to quit (an Apple Event to that one process; Restart
  Manager for just its processes on Windows), so it may still ask you first. Turning side by side
  off does this for every profile except the active one, then switches the mode.

**Sign-in routing.** Signing in ends with the browser opening a `claude://` link. With routing on,
Clatch is the handler for that scheme (macOS: Clatch declares it and is made the default handler,
and Claude is made the default again when routing is turned off; Windows: the per-user
`HKCU\Software\Classes\claude` command, with Claude's own command kept and restored, and a
`RegNotifyChangeKeyValue` watch in case Claude registers itself again). A link goes to the profile
that is waiting to sign in (a profile added in the last 15 minutes), otherwise to the Claude used
most recently. It is delivered to that profile's Claude: on macOS as a "get URL" Apple Event sent to
that process (which needs the Automation permission once), on Windows by starting Claude with the
profile's `--user-data-dir` and the link, which Electron hands to the running instance. Link
contents are never logged.

**Watchdog.** When a profile's Claude ends without Clatch asking, Clatch notes Claude's installed
version and checks it every 3 seconds for up to 3 minutes. If the version changes (Claude updated
itself), the profile is reopened in the background.

**Taskbar identity (Windows).** Each profile's Claude window gets its own AppUserModelID, relaunch
command and badged icon (`SHGetPropertyStoreForWindow`), so Windows groups it separately and
"pin to taskbar" pins that profile. macOS draws one Dock icon per application bundle, which Clatch
can't change for Claude; the profile launchers serve that purpose in the Dock.

## The profile switcher

A non-activating panel (`NSPanel` with SwiftUI; `glassEffect` on macOS 26+, the HUD material
before) or a borderless, topmost WinUI window with an always-active Acrylic backdrop on Windows. It
never takes keyboard focus, so the keys stay with the shortcut. While it is open, and only then:

- the modifier keys' state is read about 60 times a second (`NSEvent.modifierFlags`,
  `GetAsyncKeyState`), and releasing them opens the highlighted profile;
- a few extra hot keys are registered (Shift+shortcut, ←, →, Esc, Return/Enter) the same way as
  the main shortcut, and removed again when it closes.

No event tap or keyboard hook is involved, so no permission is needed.

## Profile icons and shortcuts

The icon is the installed Claude's own icon (`NSWorkspace.icon(forFile:)`; `SHDefExtractIcon` on
Windows) with a round badge in the profile's colour drawn on its corner, rendered to PNG/ICNS/ICO
and cached by look.

- **macOS**: each launcher is a small app bundle in `~/Applications/Clatch Profiles` whose only job
  is `open -g clatch://launch/<profile id>`. Clatch handles its own `clatch://` scheme, so opening
  a launcher starts Clatch if needed and opens the profile. The bundles are ad-hoc signed and
  registered with Launch Services.
- **Windows**: `.lnk` files on the Desktop and in *Start menu › Programs › Clatch Profiles*,
  pointing at `Clatch.exe --launch <profile id>` with the profile's AppUserModelID. A second
  `Clatch.exe` hands its arguments to the running one (`WM_COPYDATA`) and exits.

Clatch keeps a record of the shortcuts it made, and only ever renames or removes those.

## Code-tab chats

Claude's **Code** tab keeps one small file per local chat in the data folder
(`claude-code-sessions/<account id>/<organisation id>/local_<id>.json`); the conversation itself
lives in Claude Code's own history, which every profile on the computer shares. **Move Code Chats**
copies that file into the other profile, under the account and organisation that profile used most
recently, so the chat shows up there and can carry on. The target profile must have opened the
Code tab once. Chats on claude.ai live on Anthropic's servers and are not touched.
