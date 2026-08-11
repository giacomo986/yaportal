#!/bin/bash
# Build the Flatpak of Luanti-portal (counterpart of release.sh for the AppImage).
# Builds luanti_src from source inside the flatpak sandbox — does NOT touch
# the dev build in luanti_src/build.
#
# Dipendenze: flatpak + flatpak-builder
#   sudo apt install flatpak flatpak-builder
#   (or: flatpak install flathub org.flatpak.Builder)
# First run downloads the freedesktop 24.08 runtime/SDK (~1.5 GB) and the
# LuaJIT/OpenAL sources; later runs are cached (ccache + state dir).
#
# Usage:
#   ./release-flatpak.sh              # produce Luanti-portal-x86_64.flatpak
#   ./release-flatpak.sh --install    # also install/update it (flatpak --user)
#   BUILD_NO=12 ./release-flatpak.sh  # rebuild build 12 instead of bumping
set -e

PROJ="$(cd "$(dirname "$0")" && pwd)"
APP_ID="io.github.giacomoperin.LuantiPortal"
MANIFEST="$PROJ/flatpak/$APP_ID.yml"
METAINFO="$PROJ/flatpak/$APP_ID.metainfo.xml"
FP_TMP="$PROJ/tmp/flatpak"
RUNTIME_VER="24.08"
OUT="$PROJ/Luanti-portal-x86_64.flatpak"

# ── build number ──────────────────────────────────────────────────────────────
# Bumped here and stamped into the two places the installed app carries it:
# the engine version string (main menu, `luanti --version`) and the appstream
# metainfo (`flatpak info`). Both files are committed, so the repo always says
# which build the artifact is.
source "$PROJ/build-number.sh"
sed -i "s|^\( *- -DVERSION_EXTRA=\).*|\1$VERSION_EXTRA|" "$MANIFEST"
sed -i "s|<release version=\"[^\"]*\" date=\"[^\"]*\"/>|<release version=\"$VERSION_FULL\" date=\"$(date +%F)\"/>|" \
    "$METAINFO"

# ── prerequisites ─────────────────────────────────────────────────────────────
command -v flatpak >/dev/null 2>&1 || {
    echo "ERROR: 'flatpak' not found. Install with: sudo apt install flatpak"; exit 1
}

if command -v flatpak-builder >/dev/null 2>&1; then
    BUILDER=(flatpak-builder)
elif flatpak info --user org.flatpak.Builder >/dev/null 2>&1 \
  || flatpak info org.flatpak.Builder >/dev/null 2>&1; then
    BUILDER=(flatpak run org.flatpak.Builder)
else
    echo "ERROR: flatpak-builder not found. Install with one of:"
    echo "  sudo apt install flatpak-builder"
    echo "  flatpak install flathub org.flatpak.Builder"
    exit 1
fi

# ── runtime + SDK ─────────────────────────────────────────────────────────────
flatpak remote-add --user --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo

for ref in org.freedesktop.Platform org.freedesktop.Sdk; do
    flatpak info --user "$ref//$RUNTIME_VER" >/dev/null 2>&1 \
        || flatpak info "$ref//$RUNTIME_VER" >/dev/null 2>&1 \
        || flatpak install --user -y flathub "$ref//$RUNTIME_VER"
done

# ── build ─────────────────────────────────────────────────────────────────────
echo ">>> flatpak-builder..."
mkdir -p "$FP_TMP"
# --disable-rofiles-fuse: the fuse overlay can die during the heavy final
# link (ld "bfd_stat failed" spam, then "build directory not initialized").
"${BUILDER[@]}" --force-clean --ccache --user --disable-rofiles-fuse \
    --state-dir="$FP_TMP/state" \
    --repo="$FP_TMP/repo" \
    "$FP_TMP/build" "$MANIFEST"

# ── single-file bundle ────────────────────────────────────────────────────────
echo ">>> flatpak build-bundle..."
flatpak build-bundle "$FP_TMP/repo" "$OUT" "$APP_ID"

if [ "$1" = "--install" ]; then
    echo ">>> Installing (user)..."
    flatpak install --user -y --reinstall "$OUT"
fi

echo ""
echo "Flatpak bundle: $OUT"
echo "Build:          $BUILD_NO  ($VERSION_FULL)"
echo "Install with:   flatpak install --user --reinstall $OUT"
echo "Run with:       flatpak run $APP_ID"
echo "Which build:    flatpak info $APP_ID   (or the version in the main menu)"
