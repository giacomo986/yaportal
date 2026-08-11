#!/bin/bash
# Compile Luanti-portal in Release mode and produce the AppImage.
# Restores the dev build (Debug + RUN_IN_PLACE=FALSE) when done.
#
# Dipendenze: patchelf wget fuse/libfuse2
#   sudo apt install patchelf wget libfuse2
#
# Optional variables:
#   CMAKE=/path/to/cmake   (default: cmake from PATH)
#   NINJA=/path/to/ninja   (default: ninja from PATH)
set -e

PROJ="$(cd "$(dirname "$0")" && pwd)"
SRC="$PROJ/luanti_src"
BUILD="$SRC/build"
TOOLS="$PROJ/tmp/appimage-tools"
APPDIR="$PROJ/tmp/AppDir"
# Auto-detect cmake from CMakeCache if not set in environment.
if [ -z "$CMAKE" ]; then
    CMAKE="$(grep '^CMAKE_COMMAND:INTERNAL=' "$BUILD/CMakeCache.txt" 2>/dev/null | cut -d= -f2)"
    CMAKE="${CMAKE:-cmake}"
fi
NINJA="${NINJA:-ninja}"
OUT="$PROJ/Luanti-portal-x86_64.AppImage"

# Bump the shared build counter and stamp it into the version string.
source "$PROJ/build-number.sh"

# ── prerequisites ──────────────────────────────────────────────────────────────
for cmd in patchelf wget; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: '$cmd' not found. Install with: sudo apt install $cmd"; exit 1
    }
done

# ── /tmp symlinks (cleared on reboot) ──────────────────────────────────
ln -sfn "$PROJ/tmp/deps"            /tmp/deps
ln -sfn "$PROJ/tmp/leveldb-extract" /tmp/leveldb-extract
ln -sfn "$PROJ/tmp/luajit-extract"  /tmp/luajit-extract

SDLINC="$PROJ/tmp/deps/usr/include"
ln -sf "$SDLINC/x86_64-linux-gnu/SDL2/_real_SDL_config.h" \
       "$SDLINC/SDL2/_real_SDL_config.h" 2>/dev/null || true

