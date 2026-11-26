#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# End-to-end tests of Clatch for Linux against a stand-in Claude Desktop
# (linux/tests/stand-in-claude.c, installed as /usr/lib/claude-desktop/claude-desktop).
# Needs a display and a session bus; CI runs it as:
#   xvfb-run -a dbus-run-session -- linux/tests/e2e.sh path/to/clatch
# Every part uses a fresh, throwaway home folder.
set -euo pipefail
CLATCH=$(realpath "$1")
CLAUDE=/usr/lib/claude-desktop/claude-desktop
[ -x "$CLAUDE" ] || { echo "install the stand-in at $CLAUDE first"; exit 1; }
WORK=$(mktemp -d)
export GDK_BACKEND=x11 GSK_RENDERER=cairo NO_AT_BRIDGE=1 GTK_A11Y=none
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME

fail() { echo "FAIL: $*"; echo "---- clatch log"; cat "$HOME/.local/state/Clatch/clatch.log" 2>/dev/null || true; exit 1; }
wait_for() { # wait_for "<description>" <command...>
    local what=$1; shift
    for _ in $(seq 1 120); do "$@" >/dev/null && return 0; sleep 0.25; done
    fail "timed out waiting for $what"
}
lock_pid() { local l; l=$(readlink "$1/SingletonLock" 2>/dev/null) || return 1; echo "${l##*-}"; }
# Running, and not a zombie (re-parented processes may wait to be reaped in containers).
alive() { [ -r "/proc/$1/stat" ] && ! sed 's/.*) //' "/proc/$1/stat" | grep -q '^[ZX]'; }
export -f alive
mains() { pgrep -f "^$CLAUDE( |$)" | while read -r p; do grep -qa -- "--type=" /proc/$p/cmdline || echo "$p"; done; }

gone() { ! pgrep -f "$1" >/dev/null; }
new_home() {
    # The previous part's Clatch and Claudes must be gone: Clatch is single-instance
    # per D-Bus session, so a leftover would receive this part's commands.
    pkill -f "^$CLATCH" 2>/dev/null || true
    pkill -f "^$CLAUDE" 2>/dev/null || true
    for _ in $(seq 1 40); do gone "^$CLATCH" && gone "^$CLAUDE" && break; sleep 0.25; done
    gone "^$CLATCH" || pkill -KILL -f "^$CLATCH" || true
    sleep 0.5
    export HOME="$WORK/$1"
    export XDG_RUNTIME_DIR="$WORK/$1-run"
    mkdir -p "$HOME/.config/Claude" "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
    echo '{}' > "$HOME/.config/Claude/config.json"
    echo '{}' > "$HOME/.config/Claude/Local State"
    printf alice > "$HOME/.config/Claude/Cookies"
}
start_claude() { setsid -f "$CLAUDE" "$@" </dev/null >/dev/null 2>&1; }
start_clatch() { setsid -f "$CLATCH" "$@" </dev/null >>"$WORK/clatch.out" 2>&1; }
parked() { grep -rlx --include=Cookies "$1" "$HOME/.config/Clatch/Accounts" >/dev/null 2>&1; }

# ---- 1. One at a time -----------------------------------------------------------------
new_home one
C="$HOME/.config/Claude"
start_claude
wait_for "the stand-in Claude" lock_pid "$C"
first=$(lock_pid "$C")

