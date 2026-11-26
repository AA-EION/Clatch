#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Screenshots of Clatch's window for CI artifacts (a throwaway home, a stand-in Claude).
#   xvfb-run -a dbus-run-session -- linux/tests/screenshots.sh path/to/clatch out-dir
set -uo pipefail
CLATCH=$(realpath "$1"); OUT=$(realpath -m "$2"); mkdir -p "$OUT"
CLAUDE=/usr/lib/claude-desktop/claude-desktop
export HOME=$(mktemp -d) XDG_RUNTIME_DIR=$(mktemp -d)
chmod 700 "$XDG_RUNTIME_DIR"
export GDK_BACKEND=x11 GSK_RENDERER=cairo NO_AT_BRIDGE=1 GTK_A11Y=none
mkdir -p "$HOME/.config/Claude" "$HOME/.config/Clatch"
echo '{}' > "$HOME/.config/Claude/config.json"; echo '{}' > "$HOME/.config/Claude/Local State"; echo x > "$HOME/.config/Claude/Cookies"
echo '{"sideBySide": true, "checkForUpdates": false}' > "$HOME/.config/Clatch/settings.json"
setsid -f "$CLAUDE" </dev/null >/dev/null 2>&1; sleep 0.5
setsid -f "$CLATCH" --background </dev/null >/dev/null 2>&1; sleep 2
"$CLATCH" --add-account "Work"; sleep 1; "$CLATCH" --add-account "Personal"; sleep 2
"$CLATCH"; sleep 2; import -window root "$OUT/window-profiles.png"
"$CLATCH" --settings; sleep 2; import -window root "$OUT/window-settings.png"
"$CLATCH" --switcher; sleep 1.5; import -window root "$OUT/switcher.png"
"$CLATCH" --quit; sleep 0.5
pkill -f "^$CLAUDE" || true
ls "$OUT"