# Fix broken .so symlinks on non-Debian distros (e.g. Arch).
DEPS_LIB="$PROJ/tmp/deps/usr/lib/x86_64-linux-gnu"
for link in "$DEPS_LIB"/*.so*; do
    [ -L "$link" ] || continue
    target="$(readlink "$link")"
    [[ "$target" == /usr/lib/x86_64-linux-gnu/* ]] || continue
    [ -e "$link" ] && continue
    alt="/usr/lib/$(basename "$target")"
    if [ -e "$alt" ]; then
        ln -sfn "$alt" "$link"
    fi
done

# ── download appimagetool ──────────────────────────────────────────────────────
mkdir -p "$TOOLS"
APPIMAGETOOL="$TOOLS/appimagetool-x86_64.AppImage"
if [ ! -f "$APPIMAGETOOL" ]; then
    echo ">>> Downloading appimagetool..."
    wget -q --show-progress -O "$APPIMAGETOOL" \
        "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
    chmod +x "$APPIMAGETOOL"
fi

# ── configure Release ────────────────────────────────────────────────────────
# RUN_IN_PLACE=FALSE: setSystemPaths() reads LUANTI_USER_PATH and finds
# path_share from bindir/../builtin (= AppDir/builtin). With TRUE path_user
# is hardcoded to the read-only AppImage → crash on debug.txt.
echo ">>> cmake Release..."
"$CMAKE" -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DRUN_IN_PLACE=FALSE \
    -DVERSION_EXTRA="$VERSION_EXTRA" \
    > /dev/null

# ── compile ───────────────────────────────────────────────────────────────────
echo ">>> Build Release..."
"$NINJA" -C "$BUILD" -j"$(nproc)"

# ── build AppDir ───────────────────────────────────────────────────────────────
echo ">>> Building AppDir..."
rm -rf "$APPDIR"
mkdir -p "$APPDIR/bin" "$APPDIR/lib"

cp "$SRC/bin/luanti" "$APPDIR/bin/luanti"

for dir in games builtin fonts textures locale clientmods; do
    [ -d "$SRC/$dir" ] && cp -r "$SRC/$dir" "$APPDIR/$dir"
done
# The FPS arena game lives in the repo root, not in luanti_src/games.
mkdir -p "$APPDIR/games"
cp -r "$PROJ/yafps" "$APPDIR/games/yafps"
mkdir -p "$APPDIR/client"
[ -d "$SRC/client/shaders" ] && cp -r "$SRC/client/shaders" "$APPDIR/client/shaders"

# Mods in bundled_mods/ (not auto-discovered by Luanti as global mods).
# AppRun copies them to $LUANTI_USER/mods/ on first launch.
for mod in yaportal yaportal_link; do
    mkdir -p "$APPDIR/bundled_mods/$mod"
    cp "$PROJ/$mod/init.lua" "$PROJ/$mod/mod.conf" "$APPDIR/bundled_mods/$mod/"
    cp -r "$PROJ/$mod/textures" "$APPDIR/bundled_mods/$mod/"
done

# ── collect .so ─────────────────────────────────────────────────────────────
echo ">>> Collecting libraries..."
EXCLUDE="libGL|libGLX|libGLdispatch|libEGL|libOpenGL|libvulkan|libc\.so|libm\.so|libgcc|libstdc|ld-linux"

ldd "$APPDIR/bin/luanti" \
    | awk '/=> \// {print $3}' \
    | grep -Ev "$EXCLUDE" \
    | while read -r lib; do
        [ -f "$lib" ] && cp -n "$lib" "$APPDIR/lib/"
    done

for lib in "$APPDIR/lib/"*.so*; do
    [ -f "$lib" ] || continue
    ldd "$lib" 2>/dev/null \
        | awk '/=> \// {print $3}' \
        | grep -Ev "$EXCLUDE" \
        | while read -r dep; do
            [ -f "$dep" ] && cp -n "$dep" "$APPDIR/lib/" 2>/dev/null || true
        done
done

# ── RPATH ─────────────────────────────────────────────────────────────────────
echo ">>> Patching RPATH..."
patchelf --set-rpath '$ORIGIN/../lib' "$APPDIR/bin/luanti"

# ── AppRun ────────────────────────────────────────────────────────────────────
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/bash
APPDIR="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$APPDIR/lib:${LD_LIBRARY_PATH}"

if [ -d "$HOME/.minetest" ]; then
    LUANTI_USER="$HOME/.minetest"
elif [ -d "$HOME/.local/share/luanti" ]; then
    LUANTI_USER="$HOME/.local/share/luanti"
else
    LUANTI_USER="$HOME/.luanti"
fi
export LUANTI_USER_PATH="$LUANTI_USER"
mkdir -p "$LUANTI_USER"

# Remove old mod dir left over from rename mio_portale → yaportal
rm -rf "$LUANTI_USER/mods/mio_portale"

for mod in yaportal yaportal_link; do
    USERMOD="$LUANTI_USER/mods/$mod"
    # Content compare, not -nt: mtimes inside the image are not reliable
    # (flatpak/ostree resets them to epoch), so compare init.lua instead.
    if [ ! -d "$USERMOD" ] || ! cmp -s "$APPDIR/bundled_mods/$mod/init.lua" "$USERMOD/init.lua"; then
        mkdir -p "$LUANTI_USER/mods"
        rm -rf "$USERMOD"
        cp -r "$APPDIR/bundled_mods/$mod" "$USERMOD"
    fi
done

# yaportal_link needs an insecure environment (it starts and links local
# world servers); without this setting it disables itself at load.
CONF="$LUANTI_USER/minetest.conf"
if [ ! -f "$CONF" ] || ! grep -q '^secure\.trusted_mods' "$CONF"; then
    echo 'secure.trusted_mods = yaportal_link' >> "$CONF"
elif ! grep -q '^secure\.trusted_mods.*yaportal_link' "$CONF"; then
    sed -i 's|^secure\.trusted_mods[[:space:]]*=[[:space:]]*|&yaportal_link,|' "$CONF"
fi

# Migrate world.mt: rename old mod key and force-enable yaportal
find "$LUANTI_USER/worlds" -name "world.mt" 2>/dev/null | while read -r wmt; do
    sed -i \
        's|^load_mod_mio_portale = .*|load_mod_yaportal = true|' \
        "$wmt"
    grep -q "^load_mod_yaportal" "$wmt" || true
done

exec "$APPDIR/bin/luanti" "$@"
EOF
chmod +x "$APPDIR/AppRun"

cat > "$APPDIR/luanti.desktop" <<'EOF'
[Desktop Entry]
Name=Luanti (portal)
Exec=luanti
Icon=luanti
Type=Application
Categories=Game;
EOF

cp "$SRC/misc/luanti-xorg-icon-128.png" "$APPDIR/luanti.png"

# ── create AppImage ─────────────────────────────────────────────────────────────
echo ">>> Creating AppImage..."
ARCH=x86_64 "$APPIMAGETOOL" "$APPDIR" "$OUT"

# ── restore dev build ──────────────────────────────────────────────────────
echo ">>> Restoring Debug build for dev..."
"$CMAKE" -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Debug \
    -DVERSION_EXTRA= \
    > /dev/null
"$NINJA" -C "$BUILD" -j"$(nproc)"

echo ""
echo "AppImage: $OUT  (build $BUILD_NO, $VERSION_FULL)"
echo "Run with: ./$OUT"
