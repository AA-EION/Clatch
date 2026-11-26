#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds Clatch for Linux and packages it as a .deb for this machine's architecture.
#
#   linux/build-deb.sh <version> [output-dir]
#
# The Swift runtime and Foundation are linked statically, so the package needs
# only system libraries (GTK 4, libadwaita, libcurl), worked out by
# dpkg-shlibdeps. Build on the oldest supported system (Ubuntu 22.04: GTK 4.6,
# libadwaita 1.1, glibc 2.35) so the package installs on everything newer.
set -euo pipefail
VERSION=${1:?version, e.g. 0.1.0-beta.1}
OUT=$(realpath -m "${2:-dist}")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=$(dpkg --print-architecture)
# Debian versions order "~" before anything: 0.1.0~beta.1 < 0.1.0.
DEBVERSION=${VERSION/-/\~}
cd "$ROOT"

swift build -c release --product clatch --static-swift-stdlib
BIN=$(swift build -c release --product clatch --show-bin-path)/clatch

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/clatch_${DEBVERSION}_${ARCH}"
install -Dm755 "$BIN" "$PKG/usr/bin/clatch"
strip --strip-unneeded "$PKG/usr/bin/clatch"
install -Dm644 linux/package/com.issensoftware.Clatch.desktop "$PKG/usr/share/applications/com.issensoftware.Clatch.desktop"
install -Dm644 linux/package/com.issensoftware.Clatch.metainfo.xml "$PKG/usr/share/metainfo/com.issensoftware.Clatch.metainfo.xml"
install -Dm644 Resources/Icon/AppIcon.svg "$PKG/usr/share/icons/hicolor/scalable/apps/com.issensoftware.Clatch.svg"
install -Dm644 docs/assets/icon.png "$PKG/usr/share/icons/hicolor/512x512/apps/com.issensoftware.Clatch.png"
install -Dm644 linux/package/copyright "$PKG/usr/share/doc/clatch/copyright"
mkdir -p "$PKG/usr/share/clatch"
echo "$VERSION" > "$PKG/usr/share/clatch/version"

# Shared-library dependencies, as dpkg-shlibdeps finds them.
mkdir -p "$STAGE/debian"
printf 'Source: clatch\n\nPackage: clatch\nArchitecture: any\n' > "$STAGE/debian/control"
DEPENDS=$(cd "$STAGE" && dpkg-shlibdeps -O "$PKG/usr/bin/clatch" 2>/dev/null | sed -n 's/^shlibs:Depends=//p')
[ -n "$DEPENDS" ] || { echo "dpkg-shlibdeps found no dependencies"; exit 1; }

SIZE=$(du -sk "$PKG/usr" | cut -f1)
mkdir -p "$PKG/DEBIAN"
cat > "$PKG/DEBIAN/control" <<CONTROL
Package: clatch
Version: $DEBVERSION
Architecture: $ARCH
Maintainer: Issen Software Group
Installed-Size: $SIZE
Depends: $DEPENDS
Recommends: xdg-desktop-portal
Suggests: claude-desktop, gnome-shell-extension-appindicator
Section: utils
Priority: optional
Homepage: https://github.com/AA-EION/Clatch
Description: Switch Claude Desktop accounts without signing out
 Clatch keeps each of your Claude Desktop accounts signed in and switches
 between them from the notification area or with a keyboard shortcut: one
 account at a time, or each in its own Claude window side by side. It never
 reads, stores or sends credentials; it only moves Claude's own data folders.
CONTROL

# Refresh the desktop's caches after install and removal (triggers handle most desktops already).
for script in postinst postrm; do
cat > "$PKG/DEBIAN/$script" <<'SCRIPT'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database -q /usr/share/applications || true; fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true; fi
exit 0
SCRIPT
chmod 755 "$PKG/DEBIAN/$script"
done

mkdir -p "$OUT"
dpkg-deb --root-owner-group --build "$PKG" "$OUT/Clatch-${VERSION}-linux-${ARCH}.deb"
echo "Built $OUT/Clatch-${VERSION}-linux-${ARCH}.deb"
dpkg-deb --info "$OUT/Clatch-${VERSION}-linux-${ARCH}.deb" | sed -n '/Depends/p'
