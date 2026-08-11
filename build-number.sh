#!/bin/bash
# One build counter for every artifact this repo ships: the AppImage and the
# Flatpak share it, so "build 12" means the same code whichever one you
# installed. The number is stamped into the engine version string
# (5.16.1-portal-b12, shown in the main menu and by `luanti --version`) and,
# for the Flatpak, into the metainfo so `flatpak info` reports it too.
#
# Sourced by release.sh / release-flatpak.sh, not run directly. It bumps the
# counter in BUILD_NUMBER (committed, so the repo records what was shipped)
# and exports BUILD_NO / VERSION_EXTRA / VERSION_FULL.
#
# Rebuild an existing number instead of bumping:
#   BUILD_NO=12 ./release-flatpak.sh

_BN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BN_FILE="$_BN_DIR/BUILD_NUMBER"

if [ -z "$BUILD_NO" ]; then
    [ -f "$BN_FILE" ] || echo 0 > "$BN_FILE"
    BUILD_NO=$(( $(tr -cd '0-9' < "$BN_FILE") + 1 ))
    echo "$BUILD_NO" > "$BN_FILE"
fi

VERSION_EXTRA="portal-b$BUILD_NO"

# Base version straight from the engine, so a Luanti bump carries over.
_BASE_VER="$(sed -n 's/^set(VERSION_\(MAJOR\|MINOR\|PATCH\) \([0-9]\+\)).*/\2/p' \
    "$_BN_DIR/luanti_src/CMakeLists.txt" | paste -sd. -)"
VERSION_FULL="${_BASE_VER:-5.16.1}-$VERSION_EXTRA"

echo ">>> build $BUILD_NO  ($VERSION_FULL)"
