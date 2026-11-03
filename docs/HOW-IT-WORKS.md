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
- No timers, no network, no file watching at rest.

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
| `~/Library/Application Support/Claude` | `%APPDATA%\Claude` (classic installer) or `%LOCALAPPDATA%\Packages\<Claude package>\LocalCache\Roaming\Claude` (MSIX; Windows redirects the packaged app's AppData there) |
| Encryption key in the Keychain ("Claude Safe Storage") | Key in `Local State` inside the data folder, protected with DPAPI for the Windows user, so each saved account is self-contained |
| Quit Apple Event (`NSRunningApplication.terminate`) | Restart Manager (`RmShutdown` without force): Claude gets the messages it gets when Windows shuts down and may refuse. If it doesn't close, the user quits it from its notification area icon and Clatch carries on |
| `proc_listallpids` / `proc_pidpath` | Toolhelp snapshot + `QueryFullProcessImageName`; Claude's main process is the `claude.exe` whose parent isn't `claude.exe` |
| `rename(2)` works with open files | Directory moves **fail** while any file is open, so Clatch always waits for every process; a failed move changes nothing |
| `NSStatusItem` + `NSPopover` | `Shell_NotifyIcon` on a message-only window + a borderless WinUI 3 window with Acrylic, closed when it loses focus, hidden from the taskbar and Alt+Tab |
| Carbon `RegisterEventHotKey` | `RegisterHotKey` (same window, no permissions) |
| `SMAppService` login item | Per-user `Run` registry value |

Clatch for Windows is **unpackaged** on purpose: an MSIX-packaged Clatch would have its own AppData
writes redirected too, and could not move Claude's real data folder. It's self-contained and
compiled with NativeAOT, so it needs no .NET or Windows App SDK runtime on the PC.
