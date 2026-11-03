#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build dist/Clatch.app: a universal (arm64 + x86_64) menu bar app for
# macOS 11 Big Sur and later.
#
#   ./scripts/build-app.sh            # release build
#   ./scripts/build-app.sh --debug
#
# Environment:
#   CLATCH_SIGN_IDENTITY   codesign identity ("Developer ID Application: …").
#                          Unset → ad-hoc signature (fine for local testing).
#   CLATCH_BUILD_NUMBER    CFBundleVersion (CI passes the run number).
#
# Needs Xcode 26 or later (Swift 6.2 and the macOS 26 SDK, which provides
# Liquid Glass). The binary still runs on macOS 11: newer APIs are gated with
# #available.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

CONFIGURATION="release"
[[ "${1:-}" == "--debug" ]] && CONFIGURATION="debug"
SIGN_IDENTITY="${CLATCH_SIGN_IDENTITY:-}"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="${CLATCH_BUILD_NUMBER:-${VERSION}}"
ARCHS=(arm64 x86_64)
MIN_MACOS="11.0"
DIST="${REPO_ROOT}/dist"
APP="${DIST}/Clatch.app"

log() { printf '\033[32m==>\033[0m %s\n' "$1"; }
die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

command -v swift >/dev/null || die "swift not found; install Xcode 26 or later"
log "Clatch ${VERSION} (${BUILD_NUMBER}) · ${CONFIGURATION} · ${ARCHS[*]} · macOS ${MIN_MACOS}+"
swift --version

slices=()
for arch in "${ARCHS[@]}"; do
  log "Compiling for ${arch}"
  swift build --configuration "${CONFIGURATION}" --arch "${arch}" --product Clatch
  bin="$(swift build --configuration "${CONFIGURATION}" --arch "${arch}" --show-bin-path)"
  slices+=("${bin}/Clatch")
done

log "Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
lipo -create "${slices[@]}" -output "${APP}/Contents/MacOS/Clatch"
sed -e "s/__CLATCH_VERSION__/${VERSION}/g" -e "s/__CLATCH_BUILD__/${BUILD_NUMBER}/g" \
  Resources/Info.plist > "${APP}/Contents/Info.plist"
plutil -lint "${APP}/Contents/Info.plist" >/dev/null
cp Resources/AppIcon.icns "${APP}/Contents/Resources/"
cp LICENSE "${APP}/Contents/Resources/LICENSE.txt"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

# Swift back-deployment libraries. Swift Concurrency (MainActor and friends)
# is part of macOS from 12 on; for macOS 11 the toolchain ships a copy that has
# to travel inside the app. The binary's rpaths list /usr/lib/swift first, so
# newer systems keep using their own copy and the bundled one is only a
# fallback.
toolchain_lib="$(cd "$(dirname "$(xcrun --find swift)")/../lib" && pwd)"
embedded=0
while read -r dependency; do
  name="${dependency#@rpath/}"
  source="$(find "${toolchain_lib}" -path '*/macosx/*' -name "${name}" 2>/dev/null | sort | tail -1)"
  if [[ -n "${source}" ]]; then
    mkdir -p "${APP}/Contents/Frameworks"
    cp -L "${source}" "${APP}/Contents/Frameworks/${name}"
    chmod u+w "${APP}/Contents/Frameworks/${name}"
    echo "  embedded ${name} (back-deployment, from ${source#"${toolchain_lib}/"})"
    embedded=1
  else
    echo "  ${name}: no back-deployment copy in the toolchain (part of macOS)"
  fi
done < <(otool -L "${APP}/Contents/MacOS/Clatch" | awk '/^[[:space:]]*@rpath\/libswift/ {print $1}' | sort -u)
if [[ ${embedded} -eq 1 ]]; then
  otool -l "${APP}/Contents/MacOS/Clatch" | grep -q '@executable_path/../Frameworks' \
    || install_name_tool -add_rpath "@executable_path/../Frameworks" "${APP}/Contents/MacOS/Clatch"
  for lib in "${APP}/Contents/Frameworks/"*.dylib; do
    codesign --remove-signature "${lib}" 2>/dev/null || true
  done
fi
otool -l "${APP}/Contents/MacOS/Clatch" | awk '/cmd LC_RPATH/ {getline; getline; print "  rpath " $2}'

if [[ -n "${SIGN_IDENTITY}" ]]; then
  log "Signing with ${SIGN_IDENTITY} (hardened runtime)"
  SIGN_FLAGS=(--force --sign "${SIGN_IDENTITY}" --timestamp --options runtime)
else
  log "Ad-hoc signing (set CLATCH_SIGN_IDENTITY for a distributable build)"
  SIGN_FLAGS=(--force --sign - --timestamp=none)
fi
# Inside out: embedded libraries first, then the bundle.
for lib in "${APP}/Contents/Frameworks/"*.dylib; do
  [[ -f "${lib}" ]] && codesign "${SIGN_FLAGS[@]}" "${lib}"
done
codesign "${SIGN_FLAGS[@]}" --identifier com.issen.clatch "${APP}"

log "Verifying"
codesign --verify --deep --strict --verbose=1 "${APP}"
archs="$(lipo -archs "${APP}/Contents/MacOS/Clatch")"
for arch in "${ARCHS[@]}"; do
  [[ " ${archs} " == *" ${arch} "* ]] || die "binary lacks ${arch} (has: ${archs})"
done
echo "  ✓ universal: ${archs}"
# Deployment target of every slice.
for arch in "${ARCHS[@]}"; do
  minos="$(vtool -arch "${arch}" -show-build "${APP}/Contents/MacOS/Clatch" | awk '/minos/ {print $2; exit}')"
  [[ "${minos}" == "${MIN_MACOS}" ]] || die "${arch} slice targets macOS ${minos}, expected ${MIN_MACOS}"
  echo "  ✓ ${arch}: minimum macOS ${minos}"
done
# Only system libraries, or Swift libraries that are in the OS or the bundle.
while read -r dependency; do
  case "${dependency}" in
    /usr/lib/*|/System/*) ;;
    @rpath/libswift*) ;;  # in /usr/lib/swift on current macOS, embedded above when needed
    *) die "links ${dependency}, which is neither in macOS nor in the bundle" ;;
  esac
done < <(otool -L "${APP}/Contents/MacOS/Clatch" | awk '/^[[:space:]]/ {print $1}' | sort -u)
echo "  ✓ links only system or bundled libraries"
du -sh "${APP}"
log "Built ${APP}"