start_clatch --add-account Bob
wait_for "alice to be parked" parked alice
wait_for "the first Claude to close" bash -c "! alive $first"
wait_for "Claude to reopen for Bob" lock_pid "$C"
[ ! -e "$C/Cookies" ] || fail "Claude's folder should be fresh for the new account"
grep -q "marking readyForQuit" "$HOME/.config/Clatch/Accounts"/*/Claude/logs/main.log || fail "Claude was not asked politely"
echo "ok 1a: add account closed Claude politely, parked alice, reopened Claude"

# The tray icon, used the way a desktop's tray uses it: it offers no menu of its own
# (so desktops don't show a generic one), and a click opens Clatch's window.
bus=$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
      --method org.freedesktop.DBus.ListNames | grep -o "org.kde.StatusNotifierItem-[0-9]*-1" | head -1)
[ -n "$bus" ] || fail "no StatusNotifierItem on the bus"
menu=$(gdbus call --session --dest "$bus" --object-path /StatusNotifierItem \
       --method org.freedesktop.DBus.Properties.Get org.kde.StatusNotifierItem Menu)
grep -q "/NO_DBUSMENU" <<<"$menu" || fail "the tray item should offer no D-Bus menu, got $menu"
shown=$(grep -c "Window shown" "$HOME/.local/state/Clatch/clatch.log" || true)
gdbus call --session --dest "$bus" --object-path /StatusNotifierItem --method org.kde.StatusNotifierItem.Activate -- 0 0 >/dev/null
wait_for "a click on the tray icon to open Clatch" bash -c "[ \$(grep -c 'Window shown' '$HOME/.local/state/Clatch/clatch.log') -gt $shown ]"
echo "ok 1b: a click on the tray icon opens Clatch's window (no generic menu)"

printf bob > "$C/Cookies"
second=$(lock_pid "$C")
"$CLATCH" --switch-next
wait_for "alice to be live again" bash -c "[ \"\$(cat '$C/Cookies' 2>/dev/null)\" = alice ]"
wait_for "bob to be parked" parked bob
alive "$second" && fail "Bob's Claude should have been closed"
wait_for "Claude to reopen for alice" lock_pid "$C"
echo "ok 1c: switched back to alice, Bob parked, Claude reopened"

# Declined quit: Claude says no to the first request; nothing may move.
"$CLATCH" --quit; sleep 0.5
pkill -f "^$CLAUDE" || true; sleep 0.5
STAND_IN_DECLINE=1 start_claude
wait_for "the declining Claude" lock_pid "$C"
declining=$(lock_pid "$C")
start_clatch --switch-next
sleep 4
alive "$declining" || fail "a Claude that said no must stay open"
[ "$(cat "$C/Cookies")" = alice ] || fail "nothing may move while Claude says no"
echo "ok 1d: when Claude declines, it stays open and nothing moves"
"$CLATCH" --quit; sleep 0.5

# ---- 2. Side by side ------------------------------------------------------------------
new_home side
C="$HOME/.config/Claude"
mkdir -p "$HOME/.config/Clatch"
echo '{"sideBySide": true, "profileShortcuts": true}' > "$HOME/.config/Clatch/settings.json"
start_claude
wait_for "the stand-in Claude" lock_pid "$C"
first=$(lock_pid "$C")

start_clatch --add-account Bob
# Anchored to Claude's path: an unanchored pattern would match this check's own command line.
wait_for "Bob's own Claude" pgrep -f -- "^$CLAUDE --user-data-dir=$HOME/.config/Clatch/Accounts/"
alive "$first" || fail "side by side must leave the first Claude open"
bob=$(python3 -c "import json,sys; d=json.load(open('$HOME/.config/Clatch/accounts.json')); print([a['id'] for a in d['accounts'] if a['name']=='Bob'][0])")
alice=$(python3 -c "import json,sys; d=json.load(open('$HOME/.config/Clatch/accounts.json')); print(d['activeID'])")
bobdir="$HOME/.config/Clatch/Accounts/$bob/Claude"
wait_for "Bob's lock" lock_pid "$bobdir"
launcher="$HOME/.local/share/applications/clatch-profile-${bob,,}.desktop"
wait_for "Bob's launcher" test -f "$launcher"
grep -q -- "--launch ${bob,,}" "$launcher" || fail "the launcher does not open Bob"
echo "ok 2a: Bob runs side by side on his own folder; his launcher exists"

"$CLATCH" --launch "$bob"
wait_for "the hand-over to Bob's Claude" test -s "$bobdir/handoff.log"
[ "$(mains | wc -l)" -eq 2 ] || fail "opening an open profile must not start another Claude"
echo "ok 2b: opening Bob again brings his Claude forward"

kill -TERM "$first"
wait_for "the first Claude to end" bash -c "! alive $first"
"$CLATCH" --launch "$alice"
wait_for "the first profile to start again" lock_pid "$C"
own=$(lock_pid "$C")
grep -qa -- "--user-data-dir" "/proc/$own/cmdline" && fail "the active profile must run on Claude's own folder"
echo "ok 2c: the first profile started again on Claude's own folder"

"$CLATCH" --quit; sleep 0.5

# ---- 3. Sign-in routing (needs Clatch's desktop entry: the installed package) ----------
if [ -f /usr/share/applications/com.issensoftware.Clatch.desktop ]; then
    new_home routing
    C="$HOME/.config/Claude"
    # Claude's own desktop entry (the stand-in has none of its own), as the real package installs it.
    mkdir -p "$HOME/.local/share/applications"
    printf '[Desktop Entry]\nType=Application\nName=Claude\nExec=%s %%U\nMimeType=x-scheme-handler/claude;\n' "$CLAUDE" \
        > "$HOME/.local/share/applications/com.anthropic.Claude.desktop"
    gio mime x-scheme-handler/claude com.anthropic.Claude.desktop >/dev/null
    mkdir -p "$HOME/.config/Clatch"
    echo '{"sideBySide": true, "routeSignIns": true}' > "$HOME/.config/Clatch/settings.json"
    start_claude
    wait_for "the stand-in Claude" lock_pid "$C"
    handler() { gio mime x-scheme-handler/claude | head -1 | grep -q "$1"; }
    start_clatch --background
    wait_for "Clatch to take claude:// links" handler com.issensoftware.Clatch.desktop
    echo "ok 3a: with routing on, Clatch handles claude:// links"

    # Claude makes itself the handler again whenever it starts; Clatch takes it back.
    gio mime x-scheme-handler/claude com.anthropic.Claude.desktop >/dev/null
    wait_for "Clatch to take the handler back" handler com.issensoftware.Clatch.desktop
    echo "ok 3b: Clatch takes the handler back after Claude re-registers"

    "$CLATCH" --add-account Bob
    bob=$(python3 -c "import json; d=json.load(open('$HOME/.config/Clatch/accounts.json')); print([a['id'] for a in d['accounts'] if a['name']=='Bob'][0])")
    bobdir="$HOME/.config/Clatch/Accounts/$bob/Claude"
    wait_for "Bob's Claude" lock_pid "$bobdir"
    "$CLATCH" "claude://claude.ai/login/callback?code=test-code"
    wait_for "the sign-in to reach Bob" grep -q "claude://claude.ai/login/callback" "$bobdir/handoff.log"
    [ ! -s "$C/handoff.log" ] || fail "the sign-in went to the wrong profile"
    grep -q "test-code" "$HOME/.local/state/Clatch/clatch.log" && fail "a sign-in code was written to the log"
    echo "ok 3c: a sign-in reaches the profile that is waiting for one (and is not logged)"

    "$CLATCH" --quit; sleep 0.5
    # Off again (as Settings does): Claude gets its handler back at the next start.
    echo '{"sideBySide": true, "routeSignIns": false}' > "$HOME/.config/Clatch/settings.json"
    start_clatch --background
    wait_for "Claude to get claude:// links back" handler com.anthropic.Claude.desktop
    echo "ok 3d: with routing off, claude:// links go to Claude again"
    "$CLATCH" --quit; sleep 0.5
else
    echo "skip 3: sign-in routing needs the installed package (its desktop entry)"
fi

pkill -f "^$CLAUDE" || true
echo "all Linux end-to-end tests passed"
