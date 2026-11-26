#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# CI: the system packages Clatch for Linux builds and tests with, and the Swift
# toolchain (into ~/swift unless a cached copy is there). Prints the PATH entry.
#   linux/ci-setup.sh [build|test]
set -euo pipefail
# Only the PATH entry goes to stdout (the workflow appends it to $GITHUB_PATH).
exec 3>&1 1>&2
SWIFT_VERSION=6.4.3
MODE=${1:-build}
. /etc/os-release
sudo apt-get update -qq
if [ "$MODE" = build ]; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        libgtk-4-dev libadwaita-1-dev libcurl4-openssl-dev libxml2-dev libz3-dev libedit-dev \
        binutils gcc pkg-config dpkg-dev
fi
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    xvfb dbus dbus-x11 libglib2.0-bin desktop-file-utils imagemagick gcc python3
if [ "$MODE" = build ] && [ ! -x "$HOME/swift/usr/bin/swift" ]; then
    platform="ubuntu${VERSION_ID}"
    dir="ubuntu${VERSION_ID//./}"
    if [ "$(uname -m)" = aarch64 ]; then platform="$platform-aarch64"; dir="$dir-aarch64"; fi
    mkdir -p "$HOME/swift"
    curl -sSfL "https://download.swift.org/swift-$SWIFT_VERSION-release/$dir/swift-$SWIFT_VERSION-RELEASE/swift-$SWIFT_VERSION-RELEASE-$platform.tar.gz" \
        | tar xz --strip-components=1 -C "$HOME/swift"
fi
echo "$HOME/swift/usr/bin" >&3
